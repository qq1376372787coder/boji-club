"""Historical goal input survives validation and reaches actual provider prompts."""
import copy, sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from ai_core import validate_request, messages_for, AIError
from test_backend_offline import weekly_request
from test_backend_v2 import request as plan_request

DAY='2026-10-14'
PROFILE={'age':28,'height':175,'weight':68,'daysPerWeek':3,'goal':'增肌','experience':'新手','venue':'健身房','focus':'全身','nutritionContext':'普通成人','dailyActivity':'主要久坐'}

def context(date=DAY):
    return {'version':1,'start':date,'end':date,'days':[{'date':date,'goalVersionID':'550e8400-e29b-41d4-a716-446655440000','profile':copy.deepcopy(PROFILE),'goalChangedDuringDay':False,'planVersionID':'manual/example','planSource':'manual'}]}

def report():
    return {'kind':'report','date':DAY,'payload':{'exercises':[],'meals':[{'name':'鸡蛋','nutrition_known':True,'calories':150,'protein':13,'carbs':1,'fat':10}],'goal_context':context()}}

class GoalContextTests(unittest.TestCase):
    def invalid(self,value):
        with self.assertRaises(AIError): validate_request(value)
    def test_report_preserves_dated_profile_and_evidence(self):
        value=validate_request(report());self.assertEqual(value['payload']['goal_context'],context())
        prompts=messages_for(value)
        self.assertIn('goal_context',prompts[1]['content']);self.assertIn('不能用顶层当前profile',prompts[0]['content'])
    def test_unknown_history_stays_unknown(self):
        raw=report();row=raw['payload']['goal_context']['days'][0];row.update(profile=None,goalVersionID=None)
        self.assertIsNone(validate_request(raw)['payload']['goal_context']['days'][0]['profile'])
    def test_identity_and_private_avatar_never_forwarded(self):
        raw=report();p=raw['payload']['goal_context']['days'][0]['profile'];p.update(nickname='private',avatarImage='private',phone='private',unknown='private')
        clean=validate_request(raw)['payload']['goal_context']['days'][0]['profile']
        self.assertTrue(all(k not in clean for k in ('nickname','avatarImage','phone','unknown')))
    def test_safety_context_is_preserved(self):
        raw=report();raw['payload']['goal_context']['days'][0]['profile']['nutritionContext']='孕期或哺乳期'
        clean=validate_request(raw)['payload']
        self.assertEqual(clean['goal_context']['days'][0]['profile']['nutritionContext'],'孕期或哺乳期')
        self.assertEqual(clean['nutritionTarget'],{'generalGuidanceOnly':True})
    def test_version_and_boolean_types(self):
        for bad in (True,0,2,'1',1.0):
            raw=report();raw['payload']['goal_context']['version']=bad;self.invalid(raw)
        raw=report();raw['payload']['goal_context']['days'][0]['goalChangedDuringDay']=1;self.invalid(raw)
    def test_report_context_cannot_belong_to_another_day(self):
        raw=report();raw['payload']['goal_context']=context('2026-10-13');self.invalid(raw)
    def test_snapshot_requires_profile_and_valid_id(self):
        for field,value in [('goalVersionID',None),('profile',None),('goalVersionID','not-a-uuid')]:
            raw=report();raw['payload']['goal_context']['days'][0][field]=value;self.invalid(raw)
    def test_unknown_goal_cannot_claim_change(self):
        raw=report();raw['payload']['goal_context']['days'][0].update(profile=None,goalVersionID=None,goalChangedDuringDay=True);self.invalid(raw)
    def test_plan_source_pair(self):
        raw=report();raw['payload']['goal_context']['days'][0]['planVersionID']=None;self.invalid(raw)
    def test_duplicate_or_missing_dates(self):
        raw=report();raw['payload']['goal_context']['days']*=2;self.invalid(raw)
        raw=report();raw['payload']['goal_context']['days']=[];self.invalid(raw)
    def test_same_day_goal_change_explicit(self):
        raw=report();raw['payload']['goal_context']['days'][0]['goalChangedDuringDay']=True
        self.assertTrue(validate_request(raw)['payload']['goal_context']['days'][0]['goalChangedDuringDay'])
    def test_weekly_top_level_and_nested_day_survive(self):
        raw=weekly_request();raw['payload']['goal_context']=context(raw['date'])
        for day in raw['payload']['days']: day['payload']['goal_context']=context(day['date'])
        value=validate_request(raw);self.assertIn('goal_context',value['payload']['days'][0])
        self.assertIn('goal_context',str(messages_for(value)[1]['content']))
        self.assertIn('一天内目标发生过变化',messages_for(value)[0]['content'])
    def test_plan_current_profile_remains_authoritative(self):
        raw=plan_request();raw['payload']['goal_context']=context('2026-09-01')
        value=validate_request(raw);self.assertEqual(value['payload']['profile']['goal'],raw['payload']['profile']['goal'])
        self.assertIn('制定新计划仍以顶层当前profile',messages_for(value)[0]['content'])
    def test_legacy_input_does_not_gain_invented_history(self):
        raw=report();del raw['payload']['goal_context'];self.assertNotIn('goal_context',validate_request(raw)['payload'])
    def test_empty_null_context_rejected(self):
        for value in (None,{},[],True):
            raw=report();raw['payload']['goal_context']=value;self.invalid(raw)

if __name__=='__main__':unittest.main()
