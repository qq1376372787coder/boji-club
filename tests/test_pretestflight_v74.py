"""Live submission boundaries: no provider calls, synthetic SQLite and loopback HTTP."""
import copy, datetime as dt, json, sys, tempfile, threading, unittest, uuid
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request, urlopen
from urllib.error import HTTPError
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import ai_core as core
import server
from test_backend_v2 import request

NOW = dt.datetime(2026, 10, 13, 16, 30, tzinfo=dt.timezone.utc)

def plan(date='2026-10-14', zone='Asia/Shanghai'):
    value = request()
    value['date'] = date
    if zone is not None: value['payload']['timeZone'] = zone
    return core.validate_request(value)

class NewPlanBoundaryTests(unittest.TestCase):
    def test_local_today_accepted(self):
        core.validate_new_plan_start(plan(), NOW)

    def test_local_yesterday_rejected(self):
        with self.assertRaises(core.AIError) as error:
            core.validate_new_plan_start(plan('2026-10-13'), NOW)
        self.assertEqual(error.exception.code, 'plan_date_expired')

    def test_future_start_accepted(self):
        core.validate_new_plan_start(plan('2027-01-01'), NOW)

    def test_western_local_today_not_rejected_as_asian_yesterday(self):
        core.validate_new_plan_start(plan('2026-10-13', 'America/Los_Angeles'), NOW)

    def test_eastern_tomorrow_is_local_today(self):
        core.validate_new_plan_start(plan('2026-10-14', 'Pacific/Kiritimati'), NOW)

    def test_legacy_client_without_zone_uses_earliest_real_date(self):
        core.validate_new_plan_start(plan('2026-10-13', None), NOW)
        with self.assertRaises(core.AIError):
            core.validate_new_plan_start(plan('2026-10-12', None), NOW)

    def test_unknown_zone_rejected_before_provider(self):
        with self.assertRaises(core.AIError): plan(zone='Not/AZone')

    def test_clean_request_keeps_zone_and_drops_arbitrary_input(self):
        raw = request(); raw['payload'].update(timeZone='Asia/Shanghai', secret='never forwarded')
        clean = core.validate_request(raw)
        self.assertEqual(clean['payload']['timeZone'], 'Asia/Shanghai')
        self.assertNotIn('secret', clean['payload'])

    def test_historical_plan_import_is_not_blocked(self):
        raw = request(); raw['kind'] = 'parse_plan'; raw['payload']['text'] = '周一卧推三组'
        clean = core.validate_request(raw)
        core.validate_new_plan_start(clean, NOW)

    def test_stored_historical_result_validation_remains_supported(self):
        self.assertEqual(core.validate_request(request())['date'], '2026-09-30')

    def test_rejection_does_not_create_or_reserve_task(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            job_id = str(uuid.uuid4())
            with self.assertRaises(core.AIError):
                store.create(job_id, plan('2000-01-01'), enforce_plan_date=True)
            self.assertIsNone(store.get(job_id))
            with store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)

    def test_idempotent_recovery_after_midnight_is_not_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            job_id = str(uuid.uuid4()); value = plan()
            with patch.object(server, 'validate_new_plan_start', lambda r: core.validate_new_plan_start(r, NOW)):
                first = store.create(job_id, value, enforce_plan_date=True)
            with patch.object(server, 'validate_new_plan_start', side_effect=AssertionError('must recover, not revalidate new date')):
                recovered = store.create(job_id, value, enforce_plan_date=True)
            self.assertEqual(first['id'], recovered['id'])
            with store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 1)

    def test_expired_new_request_cannot_reuse_different_input_id(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            job_id = str(uuid.uuid4()); first = plan('2028-01-01')
            store.create(job_id, first, enforce_plan_date=True)
            with self.assertRaises(core.AIError) as error:
                store.create(job_id, plan('2000-01-01'), enforce_plan_date=True)
            self.assertEqual(error.exception.code, 'id_conflict')

    def test_expired_failed_plan_is_not_requeued_by_manual_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            job_id = str(uuid.uuid4())
            store.create(job_id, plan('2000-01-01'))  # Existing historical job from the old server.
            with store.connect() as db:
                db.execute("UPDATE jobs SET status='failed' WHERE id=?", (job_id,))
            with self.assertRaises(core.AIError):
                store.retry(job_id, enforce_plan_date=True)
            self.assertEqual(store.get(job_id)['status'], 'failed')

    def test_retry_does_not_restart_already_queued_plan_after_midnight(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            job_id = str(uuid.uuid4())
            store.create(job_id, plan('2000-01-01'))
            value = store.retry(job_id, enforce_plan_date=True)
            self.assertEqual(value['status'], 'queued')
            self.assertFalse(value['retry_started'])

    def test_live_http_endpoint_rejects_past_before_queueing(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            token = 'synthetic-private-test-token-74'
            http = server.make_server(store, None, token, port=0)
            thread = threading.Thread(target=http.serve_forever, daemon=True); thread.start()
            try:
                value = plan('2000-01-01'); value['id'] = str(uuid.uuid4())
                req = Request(f'http://127.0.0.1:{http.server_port}/v1/jobs',
                    data=json.dumps(value).encode(), headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
                with self.assertRaises(HTTPError) as error: urlopen(req, timeout=5)
                self.assertEqual(error.exception.code, 400)
                self.assertEqual(json.loads(error.exception.read())['code'], 'plan_date_expired')
                self.assertIsNone(store.get(value['id']))
            finally: http.shutdown(); http.server_close(); thread.join(timeout=2)

if __name__ == '__main__': unittest.main()
