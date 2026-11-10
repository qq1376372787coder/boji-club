import sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core

class NutritionAvailabilityTests(unittest.TestCase):
    def request(self, known):
        return {'kind':'report','date':'2026-01-01','payload':{'exercises':[], 'meals':[{'name':'未填营养的晚餐','nutrition_known':known,'calories':0,'protein':0,'carbs':0,'fat':0},{'name':'已知早餐','calories':350,'protein':20,'carbs':40,'fat':10}]}}
    def test_unknown_is_null_and_excluded(self):
        result=ai_core.validate_request(self.request(False))
        data=result['payload']
        self.assertIsNone(data['meals'][0]['calories'])
        self.assertIsNone(data['meals'][0]['protein'])
        self.assertEqual(data['totals']['calories'],350)
        self.assertEqual(data['totals']['unknown_nutrition_meals'],1)
        facts=ai_core.analysis_facts(result)
        self.assertEqual(facts['营养数据未知的餐食'][0]['食物'],'未填营养的晚餐')
    def test_old_clients_remain_known(self):
        result=ai_core.validate_request(self.request(True))
        self.assertTrue(result['payload']['meals'][1].get('nutrition_known',True))
        self.assertNotIn('unknown_nutrition_meals',result['payload']['totals'])
        self.assertNotIn('nutrition_known',result['payload']['meals'][1])
    def test_availability_requires_boolean(self):
        for value in ('false',0,None):
            with self.subTest(value=value), self.assertRaises(ai_core.AIError):
                ai_core.validate_request(self.request(value))
    def test_unknown_cannot_smuggle_invalid_numbers(self):
        request=self.request(False);request['payload']['meals'][0]['calories']=-5
        with self.assertRaises(ai_core.AIError): ai_core.validate_request(request)

if __name__=='__main__': unittest.main()
