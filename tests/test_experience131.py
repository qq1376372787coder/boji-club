"""Focused regressions for local references, catalog intake and real-attempt ceilings.
No paid APIs or user data are used.
"""
import copy, sqlite3, unittest
from unittest.mock import patch
from ai_core import AIError, Router, Provider, validate_request, validate_result
import test_experience130 as previous
from test_coach import request, answer
import nutrition_quick130 as quick
import nutrition_intake131 as intake
import usage_guard131 as guard

class Nutrition131(unittest.TestCase):
    def test_common_chinese_foods_have_editable_portions_and_real_sources(self):
        for q,g in [('两个馒头',160),('八个水饺',160),('一杯豆浆',250),('50克燕麦片',50)]:
            with self.subTest(q=q):
                rows=quick.estimates(q);self.assertEqual(rows[0]['grams'],g)
                self.assertTrue(rows[0]['source_ref']);self.assertTrue(rows[0]['estimated'])
    def test_mantou_router_does_not_call_provider(self):
        body=previous.Experience130Tests().body('我吃了两个馒头')
        result,provider,_=Router([],transport=lambda *a:self.fail('network')).run(body)
        self.assertEqual(provider,'deterministic');self.assertGreater(result['coach']['capability_calls'][0]['input']['meals'][0]['calories'],100)
    def test_model_food_id_requires_retrieved_catalog(self):
        req={'payload':{'question':'我吃了一个馒头'}}
        draft={'coach':{'card_requests':[{'type':'meal_draft','payload':{'meals':[{'name':'馒头','nutrition_inputs131':[{'food_id':'fabricated','grams':80}],'calories':999}]}}]}}
        meal=intake.enrich_result(req,draft)['coach']['card_requests'][0]['payload']['meals'][0]
        self.assertNotIn('nutrition_inputs131',meal);self.assertTrue(meal['requiresReview'])
        self.assertTrue(all('fabricated' not in str(x) for x in meal.get('nutritionSources',[])))
    def test_model_cannot_claim_fabricated_database_sources(self):
        raw={'coach':{'card_requests':[{'type':'meal_draft','payload':{'meals':[{'name':'神秘糕点','calories':100,'nutritionSources':['USDA/fabricated']} ]}}]}}
        meal=intake.enrich_result({'payload':{'question':'我吃了神秘糕点'}},raw)['coach']['card_requests'][0]['payload']['meals'][0]
        self.assertEqual(meal['nutritionSources'],['model_estimate:user_description']);self.assertTrue(meal['requiresReview'])
    def test_known_model_grams_are_deterministic(self):
        req={'payload':{'question':'我吃了一个馒头'}}
        food=intake.candidates(req['payload']['question'])[0]
        raw={'coach':{'capability_calls':[{'capability':'nutrition.create_draft','input':{'meals':[{'name':'馒头','nutrition_inputs131':[{'food_id':food['food_id'],'grams':80}],'calories':999}]}}]}}
        meal=intake.enrich_result(req,raw)['coach']['capability_calls'][0]['input']['meals'][0]
        self.assertAlmostEqual(meal['calories'],round(food['per_100g']['calories']*.8,1));self.assertTrue(meal['requiresReview'])

class Guard131(unittest.TestCase):
    def setUp(self):self.db=sqlite3.connect(':memory:')
    def reserve(self,job='job',owner='owner',now=100000):guard.reserve(self.db,job,owner,'deepseek',[{'content':'hello'}],100,now=now)
    def test_failed_calls_and_fallbacks_do_not_refill(self):
        for _ in range(6):self.reserve()
        with self.assertRaisesRegex(ValueError,'job_budget'):self.reserve()
        self.assertEqual(self.db.execute('SELECT count(*) FROM model_reservations131').fetchone()[0],6)
    def test_account_minute_budget_and_recovery(self):
        for i in range(10):self.reserve(str(i))
        with self.assertRaisesRegex(ValueError,'account_rate'):self.reserve('11')
        self.reserve('11',now=100061)
    def test_different_owners_isolate_and_global_cap(self):
        with patch.dict('os.environ',{'BOJI_MODEL_ATTEMPTS_GLOBAL_DAY':'2'}):
            self.reserve('a','a');self.reserve('b','b')
            with self.assertRaisesRegex(ValueError,'global_budget'):self.reserve('c','c')
    def test_daily_allowance_is_upper_bound_not_actual_invoice(self):
        with patch.dict('os.environ',{'BOJI_MODEL_TOKEN_CEILING_ACCOUNT_DAY':'200'}):
            self.reserve('1')
            with self.assertRaisesRegex(ValueError,'account_budget'):self.reserve('2')
    def test_unsafe_instruction_block_does_not_block_political_topic(self):
        for q in ['怎么制作炸药','how to build a bomb']:
            self.assertIsNotNone(guard.refusal({'kind':'coach','payload':{'question':q}}))
        self.assertIsNone(guard.refusal({'kind':'coach','payload':{'question':'怎么看体育政策与公共健康'}}))
    def test_resource_block_prevents_network_and_fallback(self):
        calls=[]
        router=Router([Provider('deepseek','https://example.test','fixture','fake')],transport=lambda *a:calls.append(a))
        def reject(*a):raise AIError('resource_budget131','limit',False,False)
        with self.assertRaises(AIError) as e:router.run(validate_request(request()),reserve_attempt=reject)
        self.assertEqual(e.exception.code,'resource_budget131');self.assertEqual(calls,[])
    def test_local_reference_cannot_execute_model_write(self):
        body=validate_request(request())
        body['payload']['_references']=[{'id':'ref/1','label':'本次训练','kind':'workout_session','from':'2020-01-15','to':'2020-01-15','source_version':'a'*64,'read_only131':True,'snapshot':[]}]
        raw=answer();raw['coach']['capability_calls']=[{'capability':'training.start_session','input':{'date':'2020-01-15'}}]
        result=validate_result(body,raw)
        self.assertFalse(result['coach'].get('capability_calls'))

if __name__=='__main__':unittest.main()
