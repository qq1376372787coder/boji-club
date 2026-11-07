import copy,unittest
from ai_core import validate_request,validate_result,messages_for,AIError
from test_coach import request,answer

class ChatStability127Tests(unittest.TestCase):
    def general(self,q='卧推主要练什么部位？'):
        raw=request();raw['payload']['question']=q;return validate_request(raw)
    def output(self,text='卧推主要训练胸大肌，肱三头肌和三角肌前束也参与。'):
        return {'kind':'coach','notes':[],'coach':{'answer':text,'source_ids':[],'actions':[]}}
    def test_general_knowledge_needs_no_irrelevant_personal_citation(self):
        result=validate_result(self.general(),self.output())
        self.assertEqual(result['coach']['sources'],[])
    def test_greeting_does_not_need_thirty_characters_of_filler(self):
        value=validate_result(self.general('你好'),self.output('你好，有什么想聊的？'))
        self.assertEqual(value['coach']['sources'],[])
    def test_personal_review_still_requires_real_evidence(self):
        raw=answer();raw['coach']['source_ids']=[]
        with self.assertRaises(AIError):validate_result(validate_request(request()),raw)
    def test_individual_claim_cannot_hide_inside_general_answer(self):
        with self.assertRaises(AIError):validate_result(self.general(),self.output('你今天完成了三组卧推，下一次继续登记并比较。'))
    def test_general_answer_still_rejects_invented_sources(self):
        value=self.output();value['coach']['source_ids']=['day/1900-01-01']
        with self.assertRaises(AIError):validate_result(self.general(),value)
    def test_prompt_stops_forcing_record_broadcast_on_every_turn(self):
        system=messages_for(self.general())[0]['content']
        self.assertNotIn('先陈述有记录支持的事实，再给一至两条具体建议',system)
        self.assertIn('不机械播报完成组数或饮食条数',system)
        self.assertIn('普通问答直接回答',system)
    def test_daily_scope_accepts_one_authorized_day(self):
        raw=request();raw['payload']['review_scope']={'kind':'daily','from':raw['date'],'to':raw['date'],'timeZone':'Asia/Shanghai'}
        raw['payload']['timeZone']='Asia/Shanghai';raw['payload']['context_days']=1
        clean=validate_request(raw)
        self.assertEqual(clean['payload']['review_scope']['kind'],'daily')
        self.assertEqual(len(clean['payload']['days']),1)
    def test_health_claim_safety_is_not_relaxed_for_general_questions(self):
        with self.assertRaises(AIError):validate_result(self.general(),self.output('你的动作完全标准，继续训练即可，不需要核对任何其他情况。'))

if __name__=='__main__':unittest.main()
