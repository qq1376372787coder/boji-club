"""Successful-task quotas, failure ledgers and private API regression tests."""
import concurrent.futures,json,sys,tempfile,time,threading,unittest,uuid,urllib.request,urllib.error
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from server import JobStore,make_server
from ai_core import AIError
from test_ai_capacity import request
A='a'*64;B='b'*64

class QuotaTests(unittest.TestCase):
 def setUp(self):self.tmp=tempfile.TemporaryDirectory();self.store=JobStore(Path(self.tmp.name)/'db')
 def tearDown(self):self.tmp.cleanup()
 def new(self,owner=A):
  id=str(uuid.uuid4());self.store.create(id,request(),quota_owner=owner);return id
 def success(self,id):self.store.complete(id,{'kind':'meal'},'fixture','fixture')
 def test_default_unlimited_allows_25_successes_not_20(self):
  for _ in range(25):self.success(self.new())
  self.assertEqual(self.store.quota_usage(A)['successful_today'],25)
  self.assertTrue(self.store.quota_usage(A)['unlimited'])
 def test_failed_manual_and_automatic_retries_charge_only_first_success(self):
  id=self.new();self.store.fail(id,AIError('network','fixture',True),1)
  self.assertEqual(self.store.quota_usage(A)['successful_today'],0)
  self.store.fail(id,AIError('network','fixture'),3);self.assertTrue(self.store.retry(id,A)['retry_started'])
  self.store.fail(id,AIError('network','fixture'),3);self.store.retry(id,A);self.success(id)
  self.assertFalse(self.store.retry(id,A)['retry_started']);self.success(id)
  self.assertEqual(self.store.quota_usage(A)['successful_today'],1)
  self.assertEqual(self.store.live_stats()['today_failure_events'],3)
  self.assertEqual(self.store.live_stats()['today_failed'],0)
 def test_duplicate_create_poll_complete_do_not_charge_twice(self):
  id=self.new();self.success(id)
  for _ in range(4):self.store.create(id,request(),quota_owner=A);self.store.get(id);self.success(id)
  self.assertEqual(self.store.quota_usage(A)['successful_today'],1)
 def test_finite_quota_reserves_then_releases_failed_task(self):
  self.store.update_settings({'account_daily_limit':1});id=self.new()
  with self.assertRaises(AIError) as e:self.new()
  self.assertEqual(e.exception.code,'quota_pending')
  self.store.fail(id,AIError('synthetic','fixture'),3);self.assertEqual(self.store.quota_usage(A)['remaining'],1)
  self.success(self.new())
  with self.assertRaises(AIError) as e:self.store.retry(id,A)
  self.assertEqual(e.exception.code,'quota_exceeded');self.success(self.new(B))
 def test_global_failure_free_and_active_reservation(self):
  self.store.update_settings({'daily_limit':1});id=self.new()
  with self.assertRaises(AIError) as e:self.new(B)
  self.assertEqual(e.exception.code,'capacity')
  self.store.fail(id,AIError('synthetic','fixture'),3);self.success(self.new(B))
  with self.assertRaises(AIError) as e:self.new()
  self.assertEqual(e.exception.code,'daily_capacity')
 def test_concurrent_account_admission_cannot_exceed_remaining_successes(self):
  self.store.update_settings({'account_daily_limit':3})
  def submit(_):
   try:self.new();return 1
   except AIError as e:self.assertEqual(e.code,'quota_pending');return 0
  with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:self.assertEqual(sum(pool.map(submit,range(20))),3)
 def test_settings_unlimited_restored_persist_restart(self):
  self.store.update_settings({'account_daily_limit':1});self.success(self.new())
  self.store.update_settings({'account_daily_limit':0});self.success(self.new())
  other=JobStore(self.store.path);self.assertTrue(other.quota_usage(A)['unlimited']);self.assertEqual(other.quota_usage(A)['successful_today'],2)
 def test_midnight_counts_completion_day_and_retains_old_active_reservations(self):
  from datetime import datetime,timezone
  before=datetime(2026,10,11,15,59,59,tzinfo=timezone.utc).timestamp()
  self.store.update_settings({'account_daily_limit':1})
  with patch('server.time.time',return_value=before):id=self.new();self.success(id)
  with patch('server.time.time',return_value=before+1):
   self.assertEqual(self.store.quota_usage(A)['successful_today'],0);id=self.new()
  with patch('server.time.time',return_value=before+86401):
   with self.assertRaises(AIError) as e:self.new()
   self.assertEqual(e.exception.code,'quota_pending');self.success(id)
   self.assertEqual(self.store.quota_usage(A)['successful_today'],1)
 def test_owner_cannot_be_changed_and_never_enters_stored_prompt(self):
  id=self.new()
  with self.assertRaises(AIError):self.store.create(id,request(),quota_owner=B)
  with self.store.connect() as db:self.assertNotIn(A,db.execute('SELECT payload FROM jobs WHERE id=?',(id,)).fetchone()[0])
  self.assertNotIn('quota_owner',self.store.get(id))
 def test_deleted_task_cannot_reset_quota_and_account_erasure_strips_link(self):
  self.store.update_settings({'account_daily_limit':1});id=self.new();self.success(id);self.store.delete_private(id)
  self.assertEqual(self.store.quota_usage(A)['successful_today'],1)
  self.store.erase_owner(A);self.assertEqual(self.store.quota_usage(A)['successful_today'],0)
  self.assertEqual(self.store.live_stats()['today_quota_successes'],1)
  with self.store.connect() as db:self.assertIsNone(db.execute('SELECT owner FROM task_successes').fetchone()[0])
 def test_legacy_binding_backfills_only_successes_not_failed_usage(self):
  id=self.new(None);self.success(id);bad=self.new(None);self.store.fail(bad,AIError('synthetic','fixture'),3)
  self.store.bind_owners([{'id':id,'owner':A},{'id':bad,'owner':A}]);self.assertEqual(self.store.quota_usage(A)['successful_today'],1)
 def test_startup_final_interrupted_is_failed_and_counted(self):
  id=self.new()
  with self.store.connect() as db:db.execute("UPDATE jobs SET status='running',rounds=3 WHERE id=?",(id,))
  other=JobStore(self.store.path);self.assertEqual(other.get(id)['status'],'failed');self.assertEqual(other.live_stats()['today_failed'],1);self.assertEqual(other.live_stats()['today_failure_events'],1)
  third=JobStore(self.store.path);self.assertEqual(third.live_stats()['today_failure_events'],1)
 def test_lease_failure_counted_once_while_old_token_cannot_finish(self):
  id=self.new();claim=self.store.claim()
  with self.store.connect() as db:db.execute('UPDATE jobs SET rounds=3,updated=? WHERE id=?',(time.time()-121,id))
  self.assertIsNone(self.store.claim());self.assertEqual(self.store.live_stats()['today_failed'],1)
  self.assertFalse(self.store.complete(id,{},'fixture','fixture',claim[3]));self.assertEqual(self.store.quota_usage(A)['successful_today'],0)
 def test_cleanup_keeps_anonymous_statistics_for_only_30_days(self):
  id=self.new();self.success(id);self.store.fail(id,AIError('synthetic','fixture'),3)
  with self.store.connect() as db:
   db.execute('UPDATE task_successes SET completed=?',(time.time()-31*86400,));db.execute('UPDATE task_failure_events SET occurred=?',(time.time()-31*86400,))
  self.store.cleanup()
  with self.store.connect() as db:self.assertEqual(db.execute('SELECT count(*) FROM task_successes').fetchone()[0],0);self.assertEqual(db.execute('SELECT count(*) FROM task_failure_events').fetchone()[0],0)
 def test_private_usage_bind_erase_require_internal_auth(self):
  service=make_server(self.store,None,'fixture-token',port=0);thread=threading.Thread(target=service.serve_forever,daemon=True);thread.start()
  try:
   base='http://127.0.0.1:'+str(service.server_port)
   for path,body in [('usage',{'owner':A}),('bind',{'pairs':[]}),('erase',{'owner':A})]:
    req=urllib.request.Request(base+'/v1/account-quota/'+path,data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    with self.assertRaises(urllib.error.HTTPError) as e:urllib.request.urlopen(req)
    self.assertEqual(e.exception.code,404)
    req.add_header('Authorization','Bearer fixture-token')
    with urllib.request.urlopen(req) as r:self.assertEqual(r.status,200)
  finally:service.shutdown();service.server_close();thread.join(2)

if __name__=='__main__':unittest.main(verbosity=2)
