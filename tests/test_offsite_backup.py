"""Private offsite protocol tests: synthetic files/local subprocesses, no real SSH."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO/path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
export = module('offsite_export', 'account-server/deploy/backup-export.py')
pull = module('offsite_pull', 'scripts/pull-offsite-backup.py')


class OffsiteBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='boji-offsite-fixture-')
        self.folder = Path(self.temporary.name).resolve()
        self.server = self.folder/'server'; self.server.mkdir(mode=0o700)
        self.archives = self.folder/'server-archives'; self.archives.mkdir(mode=0o700)
        self.mac = self.folder/'private-mac'
        self.patches = [mock.patch.object(export, 'STATE', self.server), mock.patch.object(export, 'ARCHIVES', self.archives),
                        mock.patch.object(export, 'OWNER_UID', os.getuid()), mock.patch.object(pull, 'ROOT', self.mac)]
        for patch in self.patches: patch.start()
        for directory in (self.mac, self.mac/'archives', self.mac/'keys', self.mac/'metadata'): pull.private_directory(directory)
        self.key = b'SYNTHETIC_PRIVATE_BACKUP_KEY_DO_NOT_LOG_123456'
        self.package = b'BOJIBACKUP2'+b'SYNTHETIC_ENCRYPTED_FIXTURE'*30
        self.name = 'bojiclub-full-20261028T031700Z-aabbccdd.boji'
        self.create_backup(self.name, self.package)
        self.commands = []
    def tearDown(self):
        for patch in reversed(self.patches): patch.stop()
        self.temporary.cleanup()
    def create_backup(self, name, package):
        path = self.archives/name; path.write_bytes(package); path.chmod(0o600)
        (self.server/'backup-password').write_bytes(self.key+b'\n'); (self.server/'backup-password').chmod(0o600)
        record = {'path': str(path), 'bytes': len(package), 'created_at_utc': '20261028T031700Z',
                  'key_fingerprint': hashlib.sha256(self.key).hexdigest()[:16]}
        (self.server/'backup-result.json').write_text(json.dumps(record))
    def request(self, command):
        output = io.BytesIO(); export.serve(command, output); return output.getvalue()
    def fake_receive(self, config, command, output, maximum, expected_size=None, timeout=120):
        self.commands.append(command)
        raw = self.request(command)
        if len(raw) > maximum or (expected_size is not None and len(raw) != expected_size): raise pull.PullError('fake transfer rejected')
        output.write(raw)
        return len(raw), hashlib.sha256(raw).hexdigest()
    def manifest(self): return json.loads(self.request('manifest'))

    def test_protocol_rejects_shell_paths_quotes_and_extra_arguments(self):
        for command in ['', 'sh', 'manifest ', 'manifest\n', 'manifest; id', 'manifest\t', 'archive ../backup-password '+'a'*64,
                        'key /root/backup-password '+'a'*64, 'archive '+self.name+' '+'a'*64+';id',
                        'ack '+self.name+' '+'a'*64, 'manifest && whoami', 'key "'+self.name+'" '+'a'*64]:
            with self.subTest(command=command), self.assertRaises(export.ExportError): export.parse_command(command)
        with mock.patch.object(export.sys, 'argv', ['backup-export.py', 'manifest']), contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(export.main(), 1)
        self.assertNotIn(self.key.decode(), error.getvalue())

    def test_manifest_is_allowlisted_metadata_and_exports_match_hash(self):
        manifest = self.manifest(); encoded = json.dumps(manifest)
        self.assertNotIn(str(self.server), encoded); self.assertNotIn(self.key.decode(), encoded)
        self.assertEqual(manifest['sha256'], hashlib.sha256(self.package).hexdigest())
        self.assertEqual(self.request('archive '+self.name+' '+manifest['sha256']), self.package)
        self.assertEqual(self.request('key '+self.name+' '+manifest['sha256']), self.key)
        self.assertEqual(manifest['key_sha256'], hashlib.sha256(self.key).hexdigest())

    def test_wrong_hash_name_and_changed_latest_are_denied(self):
        manifest = self.manifest()
        for command in ['archive '+self.name+' '+'0'*64, 'key bojiclub-full-20261027T031700Z.boji '+manifest['sha256'],
                        'key bojiclub-full-20261027T031700Z.boji '+'a'*64]:
            with self.assertRaises(export.ExportError): self.request(command)
        (self.archives/self.name).write_bytes(self.package[:-1]+b'Z')
        with self.assertRaises(export.ExportError): self.request('archive '+self.name+' '+manifest['sha256'])

    def test_symlinks_hardlinks_insecure_permissions_and_key_mismatch_rejected(self):
        archive = self.archives/self.name
        archive.chmod(0o644)
        with self.assertRaises(export.ExportError): self.manifest()
        archive.chmod(0o600)
        link = self.folder/'linked'; os.link(archive, link)
        with self.assertRaises(export.ExportError): self.manifest()
        link.unlink()
        key = self.server/'backup-password'; key.unlink(); key.symlink_to(archive)
        with self.assertRaises((OSError, export.ExportError)): self.manifest()
        key.unlink(); key.write_bytes(b'OTHER_SYNTHETIC_KEY_1234567890'); key.chmod(0o600)
        with self.assertRaises(export.ExportError): self.manifest()
        key.write_bytes(self.key)
        other = self.folder/'archive-content'; archive.rename(other); archive.symlink_to(other)
        with self.assertRaises((OSError, export.ExportError)): self.manifest()

    def test_ack_requires_archive_and_key_proof_and_does_not_change_backup_record(self):
        manifest = self.manifest(); original = (self.server/'backup-result.json').read_bytes()
        with self.assertRaises(export.ExportError): self.request('ack '+self.name+' '+manifest['sha256']+' '+'0'*64)
        result = json.loads(self.request('ack '+self.name+' '+manifest['sha256']+' '+manifest['key_sha256']))
        self.assertEqual(result['state'], 'acknowledged')
        ack_path = self.server/'offsite-mac-ack.json'; ack = json.loads(ack_path.read_text())
        self.assertEqual(ack['state'], 'receiver_verified'); self.assertFalse(ack['restore_verified'])
        self.assertEqual(stat.S_IMODE(ack_path.stat().st_mode), 0o600)
        self.assertEqual((self.server/'backup-result.json').read_bytes(), original)
        self.assertNotIn(self.key.decode(), ack_path.read_text())

    def test_end_to_end_private_files_and_ack_after_durable_verification(self):
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive): result = pull.pull({})
        self.assertEqual(result['state'], 'succeeded')
        self.assertEqual((self.mac/'archives'/self.name).read_bytes(), self.package)
        fingerprint = hashlib.sha256(self.key).hexdigest()[:16]
        self.assertEqual((self.mac/'keys'/('backup-key-'+fingerprint+'.key')).read_bytes(), self.key)
        for directory in (self.mac, self.mac/'archives', self.mac/'keys', self.mac/'metadata'):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            for file in directory.iterdir():
                if file.is_file(): self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
        self.assertTrue(self.commands[-1].startswith('ack ')); self.assertNotIn(self.key.decode(), json.dumps(result))
        latest = json.loads((self.mac/'metadata'/'latest-good.json').read_text())
        self.assertEqual(latest['remote_ack'], 'acknowledged'); self.assertFalse(latest['restore_verified'])
        self.commands = []
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive): self.assertEqual(pull.pull({})['state'], 'succeeded')
        self.assertEqual([c.split()[0] for c in self.commands], ['manifest', 'ack'])

    def test_failed_archive_does_not_replace_old_good_or_write_key_or_ack(self):
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive): pull.pull({})
        old_latest = (self.mac/'metadata'/'latest-good.json').read_bytes()
        new_name = 'bojiclub-full-20261029T031700Z-11223344.boji'
        self.create_backup(new_name, self.package+b'NEW')
        real_fake = self.fake_receive
        def corrupted(config, command, target, maximum, expected_size=None, timeout=120):
            if command.startswith('archive '):
                data = b'BAD!'+(self.package+b'NEW')[4:]; target.write(data)
                return len(data), hashlib.sha256(data).hexdigest()
            return real_fake(config, command, target, maximum, expected_size, timeout)
        self.commands = []
        with mock.patch.object(pull, 'receive', side_effect=corrupted), self.assertRaises(pull.PullError): pull.pull({})
        self.assertEqual((self.mac/'metadata'/'latest-good.json').read_bytes(), old_latest)
        self.assertEqual((self.mac/'archives'/self.name).read_bytes(), self.package)
        self.assertFalse((self.mac/'archives'/new_name).exists())
        self.assertFalse(any(command.startswith('ack ') for command in self.commands))
        self.assertFalse(list((self.mac/'archives').glob('.encrypted-*')))

    def test_failed_key_keeps_existing_key_and_does_not_ack(self):
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive): pull.pull({})
        old_latest = (self.mac/'metadata'/'latest-good.json').read_bytes()
        self.key = b'NEW_SYNTHETIC_PRIVATE_KEY_1234567890'
        name = 'bojiclub-full-20261029T031700Z-11223344.boji'; self.create_backup(name, self.package+b'NEW')
        real_fake = self.fake_receive
        def bad_key(config, command, output, maximum, expected_size=None, timeout=120):
            if command.startswith('key '):
                output.write(b'WRONG_SYNTHETIC_KEY_1234567890'); return 30, '0'*64
            return real_fake(config, command, output, maximum, expected_size, timeout)
        self.commands = []
        with mock.patch.object(pull, 'receive', side_effect=bad_key), self.assertRaises(pull.PullError): pull.pull({})
        self.assertEqual((self.mac/'metadata'/'latest-good.json').read_bytes(), old_latest)
        self.assertEqual(len(list((self.mac/'keys').glob('*.key'))), 1)
        self.assertFalse(any(c.startswith('ack ') for c in self.commands))

    def test_existing_name_collision_never_overwrites_a_previous_archive(self):
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive): pull.pull({})
        self.create_backup(self.name, self.package+b'CHANGED')
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive), self.assertRaises(pull.PullError): pull.pull({})
        self.assertEqual((self.mac/'archives'/self.name).read_bytes(), self.package)

    def test_ack_failure_shows_pending_and_preserves_previous_good_metadata(self):
        with mock.patch.object(pull, 'receive', side_effect=self.fake_receive): pull.pull({})
        previous = (self.mac/'metadata'/'latest-good.json').read_bytes()
        name = 'bojiclub-full-20261029T031700Z-11223344.boji'; self.create_backup(name, self.package+b'NEW')
        real_fake = self.fake_receive
        def unavailable_ack(config, command, output, maximum, expected_size=None, timeout=120):
            if command.startswith('ack '): raise pull.PullError('unavailable')
            return real_fake(config, command, output, maximum, expected_size, timeout)
        with mock.patch.object(pull, 'receive', side_effect=unavailable_ack): result = pull.pull({})
        self.assertEqual(result['state'], 'copied_ack_pending')
        self.assertEqual((self.mac/'metadata'/'latest-good.json').read_bytes(), previous)
        self.assertTrue((self.mac/'archives'/name).exists())

    def test_private_config_and_strict_fixed_ssh_host(self):
        identity = self.folder/'dedicated-id'; identity.write_text('SYNTHETIC_SSH_KEY'); identity.chmod(0o600)
        hosts = self.folder/'known-hosts'; hosts.write_text('117.50.119.49 ssh-ed25519 SYNTHETIC_PIN'); hosts.chmod(0o600)
        config_file = self.folder/'config.json'; config_file.write_text(json.dumps({'identity_file': str(identity), 'known_hosts_file': str(hosts)})); config_file.chmod(0o600)
        config = pull.configure(config_file); command = pull.ssh_command(config, 'manifest')
        self.assertIn('StrictHostKeyChecking=yes', command); self.assertIn('root@117.50.119.49', command)
        self.assertIn('GlobalKnownHostsFile=/dev/null', command); self.assertIn('ProxyCommand=none', command)
        self.assertNotIn('StrictHostKeyChecking=no', command)
        config_file.write_text(json.dumps({'identity_file': str(identity), 'known_hosts_file': str(hosts), 'server': 'evil.example'}))
        with self.assertRaises(pull.PullError): pull.configure(config_file)
        config_file.write_text(json.dumps({'identity_file': str(identity), 'known_hosts_file': str(hosts)}))
        hosts.chmod(0o644)
        with self.assertRaises(pull.PullError): pull.configure(config_file)
        hosts.chmod(0o600); identity.unlink(); identity.symlink_to(hosts)
        with self.assertRaises(pull.PullError): pull.configure(config_file)

    def test_manifest_rejects_paths_plaintext_and_oversize(self):
        valid = self.manifest()
        for update in [{'archive': '../backup-password'}, {'encryption': 'none'}, {'bytes': 2*1024**4+1}, {'bytes': True}, {'sha256': 'invalid'}, {'key_fingerprint': 'wrong'}]:
            with self.assertRaises(pull.PullError): pull.manifest_value(json.dumps({**valid, **update}))

    def test_receive_local_process_caps_stream_rejects_exit_failure_and_timeout(self):
        def fake_command(code): return [sys.executable, '-c', code]
        with mock.patch.object(pull, 'ssh_command', return_value=fake_command('import sys;sys.stdout.buffer.write(b"synthetic")')):
            output = io.BytesIO(); size, digest = pull.receive({}, 'ignored', output, 20, expected_size=9)
        self.assertEqual(size, 9); self.assertEqual(digest, hashlib.sha256(b'synthetic').hexdigest())
        with mock.patch.object(pull, 'ssh_command', return_value=fake_command('print("too much data")')):
            with self.assertRaises(pull.PullError): pull.receive({}, 'ignored', io.BytesIO(), 2)
        with mock.patch.object(pull, 'ssh_command', return_value=fake_command('raise SystemExit(1)')):
            with self.assertRaises(pull.PullError): pull.receive({}, 'ignored', io.BytesIO(), 100)
        with mock.patch.object(pull, 'ssh_command', return_value=fake_command('import time;time.sleep(5)')):
            with self.assertRaises(pull.PullError): pull.receive({}, 'ignored', io.BytesIO(), 100, timeout=.02)

    def test_crash_staging_cleanup_preserves_good_and_releases_duplicate_link(self):
        good = self.mac/'keys'/'backup-key-existing.key'; good.write_bytes(self.key); good.chmod(0o600)
        staging = self.mac/'keys'/'.key-abcd1234'; os.link(good, staging)
        orphan = self.mac/'archives'/'.encrypted-1234abcd'; orphan.write_bytes(b'partial'); orphan.chmod(0o600)
        foreign = self.mac/'archives'/'.encrypted-keep-me'; foreign.write_bytes(b'keep'); foreign.chmod(0o600)
        pull.cleanup_staging()
        self.assertFalse(staging.exists()); self.assertFalse(orphan.exists()); self.assertTrue(foreign.exists())
        self.assertEqual(good.read_bytes(), self.key); self.assertEqual(good.stat().st_nlink, 1)
        self.assertEqual(pull.digest_file(good), hashlib.sha256(self.key).hexdigest())

    def test_main_pending_is_secret_free_and_does_not_replace_good(self):
        (self.mac/'metadata'/'latest-good.json').write_text('{"old":"good"}'); (self.mac/'metadata'/'latest-good.json').chmod(0o600)
        with mock.patch.object(sys, 'argv', ['pull']), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(pull.main(), 1)
        result = json.loads(output.getvalue()); self.assertEqual(result['state'], 'pending')
        self.assertEqual((self.mac/'metadata'/'latest-good.json').read_text(), '{"old":"good"}')
        self.assertNotIn(self.key.decode(), output.getvalue())
        self.assertTrue((self.mac/'metadata'/'pull-status.json').exists())

    def test_launchd_template_and_smtp_example_are_pending_and_safe(self):
        plist = plistlib.loads((REPO/'scripts/com.bojiclub.offsite-backup.plist').read_bytes())
        self.assertTrue(plist['RunAtLoad']); self.assertEqual(plist['StartCalendarInterval'], {'Minute': 27})
        self.assertEqual(plist['Umask'], 0o077); self.assertIn('PYTHON3_ABSOLUTE_PATH', plist['ProgramArguments'])
        smtp = json.loads((REPO/'account-server/deploy/operations-alerts.smtp.example.json').read_text())['notifications']
        self.assertFalse(smtp['enabled']); self.assertEqual(smtp['smtp']['password'], '')
        self.assertEqual(smtp['smtp']['recipients'], ['biccyy@yeah.net'])


if __name__ == '__main__': unittest.main(verbosity=2)
