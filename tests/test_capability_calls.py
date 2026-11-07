"""Phase 2: model capability-call requests are bounded by the server whitelist."""
import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from ai_core import validate_request,validate_result,AIError,messages_for

def request():
    return {'kind':'coach','date':'2020-01-15','payload':{'version':1,'conversation_id':'00000000-0000-4000-8000-000000000001','question':'今天练什么？我有点累','history':[],
        'days':[{'date':'2020-01-15','payload':{'exercises':[{'name':'卧推','sets':[{'weight':20,'reps':10,'completed':True}]}],'meals':[],'training_confirmed':True,'meals_complete':False}}], '_routing_version':2,
        'capabilities':[
            {'capability':'training.get_today','description':'今天的安排','input':{'type':'object','properties':{'date':{'type':'string'}},'required':[]}},
            {'capability':'coach.assess_readiness','description':'疲劳评估','input':{'type':'object','properties':{'question':{'type':'string'}},'required':[]}},
            {'capability':'body.record_weight','description':'记录体重','input':{'type':'object','properties':{'date':{'type':'string'},'kilograms':{'type':'number'}},'required':['date','kilograms']}},
            {'capability':'schedule.preview_change','description':'预览改期','input':{'type':'object','properties':{'moves':{'type':'array'}},'required':['moves']}},
        ]}}

def answer():
    return {'kind':'coach','notes':[],'coach':{'answer':'根据 1 月 15 日已登记的这一组卧推，先核对每组实际重量与次数。这里只能看到完成登记，不能从这一组推断动作标准或力量增长。下一次继续记录相同动作的实际表现，再比较。','source_ids':['day/2020-01-15'],'actions':[{'type':'training','date':'2020-01-15'}]}}

class CapabilityCallTests(unittest.TestCase):
    def clean(self,raw=None):return validate_request(raw or request())
    def result(self,raw,calls):value=copy.deepcopy(raw);value['coach']['capability_calls']=calls;return validate_result(self.clean(),value)

    def test_whitelisted_calls_pass_with_clean_input(self):
        value=self.result(answer(),[{'capability':'training.get_today','input':{}},{'capability':'body.record_weight','input':{'date':'2020-01-15','kilograms':70.5}}])
        calls=value['coach']['capability_calls']
        self.assertEqual([c['capability'] for c in calls],['training.get_today','body.record_weight'])
        self.assertEqual(calls[1]['input']['kilograms'],70.5)

    def test_unknown_capability_rejected(self):
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'training.delete_everything','input':{}}])

    def test_unknown_input_field_rejected(self):
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'body.record_weight','input':{'date':'2020-01-15','kilograms':70.5,'sql':'drop table'}}])

    def test_missing_required_field_rejected(self):
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'body.record_weight','input':{'date':'2020-01-15'}}])

    def test_wrong_value_type_rejected(self):
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'body.record_weight','input':{'date':'2020-01-15','kilograms':'70.5'}}])
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'schedule.preview_change','input':{'moves':'today'}}])

    def test_duplicate_capability_rejected(self):
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'training.get_today','input':{}},{'capability':'training.get_today','input':{}}])

    def test_more_than_three_calls_rejected(self):
        with self.assertRaises(AIError):self.result(answer(),[{'capability':'training.get_today','input':{}}]*4)

    def test_absent_calls_field_stays_compatible(self):
        value=validate_result(self.clean(),answer())
        self.assertNotIn('capability_calls',value['coach'])

    def test_no_whitelist_means_no_calls(self):
        raw=request();del raw['payload']['capabilities']
        clean=validate_request(raw)
        self.assertEqual(clean['payload']['capabilities'],[])
        with self.assertRaises(AIError):validate_result(clean,{**answer(),'coach':{**answer()['coach'],'capability_calls':[{'capability':'training.get_today','input':{}}]}})

    def test_prompt_lists_whitelist_and_forbids_claiming_writes(self):
        raw=request();raw['payload']['question']='帮我把周四改到周六，再记下体重 70.5'
        content=messages_for(self.clean(raw))[0]['content']
        self.assertIn('training.get_today',content)
        self.assertIn('capability_calls',content)
        self.assertIn('绝不能宣称任何写入已执行',content)

if __name__=='__main__':unittest.main()
