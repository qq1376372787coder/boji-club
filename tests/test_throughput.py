"""Dynamic concurrency, resource protection, safe draining and operational counters."""
import sys,tempfile,threading,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from server import JobStore,Workers

MIB=1024*1024
def request():return {'kind':'food','date':'2026-10-12','payload':{'source':'text','description':'两个鸡蛋'}}
def wait_for(check,seconds=5):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if check():return
        time.sleep(.015)
    raise AssertionError('condition not reached')

class BlockingRouter:
    def __init__(self):self.gate=threading.Event();self.lock=threading.Lock();self.active=0;self.peak=0;self.calls=0
    def run(self,*_):
        with self.lock:self.active+=1;self.peak=max(self.peak,self.active);self.calls+=1
        self.gate.wait(5)
        with self.lock:self.active-=1
        return {'kind':'meal'},'fixture','fixture'

class ThroughputTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=JobStore(Path(self.tmp.name)/'jobs.db')
        self.resources={'memory_current':32*MIB,'memory_limit':512*MIB,'host_available':1024*MIB}
        self.router=BlockingRouter();self.worker=None
    def tearDown(self):
        if self.worker:
            self.worker.stop.set();self.router.gate.set();self.worker.thread.join(2);self.worker.pool.shutdown(wait=True)
        self.tmp.cleanup()
    def start(self,limit,jobs=20):
        self.store.update_settings({'worker_limit':limit})
        for i in range(jobs):self.store.create(str(i),request())
        self.worker=Workers(self.store,self.router,resource_reader=lambda:dict(self.resources))
        self.worker.thread.start()
    def test_twelve_slots_fill_without_half_second_per_job_delay(self):
        self.start(12);wait_for(lambda:self.router.calls==12)
        self.assertEqual(self.router.peak,12)
        self.assertEqual(self.store.live_stats()['running'],12)
    def test_hot_raise_from_three_to_six(self):
        self.start(3);wait_for(lambda:self.router.calls==3)
        self.store.update_settings({'worker_limit':6});wait_for(lambda:self.router.calls==6)
        self.assertEqual(self.router.peak,6)
    def test_hot_lower_does_not_cancel_running_or_start_more(self):
        self.start(6);wait_for(lambda:self.router.calls==6)
        self.store.update_settings({'worker_limit':2});wait_for(lambda:self.worker.configured_limit==2)
        self.assertEqual(self.router.active,6);self.assertEqual(self.router.calls,6)
        self.router.gate.set();wait_for(lambda:self.store.live_stats()['pending']==0)
        self.assertEqual(self.store.live_stats()['today_succeeded'],20)
        self.assertEqual(self.router.calls,20)
    def test_low_host_memory_pauses_and_recovers(self):
        self.resources['host_available']=64*MIB;self.start(8)
        time.sleep(.2);self.assertEqual(self.router.calls,0)
        self.assertEqual(self.store.live_stats()['runtime']['pause_reason'],'host_memory')
        self.resources['host_available']=512*MIB;wait_for(lambda:self.router.calls==8)
    def test_high_process_memory_pauses_and_recovers(self):
        self.start(4);wait_for(lambda:self.router.calls==4)
        self.resources['memory_current']=440*MIB
        self.assertEqual(self.worker.snapshot()['pause_reason'],'ai_memory')
        self.router.gate.set();time.sleep(.25)
        calls=self.router.calls;self.assertEqual(calls,4)
        self.resources['memory_current']=32*MIB;wait_for(lambda:self.store.live_stats()['pending']==0)
    def test_memory_budget_limits_32_configured_slots(self):
        self.start(32);wait_for(lambda:self.router.calls>=16)
        time.sleep(.15)
        expected=int((512*.85-32)//24)
        self.assertEqual(self.router.calls,expected)
        self.assertEqual(self.worker.snapshot()['effective_workers'],expected)
    def test_worker_limit_validation_is_atomic(self):
        for value in [0,33,-1,True,1.5,'16',None]:
            with self.assertRaises(ValueError):self.store.update_settings({'daily_limit':12,'worker_limit':value})
            self.assertEqual(self.store.capacity_settings()['daily_limit'],0)
        self.store.update_settings({'worker_limit':16})
        self.assertEqual(JobStore(self.store.path).settings()['worker_limit'],16)
    def test_clean_disk_cache_does_not_freeze_queue(self):
        self.resources.update(memory_current=480*MIB,memory_guard_bytes=32*MIB,reclaimable_file_cache=448*MIB)
        self.start(16);wait_for(lambda:self.router.calls==16)
        self.assertIsNone(self.worker.snapshot()['pause_reason'])
    def test_lease_exhaustion_is_counted_once(self):
        self.store.create('old',request())
        with self.store.connect() as db:db.execute("UPDATE jobs SET status='running',rounds=3,updated=? WHERE id='old'",(time.time()-200,))
        self.store.claim();self.store.claim()
        self.assertEqual(self.store.live_stats()['today_failed'],1)
    def test_weekly_expiry_is_counted_on_failure_day(self):
        with self.store.connect() as db:db.execute('INSERT INTO jobs(id,fingerprint,kind,payload,status,created,updated,next_run) VALUES(?,?,?,?,?,?,?,?)',('old','x','weekly_review','{}','queued',time.time()-90000,time.time()-90000,0))
        self.store.claim()
        stats=self.store.live_stats();self.assertEqual(stats['today_failed'],1);self.assertEqual(stats['today_processed'],1)
    def test_alerts_use_queue_and_actual_supplier_attempts(self):
        self.store.create('old',request())
        with self.store.connect() as db:db.execute("UPDATE jobs SET created=? WHERE id='old'",(time.time()-130,))
        for i in range(5):self.store.attempt('old',{'provider':'fixture','model':'fixture','outcome':'upstream_429' if i==0 else 'success','duration_ms':1,'usage':{}})
        stats=self.store.live_stats();self.assertEqual(stats['recent_failed_attempts'],1);self.assertEqual(len(stats['alerts']),2)

if __name__=='__main__':unittest.main(verbosity=2)
