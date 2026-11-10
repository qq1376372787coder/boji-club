"""Batch food validation, old protocol compatibility and durable job identity."""
import copy, datetime as dt, json, sys, tempfile, unittest, uuid
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from ai_core import validate_request, validate_result, messages_for, AIError, Router, Provider
from server import JobStore, request_audit_summary
from test_voice_meal import result as single_result

TODAY = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date()
def request(**fields):
    return validate_request({'kind':'food','date':TODAY.isoformat(),'payload':{'source':'text','mode':'multiple',
        'reference_date':TODAY.isoformat(),'description':'今天早餐两个鸡蛋一根油条，中午一碗牛肉面，晚上半碗米饭和青菜','meal_category':'早餐',**fields}})
def raw():
    meals=[]
    for category in ['早餐','午餐','晚餐']:
        item=single_result();item.update(date=TODAY.isoformat(),category=category)
        meals.append(item)
    return {'kind':'meal_batch','notes':[],'meals':meals,'calories':99999}

class MultiMealTests(unittest.TestCase):
    def test_text_batch_keeps_only_allowed_payload(self):
        value=request(audio_base64='never',private='hidden')
        self.assertNotIn('audio_base64', value['payload']);self.assertNotIn('private',value['payload'])
        self.assertEqual(value['payload']['mode'],'multiple')
    def test_invalid_mode_reference_and_photo_batch_rejected(self):
        for fields in [{'mode':'many'},{'reference_date':'2026-02-30'},{'image_base64':'fixture'}]:
            with self.subTest(fields=fields),self.assertRaises(AIError):request(**fields)
        with self.assertRaises(AIError):validate_request({'kind':'food','date':TODAY.isoformat(),'payload':{'mode':'multiple','image_base64':'fixture'}})
    def test_prompt_separates_reference_from_record_date(self):
        value=request();value['date']=(TODAY-dt.timedelta(days=3)).isoformat()
        messages=messages_for(value);content=json.loads(messages[1]['content'])
        self.assertEqual(content['reference_date'],TODAY.isoformat())
        self.assertEqual(content['base_record_date'],value['date'])
        self.assertIn('meal_batch',messages[0]['content']);self.assertNotIn('image_url',json.dumps(messages))
    def test_meals_independent_totals_and_stable_child_ids(self):
        value=validate_result(request(),raw())
        self.assertEqual([m['id'] for m in value['meals']],['m1','m2','m3'])
        self.assertEqual([m['category'] for m in value['meals']],['早餐','午餐','晚餐'])
        self.assertEqual([m['calories'] for m in value['meals']],[350,350,350])
        self.assertNotIn('calories',value)
        self.assertEqual(value['meals'][0]['components'][0]['amount'],2)
        self.assertEqual(len({c['id'] for m in value['meals'] for c in m['components']}),6)
    def test_different_dates_and_two_snacks_are_kept(self):
        value=raw();value['meals'][0]['date']=(TODAY-dt.timedelta(days=1)).isoformat()
        value['meals'][1]['category']=value['meals'][2]['category']='加餐'
        clean=validate_result(request(),value)
        self.assertNotEqual(clean['meals'][1]['id'],clean['meals'][2]['id'])
        self.assertNotEqual(clean['meals'][0]['date'],clean['meals'][1]['date'])
    def test_future_and_bad_dates_rejected(self):
        for date in [(TODAY+dt.timedelta(days=1)).isoformat(),'2026-02-30','20261009']:
            value=raw();value['meals'][0]['date']=date
            with self.subTest(date=date),self.assertRaises(AIError):validate_result(request(),value)
    def test_bad_category_and_fake_visual_evidence_rejected(self):
        value=raw();value['meals'][0]['category']='午睡'
        with self.assertRaises(AIError):validate_result(request(),value)
        value=raw();value['meals'][0]['components'][0]['basis']='visible'
        with self.assertRaises(AIError):validate_result(request(),value)
    def test_nutrient_mass_still_validated_per_meal(self):
        value=raw();value['meals'][2]['components'][0].update(unit='g',amount=1,protein=300)
        with self.assertRaises(AIError):validate_result(request(),value)
    def test_no_silent_truncation_above_six_meals(self):
        value=raw();value['meals']*=3
        with self.assertRaises(AIError):validate_result(request(),value)
    def test_total_component_limit(self):
        value=raw();value['meals']*=2
        for item in value['meals']:item['components']=copy.deepcopy(item['components']*4)
        with self.assertRaises(AIError):validate_result(request(),value)
    def test_empty_batch_requires_explanation(self):
        value={'kind':'meal_batch','notes':['没有明确吃过的食物，请补充食物名称'],'meals':[]}
        self.assertEqual(validate_result(request(),value)['meals'],[])
        value['notes']=[]
        with self.assertRaises(AIError):validate_result(request(),value)
    def test_single_result_cannot_silently_replace_batch(self):
        with self.assertRaises(AIError):validate_result(request(),single_result())
    def test_batch_uses_current_text_provider_with_sufficient_output_budget(self):
        seen=[]
        def transport(provider,messages,limit):seen.append((provider.name,limit));return raw(),{}
        providers=[Provider('deepseek','https://example.invalid','text','test'),Provider('mimo','https://example.invalid','text','test')]
        value,provider,_=Router(providers,transport=transport).run(request())
        self.assertEqual(seen,[('deepseek',8192)]);self.assertEqual(len(value['meals']),3)
    def test_audit_does_not_store_description(self):
        value=request();summary=request_audit_summary(value)
        self.assertTrue(summary['multiple_meals']);self.assertNotIn('鸡蛋',json.dumps(summary,ensure_ascii=False))
    def test_retry_keeps_one_job_and_completed_children(self):
        with tempfile.TemporaryDirectory() as folder:
            store=JobStore(Path(folder)/'jobs.sqlite');job=str(uuid.uuid4());value=request()
            store.create(job,value);store.create(job,value)
            clean=validate_result(value,raw());store.complete(job,clean,'mimo','fixture')
            self.assertEqual(store.get(job)['result']['meals'][1]['id'],'m2')
            with store.connect() as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)
                self.assertEqual(db.execute('SELECT payload FROM jobs').fetchone()[0],'{}')

if __name__=='__main__':unittest.main(verbosity=2)
