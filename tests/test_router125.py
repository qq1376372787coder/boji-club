import copy
import unittest
from ai_core import AIError, Provider, Router, validate_request
from test_coach import request, answer

class Router125Tests(unittest.TestCase):
    def providers(self):
        return [Provider('deepseek','https://example.test','fixture','fake'),Provider('minimax','https://example.test','fixture','fake')]
    def body(self):
        body=request();body['payload']['_routing_version']=3
        return validate_request(body)
    def test_empty_calls_need_no_mutation_whitelist(self):
        from ai_core import validate_result
        value=answer();value['coach']['capability_calls']=[]
        self.assertEqual(validate_result(self.body(),value)['kind'],'coach')
    def test_nonempty_calls_still_require_a_whitelist(self):
        from ai_core import validate_result
        value=answer();value['coach']['capability_calls']=[{'capability':'training.start_session','input':{'date':'2020-01-15'}}]
        with self.assertRaises(AIError):validate_result(self.body(),value)
    def test_json_then_missing_evidence_gets_one_structural_repair(self):
        calls=[];attempts=[]
        def transport(provider,messages,limit):
            calls.append(provider.name)
            if len(calls)==1:raise AIError('invalid_output','fixture',True,True,reason='response_json')
            value=answer()
            if len(calls)==2:value['coach']['source_ids']=[]
            if len(calls)==3:self.assertIn('coach.source_ids',messages[-1]['content'])
            return value,{'prompt_tokens':7,'completion_tokens':9}
        result,provider,_=Router(self.providers(),transport=transport).run(self.body(),record_attempt=attempts.append)
        self.assertEqual(len(calls),3)
        self.assertEqual(set(calls[:2]),{'deepseek','minimax'})
        self.assertEqual(calls[2],calls[1])
        self.assertEqual(provider,calls[1]);self.assertEqual(result['kind'],'coach')
        self.assertEqual([a['outcome'] for a in attempts],['invalid_output','invalid_output','success'])
    def test_repair_never_accepts_missing_evidence(self):
        calls=[]
        def transport(*args):
            calls.append(1);value=answer();value['coach']['source_ids']=[]
            return value,{}
        with self.assertRaises(AIError):Router(self.providers(),transport=transport).run(self.body())
        self.assertEqual(len(calls),3)
    def test_unsupported_health_claim_does_not_gain_extra_repair(self):
        calls=[]
        def transport(*args):
            calls.append(1);value=answer();value['coach']['answer']+='你的动作完全标准。';return value,{}
        with self.assertRaises(AIError):Router(self.providers(),transport=transport).run(self.body())
        self.assertEqual(len(calls),2)
    def test_minimax_stays_outside_legacy_consent_even_on_repair(self):
        calls=[]
        def transport(provider,*args):
            calls.append(provider.name);value=answer();value['coach']['source_ids']=[];return value,{}
        with self.assertRaises(AIError):Router(self.providers(),transport=transport).run(validate_request(request()))
        self.assertEqual(set(calls),{'deepseek'});self.assertLessEqual(len(calls),2)
    def test_no_extra_repair_without_time_budget(self):
        # 2026-11-08 智智修复（CI 红模块分流）：coach 总预算已由 20s 调整为 45s
        # （backend/model_router.py:21）。原断言 clock<=20 只在旧预算下成立，
        # 而 20s 下故障转移本身就不会发生（见 test_router122.test_bucket_and_budget）。
        # 行为契约不变：预算耗尽时不得再追加修复重试。
        # 每次 transport 消耗 22s：首试后剩余 23≥2 允许第二家；第二试后剩余 1<2，
        # 修复槽被预算中断，故 transport 共 2 次、总耗时 44s（<45s 预算）。
        clock=[0];calls=[]
        def transport(*args):
            calls.append(1);clock[0]+=22;value=answer();value['coach']['source_ids']=[];return value,{}
        with self.assertRaises(AIError):Router(self.providers(),transport=transport,clock=lambda:clock[0]).run(self.body())
        self.assertEqual(len(calls),2)
        self.assertLessEqual(clock[0],45)
if __name__=='__main__':unittest.main()
