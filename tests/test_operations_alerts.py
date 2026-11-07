"""Operational alert checks with synthetic databases and fake HTTP/SMTP only."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT/'account-server/deploy/operations-alerts.py'
spec = importlib.util.spec_from_file_location('operations_alerts', SCRIPT)
alerts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alerts)


class Response:
    status = 200
    def __init__(self, data): self.data = json.dumps(data).encode()
    def read(self, limit): return self.data[:limit]
    def __enter__(self): return self
    def __exit__(self, *args): return False


class OperationsAlertsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name)
        self.now = 1800000000
        self.config = dict(alerts.DEFAULTS)
        self.config.update(ai_sqlite=str(self.path/'jobs.sqlite3'), backup_status=str(self.path/'backup.json'))
        self.fault = alerts.check('disk_space', '服务器磁盘空间不足', True, '剩余空间不足。', 'critical')
        self.ok = {**self.fault, 'fault': False}
        self.unknown = {**self.fault, 'fault': None}
        self.external = {**self.config, 'notifications': {'enabled': True, 'webhook': {'url': 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=SYNTHETIC_SECRET'}}}
    def tearDown(self): self.temp.cleanup()
    def sqlite_fixture(self, failed=5, total=20):
        with sqlite3.connect(self.config['ai_sqlite']) as db:
            db.execute('CREATE TABLE jobs(status TEXT, updated REAL, payload TEXT)')
            db.executemany('INSERT INTO jobs VALUES(?,?,?)', [('failed' if n < failed else 'succeeded', self.now-60, 'PRIVATE_USER_TEXT') for n in range(total)])
            db.execute('INSERT INTO jobs VALUES(?,?,?)', ('failed', self.now-86400, 'OLD_PRIVATE_TEXT'))
            db.execute('INSERT INTO jobs VALUES(?,?,?)', ('running', self.now-10, 'RUNNING_PRIVATE_TEXT'))

    def test_default_is_dashboard_only_even_when_caller_allows(self):
        with mock.patch.object(alerts, 'send_webhook') as send:
            state = alerts.reconcile({}, [self.fault], self.config, True, self.now)
        send.assert_not_called()
        public = alerts.public_snapshot(state, [self.fault], self.config, True, self.now)
        self.assertEqual(public['mode'], 'dashboard_only')
        self.assertEqual(public['active_count'], 1)
        self.assertEqual(public['events'][0]['status'], 'active')

    def test_both_config_and_cli_opt_in_are_required(self):
        for config, allow in [(self.external, False), ({**self.external, 'notifications': {**self.external['notifications'], 'enabled': 'false'}}, True)]:
            with mock.patch.object(alerts, 'send_webhook') as send:
                alerts.reconcile({}, [self.fault], config, allow, self.now)
            send.assert_not_called()

    def test_deduplicates_cooldown_and_one_recovery_then_reopens(self):
        with mock.patch.object(alerts, 'send_webhook') as send:
            state = alerts.reconcile({}, [self.fault], self.external, True, self.now)
            first_id = state['events'][0]['id']
            state = alerts.reconcile(state, [self.fault], self.external, True, self.now+300)
            self.assertEqual(len(state['events']), 1); self.assertEqual(send.call_count, 1)
            state = alerts.reconcile(state, [self.fault], self.external, True, self.now+21601)
            self.assertEqual(send.call_count, 2)
            state = alerts.reconcile(state, [self.ok], self.external, True, self.now+21900)
            self.assertEqual(send.call_count, 3); self.assertEqual(state['events'][0]['status'], 'recovered')
            state = alerts.reconcile(state, [self.ok], self.external, True, self.now+23000)
            self.assertEqual(send.call_count, 3)
            state = alerts.reconcile(state, [self.fault], self.external, True, self.now+24000)
            self.assertEqual(send.call_count, 4); self.assertEqual(len(state['events']), 2)
            self.assertNotEqual(state['events'][0]['id'], first_id)

    def test_unknown_does_not_recover_and_failure_retries_are_honest(self):
        with mock.patch.object(alerts, 'send_webhook', side_effect=OSError('secret URL and credentials')) as send:
            state = alerts.reconcile({}, [self.fault], self.external, True, self.now)
            state = alerts.reconcile(state, [self.unknown], self.external, True, self.now+100)
            self.assertEqual(state['events'][0]['status'], 'active'); self.assertEqual(send.call_count, 1)
            state = alerts.reconcile(state, [self.fault], self.external, True, self.now+901)
            self.assertEqual(send.call_count, 2)
        public = alerts.public_snapshot(state, [self.unknown], self.external, True, self.now+901)
        delivery = public['events'][0]['notifications']['webhook']
        self.assertEqual(delivery['state'], 'failed'); self.assertEqual(delivery['attempts'], 2)
        self.assertEqual(public['unknown_count'], 1)
        self.assertNotIn('secret', json.dumps(public).lower())
        self.assertNotIn('attempted_at_epoch', json.dumps(public))

    def test_recovery_retry_and_no_replay_when_enabling_late(self):
        with mock.patch.object(alerts, 'send_webhook') as send:
            state = alerts.reconcile({}, [self.fault], self.config, False, self.now)
            state = alerts.reconcile(state, [self.ok], self.config, False, self.now+300)
            alerts.reconcile(state, [self.ok], self.external, True, self.now+600)
        send.assert_not_called()
        with mock.patch.object(alerts, 'send_webhook') as send:
            state = alerts.reconcile({}, [self.fault], self.external, True, self.now)
            send.side_effect = OSError('fake network failure')
            state = alerts.reconcile(state, [self.ok], self.external, True, self.now+300)
            send.side_effect = None
            state = alerts.reconcile(state, [self.ok], self.external, True, self.now+1201)
            self.assertEqual(send.call_count, 3)
            self.assertEqual(state['events'][0]['notifications']['recovered']['webhook']['state'], 'accepted')

    def test_real_sqlite_aggregates_only_recent_terminal_metadata(self):
        self.sqlite_fixture()
        fake = mock.Mock(); fake.open.return_value = Response({'status': 'ok', 'secret': 'PRIVATE'})
        with mock.patch.object(alerts.urllib.request, 'build_opener', return_value=fake):
            result = {c['key']: c for c in alerts.ai_checks(self.config, self.now)}
        self.assertFalse(result['ai_service']['fault']); self.assertFalse(result['ai_database']['fault'])
        self.assertTrue(result['ai_failure_rate']['fault']); self.assertIn('20 次', result['ai_failure_rate']['detail'])
        self.assertNotIn('PRIVATE', json.dumps(result))
        with sqlite3.connect(self.config['ai_sqlite']) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 22)

    def test_missing_sqlite_never_created_and_rate_is_unknown(self):
        fake = mock.Mock(); fake.open.side_effect = OSError('fake')
        with mock.patch.object(alerts.urllib.request, 'build_opener', return_value=fake):
            result = {c['key']: c for c in alerts.ai_checks(self.config, self.now)}
        self.assertTrue(result['ai_service']['fault']); self.assertTrue(result['ai_database']['fault'])
        self.assertIsNone(result['ai_failure_rate']['fault']); self.assertFalse(Path(self.config['ai_sqlite']).exists())

    def test_mysql_uses_aggregate_read_only_and_fails_visible(self):
        result = subprocess.CompletedProcess([], 0, stdout='1\n4\t20\n', stderr='')
        with mock.patch.object(alerts.subprocess, 'run', return_value=result) as run:
            checks = alerts.mysql_checks(self.config, self.now)
        self.assertFalse(checks[0]['fault']); self.assertTrue(checks[1]['fault'])
        command = run.call_args.args[0]
        self.assertIn('--protocol=socket', command)
        self.assertNotIn('user_id', command[-1]); self.assertNotIn('request_json', command[-1])
        with mock.patch.object(alerts.subprocess, 'run', side_effect=OSError('fake')):
            checks = alerts.mysql_checks(self.config, self.now)
        self.assertTrue(checks[0]['fault']); self.assertIsNone(checks[1]['fault'])

    def test_rate_requires_samples_and_recovers_below_threshold(self):
        self.assertFalse(alerts.rate_check('x', 'x', 3, 3, self.config)['fault'])
        self.assertTrue(alerts.rate_check('x', 'x', 4, 20, self.config)['fault'])
        self.assertFalse(alerts.rate_check('x', 'x', 3, 20, self.config)['fault'])

    def test_backup_expiry_deleted_file_and_stale_metadata(self):
        path = Path(self.config['backup_status'])
        value = {'checked_at': alerts.timestamp(self.now), 'last_success': alerts.timestamp(self.now-100), 'local_archive_present': True, 'state': 'succeeded'}
        path.write_text(json.dumps(value))
        self.assertFalse(any(c['fault'] for c in alerts.backup_checks(self.config, self.now)))
        value['last_success'] = alerts.timestamp(self.now-27*3600); path.write_text(json.dumps(value))
        self.assertTrue(alerts.backup_checks(self.config, self.now)[1]['fault'])
        value['last_success'] = alerts.timestamp(self.now-100); value['local_archive_present'] = False; path.write_text(json.dumps(value))
        self.assertTrue(alerts.backup_checks(self.config, self.now)[1]['fault'])
        result = alerts.backup_checks(self.config, self.now+1000)
        self.assertTrue(result[0]['fault']); self.assertIsNone(result[1]['fault'])

    def test_disk_threshold_and_probe_failure_are_visible(self):
        with mock.patch.object(alerts, 'mysql_checks', return_value=[]), mock.patch.object(alerts, 'ai_checks', return_value=[]), mock.patch.object(alerts, 'backup_checks', return_value=[]), mock.patch.object(alerts, 'scheduler_checks', return_value=[]):
            with mock.patch.object(alerts.shutil, 'disk_usage', return_value=SimpleNamespace(free=1024**3, total=100*1024**3)):
                self.assertTrue(alerts.collect(self.config, self.now)[0]['fault'])
            with mock.patch.object(alerts.shutil, 'disk_usage', return_value=SimpleNamespace(free=50*1024**3, total=100*1024**3)):
                self.assertFalse(alerts.collect(self.config, self.now)[0]['fault'])
            with mock.patch.object(alerts.shutil, 'disk_usage', side_effect=OSError('fake')):
                self.assertTrue(alerts.collect(self.config, self.now)[0]['fault'])

    def test_scheduler_detects_disabled_stale_and_failed_service(self):
        timer = {'LoadState': 'loaded', 'ActiveState': 'active', 'UnitFileState': 'enabled', 'LastTriggerUSec': alerts.timestamp(self.now-60)}
        with mock.patch.object(alerts, 'TIMERS', {'fake': ('测试任务', 180)}):
            with mock.patch.object(alerts, 'unit_properties', side_effect=[timer, {'Result': 'success'}]):
                self.assertFalse(alerts.scheduler_checks(self.now, 10000)[0]['fault'])
            for variant, service in [({**timer, 'ActiveState': 'inactive'}, {}), ({**timer, 'LastTriggerUSec': alerts.timestamp(self.now-200)}, {}), (timer, {'Result': 'exit-code'})]:
                with mock.patch.object(alerts, 'unit_properties', side_effect=[variant, service]):
                    self.assertTrue(alerts.scheduler_checks(self.now, 10000)[0]['fault'])
            with mock.patch.object(alerts, 'unit_properties', side_effect=[{**timer, 'LastTriggerUSec': ''}, {}]):
                self.assertFalse(alerts.scheduler_checks(self.now, 100)[0]['fault'])

    def test_permanent_workers_replace_legacy_timer(self):
        worker = {'LoadState': 'loaded', 'ActiveState': 'active', 'UnitFileState': 'enabled'}
        with mock.patch.object(alerts, 'TIMERS', {'bojiclub-ai-runs': ('AI 对话处理', 180)}):
            with mock.patch.object(alerts, 'unit_properties', return_value=worker) as probe:
                self.assertFalse(alerts.scheduler_checks(self.now, 10000)[0]['fault'])
                self.assertEqual(probe.call_count, 2)
            with mock.patch.object(alerts, 'unit_properties', side_effect=[worker, {**worker, 'ActiveState': 'failed'}, {}, {}]):
                self.assertTrue(alerts.scheduler_checks(self.now, 10000)[0]['fault'])

    def test_webhook_validates_targets_redirects_and_api_acceptance(self):
        for url in ['http://qyapi.weixin.qq.com/cgi-bin/webhook/send', 'https://evil.example/send', 'https://qyapi.weixin.qq.com.evil.test/cgi-bin/webhook/send', 'https://user:pass@qyapi.weixin.qq.com/cgi-bin/webhook/send', 'https://qyapi.weixin.qq.com/admin', 'https://qyapi.weixin.qq.com:999/cgi-bin/webhook/send']:
            with mock.patch.object(alerts.urllib.request, 'build_opener') as opener:
                with self.assertRaises(ValueError): alerts.send_webhook({'url': url}, 'safe metadata')
                opener.assert_not_called()
        fake = mock.Mock(); fake.open.return_value = Response({'errcode': 0})
        with mock.patch.object(alerts.urllib.request, 'build_opener', return_value=fake):
            alerts.send_webhook(self.external['notifications']['webhook'], 'safe metadata')
            fake.open.return_value = Response({'errcode': 93000, 'errmsg': 'not accepted'})
            with self.assertRaises(ValueError): alerts.send_webhook(self.external['notifications']['webhook'], 'safe metadata')
        self.assertIsNone(alerts.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://evil.example'))

    def test_fake_smtp_acceptance_is_not_claimed_for_refused_recipient(self):
        config = {'host': 'smtp.example.test', 'sender': 'sender@example.test', 'recipients': ['admin@example.test'], 'port': 465}
        smtp = mock.MagicMock(); smtp.__enter__.return_value = smtp; smtp.send_message.return_value = {}
        with mock.patch.object(alerts.smtplib, 'SMTP_SSL', return_value=smtp) as connect:
            alerts.send_smtp(config, '故障元数据')
            self.assertIsNotNone(connect.call_args.kwargs['context'])
            smtp.send_message.return_value = {'admin@example.test': (550, b'rejected')}
            with self.assertRaises(ValueError): alerts.send_smtp(config, '故障元数据')
        smtp = mock.MagicMock(); smtp.__enter__.return_value = smtp; smtp.send_message.return_value = {}
        with mock.patch.object(alerts.smtplib, 'SMTP', return_value=smtp):
            alerts.send_smtp({**config, 'port': 587}, '故障元数据')
            smtp.starttls.assert_called_once()

    def test_atomic_public_and_private_permissions_no_credentials(self):
        with mock.patch.object(alerts, 'send_webhook'):
            state = alerts.reconcile({}, [self.fault], self.external, True, self.now)
        public = alerts.public_snapshot(state, [self.fault], self.external, True, self.now)
        path = self.path/'runtime'/'operations-alerts.json'
        old_umask = os.umask(0o077)
        try:
            alerts.atomic_json(path, public, 0o644)
        finally:
            os.umask(old_umask)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o755)
        alerts.atomic_json(self.path/'private'/'state.json', state, 0o600)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE((self.path/'private'/'state.json').stat().st_mode), 0o600)
        self.assertNotIn('SYNTHETIC_SECRET', path.read_text())
        self.assertNotIn('https://', path.read_text()); self.assertFalse(list(path.parent.glob('.alerts-*')))

    def test_insecure_config_and_invalid_threshold_rejected(self):
        path = self.path/'config.json'; path.write_text('{}'); path.chmod(0o644)
        with self.assertRaises(ValueError): alerts.load_config(path)
        path.chmod(0o600)
        with mock.patch.object(alerts.os, 'getuid', return_value=0):
            # The fixture may be owned by a non-root developer; patch only stat ownership.
            real = path.lstat(); safe = mock.Mock(st_mode=real.st_mode, st_uid=0)
            with mock.patch.object(Path, 'lstat', return_value=safe):
                self.assertEqual(alerts.load_config(path)['minimum_samples'], 20)
                path.write_text('{"minimum_samples":0}')
                with self.assertRaises(ValueError): alerts.load_config(path)
                for value in [{'notifications': {'enabled': True}}, {'notifications': {'enabled': True, 'webhook': {'url': 'https://evil.example/send'}}}, {'notifications': {'enabled': 'false'}}]:
                    path.write_text(json.dumps(value))
                    with self.assertRaises(ValueError): alerts.load_config(path)

    def test_config_error_is_published_and_old_active_is_not_recovered(self):
        state_dir = self.path/'state'; state_dir.mkdir()
        old = alerts.reconcile({}, [self.fault], self.config, False, self.now)
        alerts.atomic_json(state_dir/'state.json', old, 0o600)
        output = self.path/'runtime'/'operations-alerts.json'
        args = ['alerts', '--state-dir', str(state_dir), '--output', str(output)]
        with mock.patch.object(sys, 'argv', args), mock.patch.object(alerts, 'load_config', side_effect=ValueError('private config')), mock.patch.object(alerts, 'collect') as collect:
            self.assertEqual(alerts.main(), 1); collect.assert_not_called()
        value = json.loads(output.read_text())
        self.assertEqual(value['active_count'], 2)
        self.assertEqual(value['mode'], 'dashboard_only')
        self.assertIn('collector_config', [e['key'] for e in value['events']])
        self.assertEqual(stat.S_IMODE(state_dir.stat().st_mode), 0o700)

    def test_lost_private_state_is_visible_and_send_budget_is_bounded(self):
        state_dir = self.path/'state'; state_dir.mkdir(); (state_dir/'state.json').write_text('{broken')
        output = self.path/'runtime'/'operations-alerts.json'
        with mock.patch.object(sys, 'argv', ['alerts', '--state-dir', str(state_dir), '--output', str(output)]), mock.patch.object(alerts, 'load_config', return_value=self.config), mock.patch.object(alerts, 'collect', return_value=[]):
            self.assertEqual(alerts.main(), 0)
        self.assertIn('collector_state', [e['key'] for e in json.loads(output.read_text())['events']])
        with mock.patch.object(alerts, 'send_webhook') as send:
            alerts.reconcile({}, [{**self.fault, 'key': str(i)} for i in range(20)], self.external, True, self.now)
            self.assertEqual(send.call_count, 8)

    def test_php_view_escapes_event_content_and_does_not_need_sqlite(self):
        php = shutil_which('php')
        if not php: self.skipTest('PHP CLI is unavailable')
        for name in ('alerts.php', 'alerts-view.php'):
            result = subprocess.run([php, '-l', str(ROOT/'account-server/admin'/name)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        code = "function h($v){return htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');} function operationsAlertsStatus(){return ['schema_version'=>1,'checked_at'=>gmdate('c'),'events'=>[['status'=>'active','title'=>'<script>alert(1)</script>','detail'=>'<img src=x onerror=alert(1)>']]];} function operationsAlertTime($v){return 'test';} function operationsAlertDelivery($e,$m){return 'test';}"
        # Including the view normally loads its helper; use an isolated copy to inject a fake safe runtime result.
        view = (ROOT/'account-server/admin/alerts-view.php').read_text().replace("require_once __DIR__.'/alerts.php';", '')
        fixture = self.path/'view.php'; fixture.write_text('<?php '+code+' ?>'+view)
        result = subprocess.run([php, str(fixture)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('<script>', result.stdout); self.assertIn('&lt;script&gt;', result.stdout)


def shutil_which(command):
    import shutil
    return shutil.which(command)


if __name__ == '__main__': unittest.main(verbosity=2)
