"""Text meal input, image compatibility, recipient isolation and result integrity."""
import sys, unittest, json, base64, tempfile, uuid
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from ai_core import validate_request, validate_result, messages_for, AIError, Provider, Router
from server import request_audit_summary, JobStore

def request(**fields):
    return {'kind':'food','date':'2026-10-09','payload':{'source':'text','description':'早上吃了俩鸡蛋一根油条','meal_category':'早餐',**fields}}

def result():
    return {'kind':'meal','is_food':True,'name':'鸡蛋与油条','notes':['做法和油条大小尚未提供，请核对'],
        'components':[
            {'name':'鸡蛋','amount':2,'unit':'个','calories':150,'protein':13,'carbs':1,'fat':10,'basis':'described','details':['按普通大小估算']},
            {'name':'油条','amount':1,'unit':'根','calories':200,'protein':4,'carbs':20,'fat':12,'basis':'described','details':['大小未知，按普通份量估算']}],
        'calories':350}

class VoiceMealTests(unittest.TestCase):
    def test_text_does_not_require_image_and_normalizes(self):
        value=validate_request(request(description='  早餐吃了两个鸡蛋  ',audio_base64='never-forward',private_field='hidden'))
        self.assertEqual(value['payload'],{'source':'text','description':'早餐吃了两个鸡蛋','meal_category':'早餐'})
    def test_empty_and_oversized_descriptions_rejected(self):
        for value in ['', '   ', 'x'*2001, None, 17]:
            with self.subTest(value=str(value)[:15]), self.assertRaises(AIError):validate_request(request(description=value))
    def test_input_modes_cannot_be_mixed(self):
        with self.assertRaises(AIError):validate_request(request(image_base64='photo'))
        with self.assertRaises(AIError):validate_request(request(source='audio'))
    def test_invalid_category_rejected(self):
        with self.assertRaises(AIError):validate_request(request(meal_category='午睡'))
    def test_original_photo_input_still_works(self):
        value=validate_request({'kind':'food','date':'2026-10-09','payload':{'image_base64':base64.b64encode(b'\xff\xd8\xff'+b'x'*80).decode(),'context':'早餐'}})
        self.assertEqual(value['payload']['mime'],'image/jpeg')
        self.assertIsInstance(messages_for(value)[1]['content'],list)
    def test_text_prompt_has_no_audio_or_image(self):
        messages=messages_for(validate_request(request()))
        self.assertIsInstance(messages[1]['content'],str)
        self.assertNotIn('image_url',json.dumps(messages))
        self.assertIn('2026-10-09',messages[1]['content'])
        self.assertIn('早餐',messages[1]['content'])
        self.assertIn('不能说看见照片',messages[0]['content'])
    def test_totals_are_computed_from_components(self):
        cleaned=validate_result(validate_request(request()),result())
        self.assertEqual(cleaned['calories'],350)
        self.assertEqual(cleaned['protein'],17)
        self.assertEqual(cleaned['components'][1]['unit'],'根')
        self.assertTrue(cleaned['estimated'])
    def test_no_food_response_does_not_invent_nutrition(self):
        cleaned=validate_result(validate_request(request()),{'kind':'meal','is_food':False,'notes':['请只描述一餐已经吃的食物'],'components':[]})
        self.assertFalse(cleaned['is_food']);self.assertEqual(cleaned['calories'],0)
    def test_text_cannot_claim_visual_evidence(self):
        raw=result();raw['components'][0]['basis']='visible'
        with self.assertRaises(AIError):validate_result(validate_request(request()),raw)
    def test_photo_cannot_claim_described_basis(self):
        with self.assertRaises(AIError):validate_result({'kind':'food','date':'2026-10-09','payload':{'image_base64':'fixture'}},result())
    def test_impossible_nutrients_rejected(self):
        raw=result();raw['components'][0].update(amount=10,unit='g',protein=100)
        with self.assertRaises(AIError):validate_result(validate_request(request()),raw)
    def test_legacy_text_recipient_remains_deepseek_only(self):
        seen=[]
        def transport(provider,messages,limit):seen.append(provider.name);return result(),{}
        providers=[Provider('deepseek','https://example.invalid','text','test'),Provider('mimo','https://example.invalid','text','test',supports_images=False)]
        cleaned,provider,_=Router(providers,transport=transport).run(validate_request(request()))
        self.assertEqual(provider,'deepseek');self.assertEqual(seen,['deepseek']);self.assertEqual(cleaned['calories'],350)
    def test_operational_audit_omits_food_description(self):
        summary=request_audit_summary(validate_request(request()))
        self.assertFalse(summary['photo_submitted']);self.assertNotIn('鸡蛋',json.dumps(summary,ensure_ascii=False))
        self.assertEqual(summary['description_characters'],len(request()['payload']['description']))
    def test_retries_keep_one_job_and_new_meals_can_have_identical_text(self):
        with tempfile.TemporaryDirectory() as folder:
            store=JobStore(Path(folder)/'jobs.sqlite');job=str(uuid.uuid4());value=validate_request(request())
            store.create(job,value);store.create(job,value)
            second=str(uuid.uuid4());store.create(second,value)
            with store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],2)
            changed=validate_request(request(description='午餐吃了米饭'))
            with self.assertRaises(AIError):store.create(job,changed)
    def test_completion_erases_text_input_but_preserves_result(self):
        with tempfile.TemporaryDirectory() as folder:
            store=JobStore(Path(folder)/'jobs.sqlite');job=str(uuid.uuid4());value=validate_request(request())
            store.create(job,value);cleaned=validate_result(value,result());store.complete(job,cleaned,'mimo','fixture')
            with store.connect() as db:self.assertEqual(db.execute('SELECT payload FROM jobs').fetchone()[0],'{}')
            self.assertEqual(store.get(job)['result']['calories'],350)

if __name__=='__main__':unittest.main(verbosity=2)
