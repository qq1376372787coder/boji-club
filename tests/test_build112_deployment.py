"""Real submission and batch-isolation regressions; synthetic temporary storage only."""
from pathlib import Path
import json
import sys
import tempfile
import threading
import unittest
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import automation_core
from ai_core import AIError, Router, validate_request
from server import JobStore, make_server
from test_adaptive_automation import body, STAMP, KEY
from test_phase1_v18 import sample


class Build112DeploymentTests(unittest.TestCase):
    def test_bad_daily_context_does_not_discard_valid_workout_followup(self):
        request = body()
        request['settings']['workout'] = True
        deferred = []

        def normalize(raw):
            if raw['kind'] == 'report':
                raise AIError('invalid_request', 'Synthetic unavailable daily context')
            return validate_request(raw)

        jobs = automation_core.prepare(request, normalize, STAMP, on_skip=deferred.append)
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]['request']['kind'], 'coach')
        self.assertEqual(deferred, [{'mode': 'daily', 'date': KEY, 'status': 'context_unavailable'}])

    def test_report_submission_recomputes_revision_and_reaches_the_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            store = JobStore(Path(directory) / 'jobs.sqlite3')
            token = 'synthetic-build112-internal-test-token'
            http = make_server(store, Router([]), token, port=0)
            worker = threading.Thread(target=http.serve_forever, daemon=True)
            worker.start()
            try:
                raw = sample()
                raw['id'] = str(uuid.uuid4())
                raw['source_revision'] = 'untrusted-client-value'
                expected = automation_core.source_revision(validate_request(raw)['payload'])
                request = urllib.request.Request(
                    'http://127.0.0.1:%d/v1/jobs' % http.server_port,
                    data=json.dumps(raw).encode(), method='POST',
                    headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
                with urllib.request.urlopen(request, timeout=4) as response:
                    self.assertEqual(response.status, 202)
                    self.assertEqual(json.load(response)['id'], raw['id'])
                with store.connect() as db:
                    audit = json.loads(db.execute('SELECT summary FROM task_audits WHERE job_id=?', (raw['id'],)).fetchone()[0])
                    self.assertEqual(audit['source_revision'], expected)
            finally:
                http.shutdown()
                http.server_close()
                worker.join(4)
