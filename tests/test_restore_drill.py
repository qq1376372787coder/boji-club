"""Synthetic encrypted recovery drills; never use an existing MySQL socket."""
from argparse import Namespace
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO/'account-server/deploy/restore-drill.py'
spec = importlib.util.spec_from_file_location('boji_restore_drill', SCRIPT)
drill = importlib.util.module_from_spec(spec); spec.loader.exec_module(drill)
MYSQL = Path('/Users/a01/Documents/Codex/2026-10-24/new-chat-2/work/runtimes/mysql-8.4.0-macos14-arm64')


class RestoreDrillTests(unittest.TestCase):
    def setUp(self):
        # A unique private tree; /tmp/boji136db.sock is never opened or modified.
        self.temporary = tempfile.TemporaryDirectory(prefix='boji-drill-tests-', dir='/tmp')
        self.folder = Path(self.temporary.name).resolve()
        self.archive = self.folder/'bojiclub-full-20261028T031700Z-aabbccdd.boji'
        self.key = self.folder/'synthetic-password'; self.key.write_text('SYNTHETIC_RECOVERY_DRILL_PASSWORD_123456'); self.key.chmod(0o600)
        self.output = self.folder/'runtime'/'restore-drill-status.json'
        self.parent = self.folder/'private-work'
    def tearDown(self): self.temporary.cleanup()
    def make_archive(self, sql=None, ai_ok=True):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
        if sql is None:
            sql = b'CREATE TABLE synthetic_alpha(id INT PRIMARY KEY); INSERT INTO synthetic_alpha VALUES(1),(2),(3); CREATE TABLE synthetic_beta(id INT PRIMARY KEY); INSERT INTO synthetic_beta VALUES(10),(20);'
        database = self.folder/'fixture.sqlite3'
        if database.exists(): database.unlink()
        with sqlite3.connect(database) as db:
            db.execute('CREATE TABLE synthetic_jobs(id INTEGER)'); db.execute('INSERT INTO synthetic_jobs VALUES(1)')
        manifest = {'version': 2, 'created_at': '20261028T031700Z', 'key_fingerprint': hashlib.sha256(self.key.read_bytes()).hexdigest()[:16], 'includes': []}
        plain = io.BytesIO()
        with tarfile.open(fileobj=plain, mode='w:gz') as archive:
            entries = [('database.sql', sql), ('recovery-manifest.json', json.dumps(manifest).encode()),
                       ('ai-jobs.sqlite3', database.read_bytes() if ai_ok else b'NOT A SQLITE DATABASE'),
                       ('etc/systemd/system/never-start-this.service', b'[Service]\nExecStart=/usr/bin/false\n')]
            for name, data in entries:
                entry = tarfile.TarInfo(name); entry.size = len(data); entry.mode = 0o600; archive.addfile(entry, io.BytesIO(data))
        salt, nonce = os.urandom(16), os.urandom(12)
        key = Scrypt(salt=salt, length=32, n=32768, r=8, p=1).derive(self.key.read_bytes())
        encryptor = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
        ciphertext = encryptor.update(plain.getvalue())+encryptor.finalize()
        self.archive.write_bytes(b'BOJIBACKUP2'+salt+nonce+ciphertext+encryptor.tag); self.archive.chmod(0o600)
    def args(self, **updates):
        args = dict(archive=self.archive, password_file=self.key, work_parent=self.parent, mysql_basedir=MYSQL, database='bojiclub', timeout=120)
        args.update(updates); return Namespace(**args)
    def run_cli(self):
        return subprocess.run([sys.executable, str(SCRIPT), '--archive', str(self.archive), '--password-file', str(self.key),
                               '--mysql-basedir', str(MYSQL), '--work-parent', str(self.parent), '--output', str(self.output), '--timeout', '120'],
                              capture_output=True, text=True, timeout=300)
    def require_mysql(self):
        if not (MYSQL/'bin/mysqld').is_file(): self.skipTest('isolated MySQL runtime not available')
        try: import cryptography
        except ImportError: self.skipTest('cryptography unavailable')

    def test_real_mysql_import_counts_sqlite_and_private_cleanup(self):
        self.require_mysql(); self.make_archive()
        before_archive, before_key = self.archive.read_bytes(), self.key.read_bytes()
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        value = json.loads(self.output.read_text())
        self.assertEqual(value['status'], 'passed'); self.assertEqual(value['mysql']['state'], 'passed')
        self.assertEqual(value['mysql']['table_count'], 2); self.assertEqual(value['mysql']['record_count'], 5)
        self.assertEqual(value['ai_sqlite']['state'], 'passed'); self.assertEqual(value['isolation']['state'], 'passed')
        self.assertTrue(value['isolation']['skip_networking']); self.assertFalse(value['production_connected'])
        self.assertEqual(value['archive'], self.archive.name); self.assertEqual(value['sha256'], hashlib.sha256(before_archive).hexdigest())
        self.assertTrue(value['cleanup_complete']); self.assertEqual(list(self.parent.iterdir()), [])
        self.assertEqual(self.archive.read_bytes(), before_archive); self.assertEqual(self.key.read_bytes(), before_key)
        serialized = json.dumps(value)
        self.assertNotIn(self.key.read_text(), serialized); self.assertNotIn('synthetic_alpha', serialized)
        self.assertNotIn(str(self.folder), serialized); self.assertNotIn('/tmp/boji136db.sock', result.stdout+result.stderr)

    def test_real_mysql_bad_import_is_failed_and_nonzero(self):
        self.require_mysql(); self.make_archive(sql=b'CREATE TABLE synthetic_alpha(id INT); THIS IS INVALID SQL;')
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        value = json.loads(self.output.read_text())
        self.assertEqual(value['status'], 'failed'); self.assertEqual(value['error_code'], 'mysql_import_failed')
        self.assertTrue(value['cleanup_complete']); self.assertEqual(list(self.parent.iterdir()), [])
        self.assertNotIn('THIS IS INVALID', json.dumps(value))

    def test_real_mysql_cannot_write_sql_selected_paths_outside_drill(self):
        self.require_mysql()
        forbidden = self.folder/'outside-mysql-must-not-write.log'
        sql = ('CREATE TABLE synthetic_alpha(id INT); SET GLOBAL general_log_file=\''+str(forbidden)+'\'; SET GLOBAL general_log=ON;').encode()
        self.make_archive(sql=sql)
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(forbidden.exists())
        value = json.loads(self.output.read_text())
        self.assertEqual(value['status'], 'failed'); self.assertEqual(value['error_code'], 'mysql_import_failed')
        self.assertTrue(value['cleanup_complete']); self.assertEqual(list(self.parent.iterdir()), [])

    def test_real_corrupt_sqlite_fails_before_starting_a_database(self):
        self.require_mysql(); self.make_archive(ai_ok=False)
        result = drill.drill(self.args())
        self.assertEqual(result['status'], 'failed'); self.assertEqual(result['error_code'], 'ai_database_failed')
        self.assertTrue(result['cleanup_complete']); self.assertEqual(list(self.parent.iterdir()), [])

    def test_missing_dependency_cannot_pass(self):
        self.archive.write_bytes(b'BOJIBACKUP2'+b'0'*60); self.archive.chmod(0o600)
        result = drill.drill(self.args(mysql_basedir=self.folder/'does-not-exist'))
        self.assertEqual(result['status'], 'failed'); self.assertEqual(result['error_code'], 'dependency_missing')
        self.assertTrue(result['cleanup_complete']); self.assertEqual(list(self.parent.iterdir()), [])

    def test_wrong_key_fails_without_booting_mysql(self):
        self.require_mysql(); self.make_archive()
        self.key.write_text('OTHER_SYNTHETIC_RECOVERY_DRILL_PASSWORD_123456')
        result = drill.drill(self.args())
        self.assertEqual(result['error_code'], 'decrypt_or_extract_failed'); self.assertEqual(result['status'], 'failed')
        self.assertTrue(result['cleanup_complete']); self.assertEqual(list(self.parent.iterdir()), [])

    def test_client_cannot_target_an_existing_or_foreign_socket(self):
        work = self.folder/'restore-drill-abc'; work.mkdir(mode=0o700)
        for socket in [Path('/tmp/boji136db.sock'), self.folder/'mysql.sock', work/'foreign.sock']:
            with self.assertRaises(drill.DrillError): drill.db_client(Path('/fake/mysql'), socket, work, False)
        command = drill.db_client(Path('/fake/mysql'), work/'mysql.sock', work, False)
        self.assertEqual(command[1:3], ['--no-defaults', '--no-login-paths'])
        self.assertIn('--protocol=SOCKET', command); self.assertIn('--local-infile=0', command)
        self.assertIn('--binary-mode', command); self.assertIn('--skip-reconnect', command)

    def test_cleanup_rejects_other_paths_and_never_changes_parent_permissions(self):
        self.parent.mkdir(mode=0o755); old_mode = self.parent.stat().st_mode
        with self.assertRaises(drill.DrillError): drill.private_parent(self.parent)
        self.assertEqual(self.parent.stat().st_mode, old_mode)
        foreign = self.folder/'user-data'; foreign.mkdir(); (foreign/'keep').write_text('keep')
        self.assertFalse(drill.clean_work(foreign, self.folder)); self.assertTrue((foreign/'keep').exists())

    def test_linux_prefers_private_systemd_unit_and_stops_only_its_random_unit(self):
        work = self.folder/'restore-drill-systemd'; work.mkdir(mode=0o700)
        drill._UNITS = []
        absent = subprocess.CompletedProcess([], 4, stdout='not-found\n', stderr='')
        with mock.patch.object(drill.sys, 'platform', 'linux'), mock.patch.object(drill.shutil, 'which', side_effect=lambda name: '/usr/bin/'+name), mock.patch.object(Path, 'is_dir', return_value=True), mock.patch.object(drill.subprocess, 'run', return_value=absent):
            command, preexec = drill.write_guard(['/usr/sbin/mariadbd', '--no-defaults'], work)
        self.assertIsNone(preexec)
        self.assertIn('--property=ProtectSystem=strict', command)
        self.assertIn('--property=MemoryMax=256M', command)
        self.assertIn('--property=OOMScoreAdjust=1000', command)
        self.assertIn('--property=ProtectHome=read-only', command)
        self.assertIn('--property=ReadWritePaths='+str(work), command)
        self.assertIn('--property=PrivateNetwork=yes', command)
        self.assertIn('--property=RestrictAddressFamilies=AF_UNIX', command)
        unit = drill._UNITS[0][0]
        self.assertRegex(unit, r'^boji-restore-drill-[a-f0-9]{24}\.service$')
        stopped = subprocess.CompletedProcess([], 0, stdout='LoadState=not-found\nActiveState=inactive\n', stderr='')
        with mock.patch.object(drill.subprocess, 'run', return_value=stopped) as run:
            self.assertTrue(drill.stop_units())
            self.assertEqual(run.call_args_list[0].args[0], ['/usr/bin/systemctl', 'stop', unit])
        drill._UNITS = []

    def test_report_path_cannot_overwrite_other_files_or_symlinks(self):
        target = self.folder/'database.sql'; target.write_text('keep')
        with self.assertRaises(drill.DrillError): drill.write_result(target, {'kind': 'restore_drill'})
        self.assertEqual(target.read_text(), 'keep')
        self.output.parent.mkdir(); self.output.symlink_to(target)
        with self.assertRaises(drill.DrillError): drill.write_result(self.output, {'kind': 'restore_drill'})
        self.assertEqual(target.read_text(), 'keep')

    def test_unsafe_archive_or_key_permissions_are_rejected(self):
        self.archive.write_bytes(b'BOJIBACKUP2'+b'0'*60); self.archive.chmod(0o600)
        self.key.chmod(0o644)
        result = drill.drill(self.args()); self.assertEqual(result['status'], 'failed'); self.assertEqual(result['error_code'], 'invalid_input')
        self.assertFalse(self.parent.exists())

    def test_only_owned_child_process_is_stopped(self):
        process = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'], start_new_session=True)
        self.assertTrue(drill.stop_owned(process)); self.assertIsNotNone(process.poll())
        unrelated = mock.Mock(pid=99999); unrelated.poll.return_value = None
        with mock.patch.object(drill.os, 'getpgid', return_value=os.getpgrp()), mock.patch.object(drill.os, 'killpg') as kill:
            self.assertFalse(drill.stop_owned(unrelated)); kill.assert_not_called()


if __name__ == '__main__': unittest.main(verbosity=2)
