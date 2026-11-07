"""Recovery regressions using temporary databases and synthetic inputs only."""
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
from ai_core import AIError
import server


def request():
    return {'kind': 'report', 'date': '2026-10-04', 'payload': {'exercises': [], 'meals': [], 'health': None}}


class WorkerRecovery(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = server.JobStore(Path(self.directory.name) / 'jobs.sqlite3')
        self.store.create('synthetic-job', request())

    def expire_lease(self):
        with self.store.connect() as db:
            db.execute('UPDATE jobs SET updated=?', (time.time() - self.store.RUN_LEASE_SECONDS - 1,))

    def test_stale_worker_cannot_overwrite_reclaimed_result(self):
        old = self.store.claim()
        self.expire_lease()
        new = self.store.claim()
        self.assertNotEqual(old[3], new[3])
        self.assertFalse(self.store.complete(old[0], {'old': True}, 'fixture', 'fixture', old[3]))
        self.assertFalse(self.store.fail(old[0], AIError('old', 'fixture'), old[2], old[3]))
        self.assertTrue(self.store.complete(new[0], {'new': True}, 'fixture', 'fixture', new[3]))
        self.assertEqual(self.store.get(old[0])['result'], {'new': True})

    def test_heartbeat_keeps_active_worker_from_being_reclaimed(self):
        item = self.store.claim()
        self.expire_lease()
        self.assertTrue(self.store.heartbeat(item[0], item[3]))
        self.assertIsNone(self.store.claim())

    def test_delete_wins_over_heartbeat_and_late_completion(self):
        item = self.store.claim()
        self.store.delete_private(item[0])
        self.assertFalse(self.store.heartbeat(item[0], item[3]))
        self.assertFalse(self.store.complete(item[0], {'late': True}, 'fixture', 'fixture', item[3]))
        self.assertEqual(self.store.get(item[0])['status'], 'deleted')

    def test_storage_failure_is_reclaimed_without_restart(self):
        class Router:
            def run(self, request, audit):
                return {'kind': 'report'}, 'fixture', 'fixture'
        worker = server.Workers(self.store, Router())
        self.addCleanup(worker.pool.shutdown)
        item = self.store.claim()
        with worker.condition: worker.active += 1
        with patch.object(self.store, 'complete', side_effect=sqlite3.OperationalError('fixture')), \
             patch.object(self.store, 'fail', side_effect=sqlite3.OperationalError('fixture')), \
             patch.object(worker.stop, 'wait', return_value=False):
            worker.run(item)
        self.assertEqual(worker.active, 0)
        self.assertEqual(self.store.get(item[0])['status'], 'running')
        self.expire_lease()
        recovered = self.store.claim()
        self.assertIsNotNone(recovered)
        self.assertEqual(recovered[2], 2)

    def test_interrupted_runs_stop_after_three_attempts(self):
        for _ in range(3):
            self.assertIsNotNone(self.store.claim())
            self.expire_lease()
        self.assertIsNone(self.store.claim())
        self.assertEqual(self.store.get('synthetic-job')['status'], 'failed')


if __name__ == '__main__':
    unittest.main(verbosity=2)
