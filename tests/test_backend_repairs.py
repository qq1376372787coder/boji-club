"""Retention and administrative filtering regression on synthetic SQLite data."""
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from server import JobStore
from ai_core import AIError

class BackendRepairTests(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory()
        self.store=JobStore(Path(self.folder.name)/'jobs.sqlite3')
    def tearDown(self):self.folder.cleanup()
    def insert(self,kind='food',status='failed',created=None):
        job=str(uuid.uuid4());now=time.time()
        with self.store.connect() as db:
            db.execute("INSERT INTO jobs(id,fingerprint,kind,payload,status,created,updated,next_run) VALUES(?,?,?,?,?,?,?,?)",(job,'fixture',kind,'{"private":"fixture"}',status,created or now,created or now,now))
            db.execute('INSERT INTO task_audits(job_id,created,expires,summary) VALUES(?,?,?,?)',(job,now,now+60,'{}'))
        return job
    def test_filters_match_real_worker_kinds(self):
        for kind in ['generate_plan','parse_plan','food','report','weekly_review']:self.insert(kind=kind)
        for kind in ['generate_plan','parse_plan','food','report','weekly_review']:
            self.assertEqual([x['kind'] for x in self.store.admin_tasks(kind=kind)['items']],[kind])
    def test_delete_clears_task_audit(self):
        job=self.insert();self.store.delete_private(job)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM task_audits WHERE job_id=?',(job,)).fetchone()[0],0)
    def test_retention_clears_failed_photo_input_and_blocks_empty_retry(self):
        job=self.insert(created=time.time()-8*86400);self.store.cleanup()
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT payload FROM jobs WHERE id=?',(job,)).fetchone()[0],'{}')
        with self.assertRaises(AIError):self.store.retry(job)
    def test_old_result_is_removed_without_new_task_creation(self):
        job=self.insert(status='succeeded',created=time.time()-31*86400)
        with self.store.connect() as db:db.execute('UPDATE jobs SET result=? WHERE id=?',('{"private":"fixture"}',job))
        self.store.cleanup();value=self.store.get(job)
        self.assertEqual(value['status'],'deleted');self.assertIsNone(value['result'])

if __name__=='__main__':unittest.main()
