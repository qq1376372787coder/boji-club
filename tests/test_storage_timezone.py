import base64,copy,datetime as dt,sys,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core as core
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_backend_offline import weekly_request

class FixedDateTime(dt.datetime):
 instant=dt.datetime(2026,10,12,15,30,tzinfo=dt.timezone.utc)
 @classmethod
 def now(cls,tz=None):return cls.instant.astimezone(tz) if tz else cls.instant.replace(tzinfo=None)
def food(zone='Asia/Tokyo',date='2026-10-13'):
 payload={'source':'text','description':'今天早餐吃了两个鸡蛋','meal_category':'早餐','mode':'multiple','reference_date':date}
 if zone:payload['timeZone']=zone
 return {'kind':'food','date':date,'payload':payload}
def batch(date):
 return {'kind':'meal_batch','notes':[],'meals':[{'date':date,'category':'早餐','name':'鸡蛋','notes':[],'components':[{'name':'鸡蛋','amount':2,'unit':'个','basis':'described','details':[],'calories':140,'protein':12,'carbs':1,'fat':10}]}]}

class TimezoneTests(unittest.TestCase):
 def test_tokyo_today_is_valid_when_beijing_is_yesterday(self):
  with patch('ai_core.dt.datetime',FixedDateTime):
   request=core.validate_request(food());self.assertEqual(core.validate_result(request,batch('2026-10-13'))['meals'][0]['date'],'2026-10-13')
 def test_shanghai_same_date_is_still_future(self):
  with patch('ai_core.dt.datetime',FixedDateTime),self.assertRaises(core.AIError):core.validate_request(food('Asia/Shanghai'))
 def test_western_timezone_uses_its_own_today(self):
  with patch('ai_core.dt.datetime',FixedDateTime):
   request=core.validate_request(food('America/Los_Angeles','2026-10-12'))
   with self.assertRaises(core.AIError):core.validate_result(request,batch('2026-10-13'))
 def test_legacy_phone_today_gets_bounded_world_date_compatibility(self):
  with patch('ai_core.dt.datetime',FixedDateTime):
   request=core.validate_request(food(None));self.assertEqual(core.validate_result(request,batch('2026-10-13'))['kind'],'meal_batch')
   with self.assertRaises(core.AIError):core.validate_request(food(None,'2026-10-15'))
 def test_reference_date_cannot_claim_arbitrary_future(self):
  raw=food();raw['payload']['reference_date']='2030-01-01'
  with patch('ai_core.dt.datetime',FixedDateTime),self.assertRaises(core.AIError):core.validate_request(raw)
 def test_bad_zone_rejected_before_provider_call(self):
  with self.assertRaises(core.AIError):core.validate_request(food('Not/A_Zone'))
 def test_batch_future_relative_to_reference_still_rejected(self):
  with patch('ai_core.dt.datetime',FixedDateTime):
   request=core.validate_request(food());
   with self.assertRaises(core.AIError):core.validate_result(request,batch('2026-10-14'))
 def test_queued_request_keeps_reference_date_across_midnight(self):
  with patch('ai_core.dt.datetime',FixedDateTime):request=core.validate_request(food())
  class NextDay(FixedDateTime):instant=FixedDateTime.instant+dt.timedelta(days=1)
  with patch('ai_core.dt.datetime',NextDay):
   self.assertEqual(core.validate_result(request,batch('2026-10-13'))['kind'],'meal_batch')
   with self.assertRaises(core.AIError):core.validate_result(request,batch('2026-10-14'))
 def test_weekly_general_guidance_without_calorie_fields_is_accepted(self):
  raw=weekly_request();raw['payload']['nutritionTarget']={'generalGuidanceOnly':True,'strategy':'仅提供通用建议'}
  self.assertTrue(core.validate_request(raw)['payload']['nutritionTarget']['generalGuidanceOnly'])
 def test_minor_weekly_target_never_requires_calories(self):
  raw=weekly_request();raw['payload']['profile']['age']=16;raw['payload']['nutritionTarget']={'generalGuidanceOnly':True}
  self.assertEqual(core.validate_request(raw)['payload']['nutritionTarget'],{'generalGuidanceOnly':True})
 def test_daylight_saving_fallback_keeps_local_day(self):
  for hour in (8,9):
   class DSTClock(FixedDateTime):instant=dt.datetime(2026,11,1,hour,30,tzinfo=dt.timezone.utc)
   with patch('ai_core.dt.datetime',DSTClock):
    request=core.validate_request(food('America/Los_Angeles','2026-11-01'))
    self.assertEqual(core.validate_result(request,batch('2026-10-31'))['meals'][0]['date'],'2026-10-31')
 def test_legacy_single_and_photo_use_bounded_world_today(self):
  jpeg=(Path(__file__).resolve().parent/'food-illustration-fixture.jpg').read_bytes()
  payloads=[{'source':'text','description':'两个鸡蛋'}, {'image_base64':base64.b64encode(jpeg).decode()}]
  with patch('ai_core.dt.datetime',FixedDateTime):
   for payload in payloads:
    self.assertEqual(core.validate_request({'kind':'food','date':'2026-10-13','payload':payload})['date'],'2026-10-13')
    with self.assertRaises(core.AIError):core.validate_request({'kind':'food','date':'2026-10-15','payload':payload})

if __name__=='__main__':unittest.main(verbosity=2)
