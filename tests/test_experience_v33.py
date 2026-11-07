"""New routing, consent isolation, real schemas and bounded fallback."""
import base64,copy,os,tempfile,unittest
from unittest.mock import patch
from pathlib import Path
from test_voice_meal import request as text_request, result as meal_result
from test_backend_offline import weekly_request, weekly_result
from test_backend_v2 import request as plan_request, result as plan_result
from ai_core import AIError,Provider,Router,validate_request,providers_from_env
from server import JobStore

class ExperienceRouting(unittest.TestCase):
    def providers(self, images=True):
        return [Provider(name,'https://example.invalid','fixture','synthetic',60,images,True,rank)
                for name,rank in [('deepseek',10),('minimax',20)]]
    def ordered_router(self, transport, clock=None):
        router=Router(self.providers(),transport,clock=clock or __import__('time').monotonic)
        router.routing_metrics.order=lambda providers,request:sorted(providers,key=lambda p:p.priority)
        return router
    def test_defaults_match_fixed_product_order_and_image_support(self):
        with patch.dict(os.environ,{},clear=True):
            values=providers_from_env()
        self.assertEqual([p.name for p in values],['deepseek','minimax'])
        self.assertTrue(all(p.supports_images for p in values))
    def test_new_text_food_falls_back_in_order(self):
        value=validate_request(text_request(_routing_version=3));seen=[]
        def transport(p,*args):
            seen.append(p.name)
            if p.name!='minimax':raise AIError('upstream_timeout','fixture',True,True)
            return meal_result(),{}
        _,provider,_=self.ordered_router(transport).run(value)
        self.assertEqual(seen,['deepseek','minimax']);self.assertEqual(provider,'minimax')
    def test_legacy_food_does_not_expand_recipients(self):
        seen=[]
        def transport(p,*args):seen.append(p.name);return meal_result(),{}
        self.ordered_router(transport).run(validate_request(text_request()))
        self.assertEqual(seen,['deepseek'])
    def test_new_photo_uses_approved_vision_providers(self):
        raw={'kind':'food','date':'2026-10-09','payload':{'image_base64':base64.b64encode(b'\xff\xd8\xff'+b'a'*100).decode(),'_routing_version':3}}
        value=validate_request(raw);self.assertEqual(value['payload']['_routing_version'],3)
        seen=[]
        def transport(p,*args):
            seen.append(p.name)
            if p.name!='minimax':raise AIError('invalid_output','fixture',True,True)
            return {'kind':'meal','is_food':False,'notes':[]},{}
        self.ordered_router(transport).run(value)
        self.assertEqual(seen,['deepseek','minimax'])
        providers=self.providers();providers[0].supports_images=False;providers[1].supports_images=False;seen.clear()
        with self.assertRaises(AIError):
            router=Router(providers,transport);router.routing_metrics.order=lambda ps,req:sorted(ps,key=lambda p:p.priority);router.run(value)
        self.assertEqual(seen,[])
    def test_legacy_weekly_review_routes_only_legacy_approved_provider(self):
        raw=weekly_request();raw['payload']['_routing_version']=2
        value=validate_request(raw);seen=[]
        def transport(p,*args):seen.append(p.name);return weekly_result(),{}
        self.ordered_router(transport).run(value)
        self.assertEqual(seen,['deepseek']);self.assertEqual(value['payload']['_routing_version'],2)
    def test_budget_shrinks_for_later_providers(self):
        value=validate_request(text_request(_routing_version=3));seen=[];time=[0]
        def transport(p,*args):
            seen.append((p.name,p.timeout));time[0]+=p.timeout
            raise AIError('upstream_timeout','fixture',True,True)
        with self.assertRaises(AIError) as caught:self.ordered_router(transport,clock=lambda:time[0]).run(value)
        self.assertEqual(seen,[('deepseek',10),('minimax',10)])
        # Every provider timed out transiently: the job must be retried with
        # backoff instead of being terminally failed on the first logical pass.
        self.assertEqual(caught.exception.code,'all_unavailable')
        self.assertTrue(caught.exception.retryable)
    def test_deadline_stops_further_transport(self):
        value=validate_request(text_request(_routing_version=3));seen=[];time=[0]
        def transport(p,*args):seen.append(p.name);time[0]=121;raise AIError('upstream_timeout','fixture',True,True)
        with self.assertRaises(AIError) as caught:self.ordered_router(transport,clock=lambda:time[0]).run(value)
        self.assertEqual(seen,['deepseek']);self.assertEqual(caught.exception.code,'task_timeout')
    def test_invalid_consent_version_is_rejected(self):
        for version in (True,'2',1,4):
            with self.assertRaises(AIError):validate_request(text_request(_routing_version=version))
    def test_plan_fallback_and_chinese_names_remain_valid(self):
        value=plan_request();value['payload']['_routing_version']=3;seen=[]
        def transport(p,*args):
            seen.append(p.name)
            if p.name!='minimax':raise AIError('provider_config','fixture',True,True)
            return plan_result(),{}
        result,_,_=self.ordered_router(transport).run(value)
        self.assertEqual(seen,['deepseek','minimax'])
        for session in result['sessions']:
            for exercise in session['exercises']:self.assertRegex(exercise['name'],r'[\u4e00-\u9fff]')
    def test_exhausted_route_uses_retryable_flag_not_the_code(self):
        with tempfile.TemporaryDirectory() as folder:
            store=JobStore(Path(folder)/'jobs.sqlite');store.create('fixture',validate_request(text_request(_routing_version=2)))
            job=store.claim();self.assertIsNotNone(job)
            store.fail(job[0],AIError('all_unavailable','fixture',True),1,job[3])
            self.assertEqual(store.get('fixture')['status'],'retrying')
            store.fail(job[0],AIError('all_unavailable','fixture',False),2)
            self.assertEqual(store.get('fixture')['status'],'failed')

if __name__=='__main__':unittest.main()
