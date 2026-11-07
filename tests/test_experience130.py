"""Focused deterministic nutrition regressions. No paid model calls."""
import copy, unittest
from ai_core import Router, validate_request
from test_coach import request
from nutrition_quick130 import estimates, fast_result, enrich_result
import nutrition_engine

class Experience130Tests(unittest.TestCase):
    def body(self, question):
        raw=request(); raw['payload']['question']=question
        raw['payload']['capabilities']=[{'capability':'nutrition.create_draft','description':'起草饮食记录','input':{'type':'object','properties':{'date':{'type':'string'},'meals':{'type':'array','items':{'type':'object'}}},'required':['date','meals']}}]
        return validate_request(raw)
    def test_chinese_quantity_uses_catalog_arithmetic(self):
        values=estimates('我吃了六个鸡蛋')
        self.assertEqual(len(values),1);self.assertEqual(values[0]['grams'],300)
        food=nutrition_engine.match_food('水煮鸡蛋')
        self.assertEqual(values[0]['calories'],round(food['per_100g']['calories']*3,1))
        self.assertTrue(values[0]['estimated']);self.assertTrue(values[0]['source_ref'])
    def test_real_router_fast_path_preserves_portion_and_sources(self):
        result,provider,_=Router([],transport=lambda *a:self.fail('unexpected model request')).run(self.body('我吃了六个鸡蛋'))
        self.assertEqual(provider,'deterministic')
        meal=result['coach']['capability_calls'][0]['input']['meals'][0]
        self.assertIn('6个',meal['portion']);self.assertTrue(meal['nutritionSources']);self.assertTrue(meal['requiresReview'])
    def test_oilstick_is_primary_source_and_has_uncertainty(self):
        v=estimates('十根油条')[0]
        self.assertEqual(v['grams'],540);self.assertEqual(v['source_ref'],'tfda-R3000101')
        self.assertGreater(v['calories'],v['low']['calories']);self.assertLess(v['calories'],v['high']['calories'])
    def test_hypothetical_and_negated_intake_never_creates_draft(self):
        for q in ('比如我吃了5个鸡蛋','假如我吃了六个鸡蛋','我没吃六个鸡蛋'):
            result=fast_result(self.body(q))
            if result:self.assertFalse(result['coach'].get('capability_calls') or result['coach'].get('card_requests'))
            raw={'coach':{'card_requests':[{'type':'meal_draft'}], 'capability_calls':[{'capability':'nutrition.create_draft'}]}}
            clean=enrich_result(self.body(q),raw)['coach']
            self.assertFalse(clean['card_requests']);self.assertFalse(clean['capability_calls'])
    def test_corrections_unknown_food_and_pictures_fall_back(self):
        for q in ('不是6个，是5个鸡蛋','我吃了六个鸡蛋和三块神秘糕点','我吃了六个鸡蛋，胸痛'):
            self.assertIsNone(fast_result(self.body(q)),q)
        body=self.body('我吃了六个鸡蛋');body['payload']['deep_analysis']=True
        self.assertIsNone(fast_result(body))
    def test_multiple_foods_and_grams(self):
        v=estimates('两个鸡蛋和180克米饭')
        self.assertEqual([x['grams'] for x in v],[100,180])
        self.assertEqual(estimates('半碗米饭')[0]['grams'],90)
    def test_repeated_same_food_not_misattributed_by_enricher(self):
        raw={'coach':{'capability_calls':[{'capability':'nutrition.create_draft','input':{'meals':[{'name':'鸡蛋','calories':123}]}}]}}
        clean=enrich_result(self.body('早餐两个鸡蛋，晚餐六个鸡蛋'),raw)
        self.assertEqual(clean['coach']['capability_calls'][0]['input']['meals'][0]['calories'],123)

if __name__=='__main__':unittest.main()
