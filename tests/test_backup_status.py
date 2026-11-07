"""Encrypted backup and readable status, using synthetic files and a fake DB dump."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from argparse import Namespace

ROOT=Path(__file__).resolve().parents[1]
BACKUP=ROOT/'account-server/deploy/backup.py'
RESTORE=ROOT/'account-server/deploy/restore.py'
spec=importlib.util.spec_from_file_location('boji_backup_status',BACKUP)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class BackupStatusTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='boji-backup-drill-')
        self.folder=Path(self.temp.name);self.source=self.folder/'source';self.state=self.folder/'state';self.state.mkdir()
        self.dest=self.folder/'encrypted';self.status=self.folder/'web'/'backup-status.json'
        self.password=self.folder/'password';self.password.write_text('synthetic-backup-password-for-isolated-drill');self.password.chmod(0o600)
        for path in module.REQUIRED_PATHS:
            target=self.source/path.lstrip('/')
            if path in ['/opt/bojiclub-account','/opt/bojiclub-ai','/etc/nginx']:
                target.mkdir(parents=True,exist_ok=True);(target/'fixture.txt').write_text('synthetic fixture')
            else:target.parent.mkdir(parents=True,exist_ok=True);target.write_text('synthetic recovery file')
        ai=self.source/'opt/bojiclub-ai/.data/jobs.sqlite3';ai.parent.mkdir(parents=True)
        with sqlite3.connect(ai) as db:db.execute('CREATE TABLE fixture (id INTEGER)');db.execute('INSERT INTO fixture VALUES(1)')
        bindir=self.folder/'bin';bindir.mkdir();self.dump=bindir/'mysqldump';self.dump.write_text('#!/bin/sh\nprintf "CREATE TABLE synthetic_fixture(id INT);\\n"\n');self.dump.chmod(0o700)
        self.env={**os.environ,'BOJI_BACKUP_SOURCE_ROOT':str(self.source),'BOJI_BACKUP_ROOT':str(self.state),'BOJI_BACKUP_DEST':str(self.dest),'BOJI_BACKUP_STATUS_FILE':str(self.status),'BOJI_BACKUP_PASSWORD_FILE':str(self.password),'PATH':str(bindir)+os.pathsep+os.environ['PATH']}

    def tearDown(self):self.temp.cleanup()
    def run_backup(self,*args,ok=True):
        result=subprocess.run([sys.executable,str(BACKUP),*args],env=self.env,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode==0,ok,result.stderr)
        return result
    def read_status(self):return json.loads(self.status.read_text())

    def test_unknown_is_not_reported_as_no_backup_or_success(self):
        self.run_backup('--status-only');state=self.read_status()
        self.assertEqual(state['state'],'unknown');self.assertFalse(state['local_archive_present']);self.assertNotIn('last_success',state)
        self.assertFalse(state['schedule']['available'])

    def test_encrypted_archive_can_be_verified_and_publishes_safe_status(self):
        self.run_backup();state=self.read_status()
        self.assertEqual(state['state'],'succeeded');self.assertTrue(state['local_archive_present']);self.assertTrue(state['encrypted'])
        self.assertFalse(state['restore_verified']) # File creation is not a production restore drill.
        self.assertNotIn('path',state);self.assertNotIn('key_fingerprint',state)
        self.assertNotIn(self.password.read_text(),self.status.read_text())
        self.assertEqual(self.status.stat().st_mode&0o777,0o644)
        archive=next(self.dest.glob('*.boji'))
        verified=subprocess.run([sys.executable,str(RESTORE),str(archive),'--password-file',str(self.password)],capture_output=True,text=True,timeout=30)
        self.assertEqual(verified.returncode,0,verified.stderr)
        self.assertFalse(list(self.state.glob('boji-backup-*')),'plaintext work directory was not removed')

    def test_failure_persists_readable_code_and_keeps_previous_success(self):
        self.run_backup();before=self.read_status()['last_success'];self.password.unlink()
        self.run_backup(ok=False);state=self.read_status()
        self.assertEqual(state['state'],'failed');self.assertEqual(state['last_error_code'],'password_missing')
        self.assertEqual(state['last_success'],before);self.assertTrue(state['local_archive_present'])

    def test_recovery_includes_other_signing_keys_and_alert_units_once(self):
        key=self.source/'etc/bojiclub/apns.p8';key.write_text('synthetic push signing key')
        unit=self.source/'etc/systemd/system/operations-alerts.service';unit.write_text('[Service]\nExecStart=/usr/bin/false\n')
        self.run_backup();archive=next(self.dest.glob('*.boji'));target=self.folder/'extracted'
        result=subprocess.run([sys.executable,str(RESTORE),str(archive),'--password-file',str(self.password),'--apply','--target',str(target)],capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((target/'etc/bojiclub/apns.p8').read_text(),'synthetic push signing key')
        self.assertTrue((target/'etc/systemd/system/operations-alerts.service').is_file())

    def test_mac_ack_and_restore_drill_bind_to_the_current_archive(self):
        self.run_backup();record=json.loads((self.state/'backup-result.json').read_text());archive=Path(record['path'])
        import hashlib
        key_sha=hashlib.sha256(self.password.read_text().strip().encode()).hexdigest()
        ack={'state':'receiver_verified','archive':archive.name,'sha256':record['sha256'],'bytes':archive.stat().st_size,'key_sha256':key_sha,'confirmed_at':'2026-10-28T10:00:00+00:00'}
        (self.state/'offsite-mac-ack.json').write_text(json.dumps(ack))
        drill={'status':'passed','archive':archive.name,'sha256':record['sha256'],'isolation':{'state':'passed'},'cleanup_complete':True,'checked_at':'2026-10-28T10:01:00+00:00'}
        (self.status.parent/'restore-drill-status.json').write_text(json.dumps(drill))
        self.run_backup('--status-only');state=self.read_status();self.assertEqual(state['offsite_copy'],'ok');self.assertTrue(state['restore_verified'])
        ack['sha256']='0'*64;drill['sha256']='0'*64
        (self.state/'offsite-mac-ack.json').write_text(json.dumps(ack));(self.status.parent/'restore-drill-status.json').write_text(json.dumps(drill))
        self.run_backup('--status-only');state=self.read_status();self.assertNotEqual(state['offsite_copy'],'ok');self.assertFalse(state['restore_verified'])

    def test_dump_failure_does_not_claim_success(self):
        self.dump.write_text('#!/bin/sh\nexit 1\n');self.run_backup(ok=False)
        self.assertEqual(self.read_status()['last_error_code'],'database_dump_failed')
        self.assertFalse(list(self.dest.glob('*.boji')))

    def test_missing_ai_database_is_a_real_failure(self):
        (self.source/'opt/bojiclub-ai/.data/jobs.sqlite3').unlink();self.run_backup(ok=False)
        self.assertEqual(self.read_status()['last_error_code'],'ai_database_missing')

    def test_offsite_failure_is_separate_from_local_backup(self):
        self.env['BOJI_OFFSITE_CMD']='false';self.run_backup();state=self.read_status()
        self.assertEqual(state['state'],'succeeded');self.assertTrue(state['local_archive_present']);self.assertEqual(state['offsite_copy'],'failed')

    def test_offsite_timeout_keeps_the_valid_local_recovery_set(self):
        real_run=subprocess.run
        def run(command,*args,**kwargs):
            if command[0]=='sh':raise subprocess.TimeoutExpired(command,900)
            return real_run(command,*args,**kwargs)
        with mock.patch.dict(os.environ,{**self.env,'BOJI_OFFSITE_CMD':'synthetic-offsite'}),mock.patch.object(module.subprocess,'run',side_effect=run):
            with mock.patch('builtins.print'):
                self.assertEqual(module.backup(Namespace(dry_run=False)),0)
        result=json.loads((self.state/'backup-result.json').read_text())
        self.assertEqual(result['offsite_copy'],'failed');self.assertTrue(Path(result['path']).is_file())

    def test_monitor_detects_deleted_archive(self):
        self.run_backup();next(self.dest.glob('*.boji')).unlink();self.run_backup('--status-only');state=self.read_status()
        self.assertEqual(state['state'],'failed');self.assertEqual(state['last_error_code'],'archive_missing')

if __name__=='__main__':unittest.main(verbosity=2)
