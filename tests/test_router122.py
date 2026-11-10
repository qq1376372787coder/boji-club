import json,os,tempfile,unittest
from unittest.mock import patch
from pathlib import Path
from ai_core import Provider,providers_from_env,validate_request
from model_router import POLICY,RoutingMetrics,request_body,task_policy
from test_coach import request

class Router122Tests(unittest.TestCase):
    def test_minimax_never_disables_thinking(self):
        p=Provider('minimax','https://example.test','MiniMax-M3.1-Flash','fake')
        POLICY.set({'deep':False});body=request_body(p,[],300,True)
        self.assertEqual(body['reasoning_effort'],'low');self.assertNotIn('thinking',body)
        self.assertNotIn('response_format',body);self.assertGreaterEqual(body['max_completion_tokens'],8192)
        self.assertTrue(body['stream_options']['include_usage'])
    def test_deepseek_fast_and_deep(self):
        p=Provider('deepseek','https://example.test','deepseek-flash','fake')
        POLICY.set({'deep':False});self.assertEqual(request_body(p,[],100,False)['thinking']['type'],'disabled')
        POLICY.set({'deep':True});self.assertEqual(request_body(p,[],100,False)['thinking']['type'],'enabled')
    def test_only_two_configured_providers(self):
        self.assertEqual({p.name for p in providers_from_env()},{'deepseek','minimax'})
    def test_new_consent_version_survives_normalization(self):
        body=request();body['payload']['_routing_version']=3
        self.assertEqual(validate_request(body)['payload']['_routing_version'],3)
    def test_bucket_and_budget(self):
        self.assertEqual(task_policy({'kind':'coach','payload':{}})['budget'],20)
        self.assertEqual(task_policy({'kind':'generate_plan','payload':{}})['budget'],90)
        self.assertEqual(task_policy({'kind':'coach','payload':{'_references':[{}]}})['bucket'],'reference')
    def test_metrics_do_not_store_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            m=RoutingMetrics(Path(tmp)/'metrics.db');m.record('chat','deepseek',True,400,{'first_text_ms':100,'total_tokens':200,'prompt':'private'})
            s=m.snapshot();self.assertEqual(s['samples_24h']['chat/deepseek']['ttft_p95_ms'],100)
            self.assertNotIn('private',json.dumps(s))
    def test_controls_reject_invalid_weights(self):
        with tempfile.TemporaryDirectory() as tmp:
            m=RoutingMetrics(Path(tmp)/'metrics.db')
            with self.assertRaises(ValueError):m.configure({'weights':{'chat':2}})
            with self.assertRaises(ValueError):m.configure({'weights':{'unknown':.5}})
            self.assertEqual(m.configure({'weights':{'chat':.7}})['controls']['weights']['chat'],.7)
    def test_exact_command_uses_durable_result_without_model(self):
        from ai_core import Router
        body=request();body['payload']['question']='开始今天训练'
        body['payload']['capabilities']=[{'capability':'training.start_session','description':'开始训练','input':{'type':'object','properties':{'date':{'type':'string'}},'required':['date']}}]
        router=Router([],transport=lambda *args:self.fail('unexpected model call'))
        value,provider,model=router.run(validate_request(body))
        self.assertEqual(provider,'deterministic')
        self.assertEqual(value['coach']['capability_calls'][0]['capability'],'training.start_session')
    def test_minimax_cannot_receive_legacy_consent(self):
        from ai_core import Router,AIError
        body=validate_request(request());calls=[]
        router=Router([Provider('minimax','https://example.test','test','fake')],transport=lambda *a:calls.append(a))
        with self.assertRaises(AIError):router.run(body)
        self.assertEqual(calls,[])

if __name__=='__main__':unittest.main()
