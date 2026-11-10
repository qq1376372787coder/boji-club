"""Runtime limits, concurrent admission and Beijing-day counters on isolated data."""
import concurrent.futures,json,sys,tempfile,threading,time,unittest,urllib.request,urllib.error
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from server import JobStore,make_server
from ai_core import AIError

def request():
    return {'kind':'food','date':'2026-10-12','payload':{'source':'text','description':'两个鸡蛋','meal_category':'早餐'}}

class CapacityTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=JobStore(Path(self.tmp.name)/'db')
    def tearDown(self):self.tmp.cleanup()
    def test_new_defaults_allow_more_than_200_daily_jobs(self):
        self.assertEqual(self.store.settings(),{'daily_limit':0,'pending_limit':800,'worker_limit':3,'account_daily_limit':0,'account_pending_limit':8,'accepting':True})
        for i in range(220):self.store.create(str(i),request())
        self.assertEqual(self.store.live_stats()['today_received'],220)
    def test_eight_hundred_boundary_and_duplicate_id(self):
        for i in range(800):self.store.create(str(i),request())
        self.assertEqual(self.store.create('0',request())['id'],'0')
        with self.assertRaises(AIError) as caught:self.store.create('overflow',request())
        self.assertEqual(caught.exception.code,'capacity')
        self.store.update_settings({'pending_limit':801})
        self.store.create('overflow',request())
    def test_limits_hot_update_persist_and_can_be_disabled(self):
        self.store.update_settings({'daily_limit':1,'pending_limit':1})
        self.store.create('one',request())
        self.store.update_settings({'daily_limit':0,'pending_limit':0,'worker_limit':3,'account_daily_limit':0,'account_pending_limit':8})
        self.store.create('two',request())
        other=JobStore(self.store.path)
        self.assertEqual(other.capacity_settings(),{'daily_limit':0,'pending_limit':0,'worker_limit':3,'account_daily_limit':0,'account_pending_limit':8})
    def test_daily_limit_and_midnight_use_beijing_day(self):
        self.store.update_settings({'daily_limit':1})
        # 2026-10-11 15:59:59 UTC and the next second: Beijing midnight.
        from datetime import datetime,timezone
        before=datetime(2026,10,11,15,59,59,tzinfo=timezone.utc).timestamp()
        with patch('server.time.time',return_value=before):
            self.store.create('one',request())
            self.store.complete('one',{},'fixture','fixture')
            with self.assertRaises(AIError) as caught:self.store.create('two',request())
            self.assertEqual(caught.exception.code,'daily_capacity')
        with patch('server.time.time',return_value=before+1):
            self.store.create('two',request())
            self.assertEqual(self.store.live_stats()['today_received'],1)
    def test_invalid_settings_are_atomic(self):
        for bad in [-1,1.5,True,'800',None,2147483648]:
            with self.assertRaises(ValueError):self.store.update_settings({'daily_limit':12,'pending_limit':bad})
            self.assertEqual(self.store.capacity_settings(),{'daily_limit':0,'pending_limit':800,'worker_limit':3,'account_daily_limit':0,'account_pending_limit':8})
        for bad in [{},{'unknown':1},{'accepting':1}]:
            with self.assertRaises(ValueError):self.store.update_settings(bad)
    def test_concurrent_requests_cannot_oversubscribe(self):
        self.store.update_settings({'pending_limit':5})
        def submit(i):
            try:self.store.create(str(i),request());return True
            except AIError as e:self.assertEqual(e.code,'capacity');return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            self.assertEqual(sum(pool.map(submit,range(24))),5)
        self.assertEqual(self.store.live_stats()['pending'],5)
    def test_lowering_limit_preserves_existing_jobs_and_retry_enforces_it(self):
        for i in range(3):self.store.create(str(i),request())
        self.store.fail('0',AIError('synthetic','fixture'),3)
        self.store.update_settings({'pending_limit':1})
        self.assertEqual(self.store.live_stats()['pending'],2)
        with self.assertRaises(AIError):self.store.retry('0')
        self.store.update_settings({'pending_limit':3})
        self.assertTrue(self.store.retry('0')['retry_started'])
    def test_completed_counts_are_tasks_not_attempts_and_survive_retry(self):
        self.store.create('one',request())
        self.store.fail('one',AIError('synthetic','fixture'),3)
        self.assertEqual(self.store.live_stats()['today_failed'],1)
        self.store.retry('one')
        self.assertEqual(self.store.live_stats()['today_processed'],1)
        self.store.complete('one',{'kind':'meal'},'fixture','fixture')
        stats=self.store.live_stats()
        self.assertEqual((stats['today_processed'],stats['today_succeeded'],stats['today_failed']),(1,1,0))
        self.store.complete('one',{'kind':'meal'},'fixture','fixture')
        self.assertEqual(self.store.live_stats()['today_processed'],1)
    def test_completion_of_yesterday_task_counts_today(self):
        self.store.create('old',request())
        with self.store.connect() as db:db.execute('UPDATE jobs SET created=? WHERE id=?',(time.time()-86400,'old'))
        self.store.complete('old',{'kind':'meal'},'fixture','fixture')
        stats=self.store.live_stats();self.assertEqual(stats['today_received'],0);self.assertEqual(stats['today_processed'],1)
    def test_lease_protection_prevents_false_completion_counter(self):
        self.store.create('one',request());claimed=self.store.claim()
        self.assertFalse(self.store.complete('one',{},'fixture','fixture','wrong-token'))
        self.assertEqual(self.store.live_stats()['today_processed'],0)
        self.assertTrue(self.store.complete('one',{},'fixture','fixture',claimed[3]))
    def test_delete_removes_operational_linkage(self):
        self.store.create('one',request());self.store.complete('one',{},'fixture','fixture')
        self.store.delete_private('one')
        self.assertEqual(self.store.live_stats()['today_processed'],1)
    def test_metrics_and_settings_http_require_internal_auth(self):
        service=make_server(self.store,None,'synthetic-internal-token',port=0)
        thread=threading.Thread(target=service.serve_forever,daemon=True);thread.start()
        try:
            url='http://127.0.0.1:'+str(service.server_port)
            for path in ['/v1/admin/ai/live','/v1/admin/ai/settings']:
                with self.assertRaises(urllib.error.HTTPError) as caught:urllib.request.urlopen(url+path)
                self.assertEqual(caught.exception.code,404)
            headers={'Authorization':'Bearer synthetic-internal-token','Content-Type':'application/json'}
            req=urllib.request.Request(url+'/v1/admin/ai/settings',data=json.dumps({'daily_limit':0,'pending_limit':800,'worker_limit':3,'account_daily_limit':0,'account_pending_limit':8}).encode(),headers=headers)
            with urllib.request.urlopen(req) as response:self.assertEqual(json.load(response)['pending_limit'],800)
            req=urllib.request.Request(url+'/v1/admin/ai/live',headers=headers)
            with urllib.request.urlopen(req) as response:self.assertEqual(json.load(response)['timezone'],'Asia/Shanghai')
        finally:service.shutdown();service.server_close();thread.join(2)

if __name__=='__main__':unittest.main(verbosity=2)
