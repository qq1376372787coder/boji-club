"""Real SQLite retry transitions, including simultaneous reconnect requests."""
import concurrent.futures, tempfile, time, unittest, uuid, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from server import JobStore
from ai_core import AIError

class RetryBilling(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory()
        self.store=JobStore(Path(self.folder.name)/'jobs.sqlite3')
    def tearDown(self): self.folder.cleanup()
    def job(self,status,payload='{"kind":"food"}'):
        ident=str(uuid.uuid4());now=time.time()
        with self.store.connect() as db:
            db.execute('INSERT INTO jobs(id,fingerprint,kind,payload,status,created,updated,next_run) VALUES(?,?,?,?,?,?,?,?)',(ident,'test','food',payload,status,now,now,now))
        return ident
    def test_reconnect_does_not_start_or_charge_existing_work(self):
        for status in ['queued','running','retrying','succeeded','deleted']:
            with self.subTest(status=status):
                ident=self.job(status)
                self.assertFalse(self.store.retry(ident)['retry_started'])
                self.assertEqual(self.store.get(ident)['status'],status)
    def test_failed_job_can_start_only_once_during_concurrent_reconnect(self):
        ident=self.job('failed')
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(lambda _:self.store.retry(ident),range(8)))
        self.assertEqual(sum(r['retry_started'] for r in results),1)
        self.assertEqual(self.store.get(ident)['status'],'queued')
    def test_expired_input_is_not_a_billable_restart(self):
        ident=self.job('failed','{}')
        with self.assertRaises(AIError): self.store.retry(ident)
        self.assertEqual(self.store.get(ident)['status'],'failed')
    def test_maintenance_leaves_failed_job_unchanged(self):
        ident=self.job('failed');self.store.set_accepting(False)
        with self.assertRaises(AIError):self.store.retry(ident)
        self.assertEqual(self.store.get(ident)['status'],'failed')
    def test_unknown_job_does_not_create_work(self):
        self.assertIsNone(self.store.retry(str(uuid.uuid4())))

if __name__=='__main__': unittest.main()
