"""Production backend regressions: venues, long actual records and dated weights."""
import copy, datetime as dt, sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core as core
from test_backend_v2 import request, result
from test_training_feedback_v63 import request as report, evaluate

class VenueTests(unittest.TestCase):
 def profile(self):
  p=copy.deepcopy(request()['payload']['profile']);p['venue']='两者都有';return p
 def test_unfixed_weekdays_alternate_starting_at_gym(self):
  p=self.profile()
  self.assertEqual([core.is_home_session(p,dt.date(2026,10,d)) for d in [5,7,9]], [False,True,False])
 def test_fixed_home_days_override_alternation(self):
  p=self.profile();p['homeTrainingDays']=[1,5]
  self.assertEqual([core.is_home_session(p,dt.date(2026,10,d)) for d in [5,7,9]], [True,False,True])
 def test_single_venue_does_not_alternate(self):
  p=self.profile()
  for venue,expected in [('在家',True),('健身房',False)]:
   p['venue']=venue;self.assertEqual(core.is_home_session(p,dt.date(2026,10,5)),expected)
 def test_non_training_day_not_arbitrarily_assigned_home(self):
  self.assertFalse(core.is_home_session(self.profile(),dt.date(2026,10,6)))
 def test_selected_schedule_uses_same_venue_across_future_weeks(self):
  raw=request();raw['payload']['profile']=self.profile()
  clean=core.validate_request(raw)
  schedule=core.plan_schedule(clean)
  self.assertEqual([s['venue'] for s in schedule],['在家','健身房','健身房'])
  for s in schedule:
   date=dt.date.fromisoformat(s['date'])
   self.assertEqual(core.is_home_session(clean['payload']['profile'],date),core.is_home_session(clean['payload']['profile'],date+dt.timedelta(days=7)))
 def test_mixed_gym_session_accepts_gym_equipment(self):
  raw=request();raw['payload']['profile']=self.profile();out=result()
  out['sessions'][1]['exercises'][0]['library_query']='barbell squat'
  cleaned=core.validate_result(core.validate_request(raw),out)
  self.assertIn('健身房',cleaned['sessions'][1]['label']);self.assertIn('居家',cleaned['sessions'][0]['label'])
 def test_mixed_home_session_rejects_unavailable_equipment(self):
  raw=request();raw['payload']['profile']=self.profile();out=result()
  out['sessions'][0]['exercises'][0]['library_query']='barbell squat'
  with self.assertRaises(core.AIError):core.validate_result(core.validate_request(raw),out)

class LongActualTests(unittest.TestCase):
 def test_two_hour_record_and_original_target_survive(self):
  raw=report(total=1,done=1,timed=7200)
  cleaned=core.validate_request(raw)['payload']
  self.assertEqual(cleaned['exercises'][0]['sets'][0]['durationSeconds'],7200)
  self.assertEqual(cleaned['workout_sessions'][0]['executionBaseline']['sets'][0]['targetSeconds'],7200)
  self.assertEqual(evaluate(raw)['status'],'green')
 def test_six_hour_boundary_preserved(self):
  self.assertEqual(core.validate_request(report(total=1,done=1,timed=21600))['payload']['exercises'][0]['sets'][0]['durationSeconds'],21600)
 def test_over_limit_rejected_instead_of_truncated(self):
  with self.assertRaises(core.AIError):core.validate_request(report(total=1,done=1,timed=21601))
 def test_300_reps_record_remains_valid(self):
  raw=report(total=1);raw['payload']['exercises'][0]['sets'][0]['reps']=300
  self.assertEqual(core.validate_request(raw)['payload']['exercises'][0]['sets'][0]['reps'],300)
 def test_ai_generation_does_not_prescribe_six_hour_sets(self):
  out=result();out['sessions'][0]['exercises'][2]['sets'][0]['durationSeconds']=7200
  with self.assertRaises(core.AIError):core.validate_result(request(),out)

class WeightReferenceTests(unittest.TestCase):
 def raw(self,days_ago=0):
  raw=request();today=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date()
  raw['date']=(today+dt.timedelta(days=1)).isoformat();raw['payload']['timeZone']='Asia/Shanghai'
  raw['payload']['weight_reference']={'date':(today-dt.timedelta(days=days_ago)).isoformat(),'kilograms':68}
  return raw
 def test_explicit_recent_measurement_sent_to_provider(self):
  clean=core.validate_request(self.raw(3));messages=core.messages_for(clean)
  self.assertIn('weight_reference',messages[1]['content']);self.assertIn('实测体重',messages[0]['content'])
 def test_boundary_thirty_days_accepted(self):core.validate_request(self.raw(30))
 def test_older_measurement_not_silently_used(self):
  with self.assertRaises(core.AIError):core.validate_request(self.raw(31))
 def test_future_measurement_rejected_even_for_future_plan(self):
  with self.assertRaises(core.AIError):core.validate_request(self.raw(-1))
 def test_contradictory_weight_rejected(self):
  raw=self.raw();raw['payload']['weight_reference']['kilograms']=69
  with self.assertRaises(core.AIError):core.validate_request(raw)
 def test_old_request_without_reference_stays_compatible(self):
  self.assertNotIn('weight_reference',core.validate_request(request())['payload'])

if __name__=='__main__':unittest.main()
