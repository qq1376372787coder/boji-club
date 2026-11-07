import sys,unittest,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from ai_core import validate_request,AIError
from test_adaptive_automation import body,KEY
import automation_core as auto
class Build123Tests(unittest.TestCase):
 def coach(self,kind='rolling7',start='2020-01-09',end='2020-01-15'):
  return {'kind':'coach','date':end,'payload':{'version':1,'conversation_id':str(uuid.uuid4()),'question':'请核对这些记录','timeZone':'Asia/Shanghai','purpose':'weekly','days':[],'review_scope':{'kind':kind,'from':start,'to':end,'timeZone':'Asia/Shanghai'}}}
 def test_scope_survives_normalization(self):
  self.assertEqual(validate_request(self.coach())['payload']['review_scope']['from'],'2020-01-09')
 def test_calendar_scope_requires_sunday(self):
  with self.assertRaises(AIError):validate_request(self.coach('completedCalendarWeek'))
 def test_scope_cannot_claim_different_days(self):
  with self.assertRaises(AIError):validate_request(self.coach(start='2020-01-01'))
 def test_valid_complete_week(self):
  self.assertEqual(validate_request(self.coach('completedCalendarWeek','2020-01-06','2020-01-12'))['payload']['review_scope']['to'],'2020-01-12')
 def source(self,overlap=False):
  b=body();session=b['state']['days'][KEY]['workoutSessions'][0];start=session['startedAt']
  session['pauseIntervals']=[{'start':start+10,'end':start+30}]
  if overlap:session['pauseIntervals'].append({'start':start+20,'end':start+40})
  return {'kind':'report','date':KEY,'payload':auto.report_day(b['state'],KEY,{},'Asia/Shanghai')}
 def test_pause_survives_automation_source(self):
  self.assertEqual(validate_request(self.source(),allow_empty_report=True)['payload']['workout_sessions'][0]['active_duration_seconds'],40)
 def test_overlapping_pauses_rejected(self):
  with self.assertRaises(AIError):validate_request(self.source(True),allow_empty_report=True)
if __name__=='__main__':unittest.main()
