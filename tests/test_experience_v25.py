import copy,sys,unittest,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core
S1='00000000-0000-4000-8000-000000000001';S2='00000000-0000-4000-8000-000000000002'
def request():
 return {'kind':'report','date':'2026-10-04','payload':{'exercises':[{'name':'卧推','session_id':S1,'sets':[{'weight':20,'reps':10,'completed':True}]},{'name':'平板支撑','session_id':S2,'sets':[{'weight':0,'reps':0,'durationSeconds':40,'completed':True}]}],'meals':[],'workout_sessions':[{'id':S1,'startedAt':800000000,'endedAt':800003600,'savedAt':800003601},{'id':S2,'startedAt':800010000,'endedAt':800013600,'savedAt':800013601}]}}
class UserJourneyRepair(unittest.TestCase):
 def test_aggregate_no_double_count(self):
  data=ai_core.validate_request(request())['payload'];self.assertEqual(data['totals']['completed_sets'],2);self.assertEqual(data['totals']['volume_kg'],200);self.assertEqual(data['totals']['duration_seconds'],40)
 def test_separate_intervals(self):
  data=ai_core.validate_request(request())['payload']['workout_sessions'];self.assertNotEqual(data[0]['startedAt'],data[1]['startedAt']);self.assertTrue(all(x['confirmed'] for x in data))
 def test_duplicate_session_rejected(self):
  r=request();r['payload']['workout_sessions'][1]['id']=S1
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(r)
 def test_missing_session_rejected(self):
  r=request();r['payload']['exercises'][0].pop('session_id')
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(r)
 def test_reverse_interval_rejected(self):
  r=request();r['payload']['workout_sessions'][0]['endedAt']=1
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(r)
 def test_saved_empty_session_rejected(self):
  r=request();r['payload']['exercises'][0]['sets'][0]['completed']=False
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(r)
 def test_unconfirmed_session_supported(self):
  r=request();r['payload']['workout_sessions'][0].pop('savedAt');self.assertFalse(ai_core.validate_request(r)['payload']['workout_sessions'][0]['confirmed'])
 def test_empty_report_rejected(self):
  with self.assertRaises(ai_core.AIError):ai_core.validate_request({'kind':'report','date':'2026-10-04','payload':{'exercises':[],'meals':[]}})
 def test_empty_weekly_context_allowed(self):
  self.assertEqual(ai_core.validate_request({'kind':'report','date':'2026-10-04','payload':{'exercises':[],'meals':[]}},allow_empty_report=True)['payload']['totals']['completed_sets'],0)
 def test_empty_health_does_not_qualify(self):
  r={'kind':'report','date':'2026-10-04','payload':{'health':{'date':'2026-10-04','timeZone':'Asia/Shanghai','updatedAt':800000000,'workouts':[]}}}
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(r)
 def test_weight_alone_qualifies(self):
  self.assertEqual(ai_core.validate_request({'kind':'report','date':'2026-10-04','payload':{'body_weight_kg':70}})['payload']['body_weight_kg'],70)
 def test_link_requires_own_completed_groups(self):
  r=request();r['payload']['workout_sessions'][0]['linkedDeviceWorkoutID']='missing'
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(r)
if __name__=='__main__':unittest.main()
