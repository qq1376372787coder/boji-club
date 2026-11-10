import copy,datetime,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core as core
from test_backend_v2 import request,result

class MultiweekTests(unittest.TestCase):
    def fixture(self,days=14,start='2026-10-05'):
        value=request();value['date']=start;value['payload']['plan_days']=days
        clean=core.validate_request(value);raw=result()
        for item,day in zip(raw['sessions'],core.plan_schedule(clean)): item['date']=day['date']
        return clean,raw
    def test_all_lengths_have_exact_counts_and_unique_dates(self):
        for days in [7,14,28]:
            value,raw=self.fixture(days);base=core.validate_result(value,raw)
            output=core.expand_generated_plan(value,base)
            self.assertEqual(len(output['sessions']),3*days//7)
            dates=[item['date'] for item in output['sessions']]
            self.assertEqual(len(dates),len(set(dates)))
            self.assertTrue(all(datetime.date.fromisoformat(key).isoweekday() in [1,3,5] for key in dates))
            self.assertTrue(all(0<=(datetime.date.fromisoformat(key)-datetime.date(2026,10,5)).days<days for key in dates))
    def test_cross_month_and_leap_year(self):
        for start in ['2026-12-20','2028-02-27']:
            value,raw=self.fixture(28,start);output=core.expand_generated_plan(value,core.validate_result(value,raw))
            self.assertEqual(len(output['sessions']),12)
            self.assertLess(datetime.date.fromisoformat(output['sessions'][-1]['date']),datetime.date.fromisoformat(start)+datetime.timedelta(days=28))
    def test_repeats_are_independent_and_no_fake_progression(self):
        value,raw=self.fixture();base=core.validate_result(value,raw);before=copy.deepcopy(base)
        output=core.expand_generated_plan(value,base)
        self.assertEqual(output['sessions'][0]['exercises'],output['sessions'][3]['exercises'])
        self.assertIn('沿用',output['sessions'][3]['label']);self.assertIn('不自动加重',output['notes'][0])
        output['sessions'][3]['exercises'][0]['sets'][0]['reps']=99
        self.assertNotEqual(output['sessions'][0]['exercises'][0]['sets'][0]['reps'],99)
        self.assertEqual(base,before)
    def test_legacy_request_stays_one_week(self):
        value=request();base=core.validate_result(value,result())
        self.assertIs(core.expand_generated_plan(value,base),base)
        self.assertNotIn('plan_days',base)
    def test_safety_notes_are_not_discarded_at_limit(self):
        value,raw=self.fixture();base=core.validate_result(value,raw)
        base['notes']=['保留安全说明'+str(index) for index in range(20)]
        output=core.expand_generated_plan(value,base)
        self.assertEqual(output['notes'],base['notes'])
    def test_invalid_length_rejected(self):
        for bad in [0,8,21,29,100000,True,'14',14.5]:
            value=request();value['payload']['plan_days']=bad
            with self.assertRaises(core.AIError):core.validate_request(value)
    def test_import_is_not_duplicated(self):
        value={'kind':'parse_plan','payload':{'plan_days':28}}
        plan={'kind':'plan','sessions':[]}
        self.assertIs(core.expand_generated_plan(value,plan),plan)
    def test_purposes_follow_shifted_dates(self):
        value,raw=self.fixture(28);value['payload']['plan_explanation_version']=1
        output=core.expand_generated_plan(value,core.validate_result(value,raw))
        self.assertEqual([s['date'] for s in output['sessions']],[p['date'] for p in output['explanation']['sessions']])
        self.assertTrue(all('沿用基础周' in p['purpose'] for p in output['explanation']['sessions'][3:]))
    def test_explanation_uses_full_cycle_counts(self):
        # AUD-018/FIX-018：14/28 天说明必须按完整周期重算，不能保留基础周数量。
        value,raw=self.fixture(28);value['payload']['plan_explanation_version']=1
        output=core.expand_generated_plan(value,core.validate_result(value,raw))
        summary=' '.join(output['explanation']['summary'])
        self.assertIn('12 课',summary)
        self.assertIn('基础周 3 课',summary)
        self.assertIn('不自动加量',summary)
        self.assertNotIn('本轮 3',summary)
        volume=next(s for s in output['explanation']['sections'] if s['id']=='volume')
        self.assertIn('本周期共 36 项动作、36 组',volume['basis'])
        self.assertIn('基础周 9 项动作、9 组',volume['basis'])
    def test_router_uses_one_provider_call_for_four_weeks(self):
        value,raw=self.fixture(28);calls=[]
        def transport(provider,*args):calls.append(provider.name);return raw,{}
        output,provider,_=core.Router([core.Provider('longcat','https://example.invalid','test','test')],transport).run(value)
        self.assertEqual(calls,['longcat']);self.assertEqual(len(output['sessions']),12)
    def test_model_receives_only_base_week_scope(self):
        import json
        value,_=self.fixture(28)
        content=json.loads(core.messages_for(value)[1]['content'])
        self.assertNotIn('plan_days',content)
        self.assertEqual(len(content['allowed_training_sessions']),3)
        self.assertEqual(value['payload']['plan_days'],28)

if __name__=='__main__':unittest.main()
