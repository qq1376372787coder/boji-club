"""Synthetic regression cases for the fourth repair; no paid model calls."""
import copy,datetime as dt,importlib.util,json,os,sys,tempfile,unittest,uuid
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'backend'))
import ai_core
from server import JobStore,make_server
from test_backend_offline import weekly_request,weekly_result

class RepairV4(unittest.TestCase):
 def test_zero_repetitions_do_not_count_as_activity(self):
  req={'kind':'report','date':'2026-10-02','payload':{'exercises':[{'name':'x','sets':[{'weight':40,'reps':0,'completed':True}]}],'meals':[]}}
  with self.assertRaises(ai_core.AIError): ai_core.validate_request(req)
  totals=ai_core.validate_request(req,allow_empty_report=True)['payload']['totals'];self.assertEqual(totals['completed_sets'],0);self.assertEqual(totals['volume_kg'],0)
 def test_timed_sets_count_seconds_without_weight_volume(self):
  req={'kind':'report','date':'2026-10-02','payload':{'exercises':[{'name':'平板支撑','sets':[{'weight':40,'reps':10,'durationSeconds':45,'completed':True},{'weight':0,'reps':0,'durationSeconds':0,'completed':True}]}],'meals':[]}}
  totals=ai_core.validate_request(req)['payload']['totals'];self.assertEqual(totals['completed_sets'],1);self.assertEqual(totals['duration_seconds'],45);self.assertEqual(totals['volume_kg'],0)
 def test_proposed_volume_uses_completed_work(self):
  req=weekly_request()
  for day in req['payload']['days']:
   for s in day['payload']['exercises'][0]['sets']:s['completed']=False
  req['payload']['days'][0]['payload']['exercises'][0]['sets'][0]['completed']=True
  result=ai_core.validate_result(ai_core.validate_request(req),weekly_result())
  self.assertEqual(result['decision'],'insufficient');self.assertEqual(result['sessions'],[])
 def test_weekly_cannot_move_to_unselected_weekday(self):
  req=weekly_request();req['payload']['survey']['trainingDays']=[1,3]
  result=weekly_result();result['sessions'][0]['date']='2026-09-29'
  with self.assertRaises(ai_core.AIError):ai_core.validate_result(ai_core.validate_request(req),result)
 def test_completed_days_exclude_empty_sets(self):
  req=weekly_request()
  for day in req['payload']['days']:
   for s in day['payload']['exercises'][0]['sets']:s['reps']=0
  result=ai_core.validate_result(ai_core.validate_request(req),weekly_result());self.assertEqual(result['decision'],'insufficient')
 def test_timed_plan_preserves_unit_and_verified_reference(self):
  req=ai_core.validate_request({'kind':'parse_plan','date':'2026-10-02','payload':{'profile':{'age':28,'height':175,'weight':68,'daysPerWeek':3,'goal':'增肌','experience':'新手','venue':'在家','focus':'全身'},'text':'周五平板支撑45秒'}})
  result={'kind':'plan','title':'x','notes':[],'sessions':[{'date':'2026-10-02','label':'x','exercises':[{'name':'平板支撑','muscle':'核心','library_query':'plank','sets':[{'reps':0,'durationSeconds':45}]}]}]}
  value=ai_core.validate_result(req,result)['sessions'][0]['exercises'][0];self.assertEqual(value['sets'][0]['durationSeconds'],45);self.assertEqual(value['sets'][0]['reps'],0);self.assertEqual(value['library_id'],'boji-basic-plank')
 def test_metadata_restores_date_after_private_input_is_cleared(self):
  with tempfile.TemporaryDirectory() as temp:
   store=JobStore(Path(temp)/'jobs.sqlite3');job=str(uuid.uuid4())
   req=ai_core.validate_request({'kind':'report','date':'2026-10-02','payload':{'exercises':[],'meals':[],'body_weight_kg':70}})
   store.create(job,req);store.complete(job,{'kind':'report'},'synthetic','synthetic')
   rows=store.metadata([job]);self.assertEqual(rows[0]['date'],'2026-10-02');self.assertNotIn('payload',rows[0]);self.assertNotIn('result',rows[0])
   store.delete_private(job);self.assertEqual(store.metadata([job]),[])
 def test_queue_indexes_exist_and_quota_resets_at_beijing_midnight(self):
  with tempfile.TemporaryDirectory() as temp:
   store=JobStore(Path(temp)/'jobs.sqlite3');req=ai_core.validate_request({'kind':'report','date':'2026-10-01','payload':{'exercises':[],'meals':[],'body_weight_kg':70}})
   before=dt.datetime(2026,10,1,15,59,tzinfo=dt.timezone.utc).timestamp();after=before+60
   with patch('server.time.time',return_value=before):
    first=str(uuid.uuid4());store.create(first,req,1);store.complete(first,{'kind':'report'},'synthetic','synthetic')
   with patch('server.time.time',return_value=before+10):
    with self.assertRaises(ai_core.AIError):store.create(str(uuid.uuid4()),req,1)
   with patch('server.time.time',return_value=after):self.assertEqual(store.create(str(uuid.uuid4()),req,1)['status'],'queued')
   with store.connect() as db:self.assertIn('jobs_queue_due',[row['name'] for row in db.execute('PRAGMA index_list(jobs)')])
 def test_verified_resolution_never_returns_first_variant(self):
  os.environ.setdefault('EXERCISES_JSON',str(ROOT/'tests/fixtures/exercise-library-original.json'))
  if not Path(os.environ['EXERCISES_JSON']).exists():self.skipTest('Public exercise fixture path required')
  spec=importlib.util.spec_from_file_location('exercise_repair_api',ROOT/'exercise-server/api.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  self.assertEqual(module.resolve_movement('barbell squat')['id'],'0043');self.assertEqual(module.resolve_movement('push up')['id'],'0662')
  self.assertEqual(module.resolve_movement('plank')['id'],'boji-basic-plank');self.assertIsNone(module.resolve_movement('superman'));self.assertIsNone(module.resolve_movement('squat'))
  self.assertEqual(len(module.SEARCH_INDEX),678)
  self.assertEqual(len(module.ORIGINAL_EXERCISES),1324)
  self.assertEqual(len(module.EXERCISES),1337)
  self.assertEqual(len(module.BY_ID),1337)
 def test_usage_retention_preserves_recent_history_and_deletion_barrier(self):
  import time
  with tempfile.TemporaryDirectory() as temp:
   store=JobStore(Path(temp)/'jobs.sqlite3');job=str(uuid.uuid4());req=ai_core.validate_request({'kind':'report','date':'2026-10-02','payload':{'exercises':[],'meals':[],'body_weight_kg':70}})
   store.create(job,req);store.delete_private(job)
   with store.connect() as db:
    for age in [91,89]:db.execute('INSERT INTO attempts(job_id,timestamp,provider,model,outcome,duration_ms,usage) VALUES(?,?,?,?,?,?,?)',(job,time.time()-age*86400,'synthetic','synthetic','success',1,'{}'))
   store.cleanup()
   with store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM attempts').fetchone()[0],1)
   self.assertEqual(store.create(job,req)['status'],'deleted')

if __name__=='__main__':unittest.main(verbosity=2)
