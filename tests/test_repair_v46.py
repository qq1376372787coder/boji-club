import sys, unittest, copy
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
import ai_core as core
from curated_library import resolve_generated_movement
from test_backend_v2 import request,result

class CatalogIdentityRepair(unittest.TestCase):
 def test_common_pulldown_alias(self):
  self.assertEqual(core.recommended_reference('lat pulldown')['id'],'0150')
 def test_explicit_id_canonicalizes_unfamiliar_spelling(self):
  value=result();ex=value['sessions'][0]['exercises'][0]
  ex['library_id']='0150';ex['library_query']='wide grip lat pull down';ex['name']='宽握高位下拉'
  req=request();req['payload']['profile']['venue']='健身房'
  clean=core.validate_result(req,value)['sessions'][0]['exercises'][0]
  self.assertEqual(clean['library_id'],'0150');self.assertEqual(clean['library_query'],'cable bar lateral pulldown')
 def test_explicit_id_without_english_query(self):
  value=result();ex=value['sessions'][0]['exercises'][0];ex['library_id']='0150';ex.pop('library_query')
  req=request();req['payload']['profile']['venue']='健身房'
  self.assertEqual(core.validate_result(req,value)['sessions'][0]['exercises'][0]['library_id'],'0150')
 def test_conflicting_id_rejected(self):
  with self.assertRaises(ValueError):resolve_generated_movement({'library_id':'0150','library_query':'barbell squat'},core.MOVEMENT_CATALOG)
 def test_unknown_and_numeric_id_rejected(self):
  for id in ['99999',150,'3299']:
   with self.subTest(id=id),self.assertRaises(ValueError):resolve_generated_movement({'library_id':id})
 def test_no_fuzzy_or_chinese_name_guessing(self):
  self.assertIsNone(resolve_generated_movement({'name':'宽握高位下拉','library_query':'made up move'}))
 def test_home_equipment_check_cannot_be_bypassed_with_id(self):
  value=result();ex=value['sessions'][0]['exercises'][0];ex['library_id']='0150';ex['library_query']='lat pulldown'
  with self.assertRaises(core.AIError):core.validate_result(request(),value)
 def test_missing_optional_plan_notes(self):
  value=result();value.pop('notes');self.assertEqual(core.validate_result(request(),value)['notes'],[])
 def test_invalid_notes_not_silently_discarded(self):
  value=result();value['notes']='broken'
  with self.assertRaises(core.AIError):core.validate_result(request(),value)
 def test_missing_report_content_still_rejected(self):
  with self.assertRaises(core.AIError):core.validate_result({'kind':'report','payload':{}},{'kind':'report','summary':'只有摘要'})
 def test_plan_prompt_contains_catalog_identity(self):
  prompt=core.messages_for(request())[0]['content'];self.assertIn('library_id',prompt);self.assertIn('保留前导零',prompt)
 def test_home_prompt_does_not_offer_gym_catalog(self):
  prompt=core.messages_for(request())[0]['content']
  self.assertNotIn('cable bar lateral pulldown',prompt)
  self.assertIn('居家课堂仅允许这些动作编号',prompt)
 def test_rest_units_keep_numbers(self):
  self.assertEqual(core.plan_display_text('每组休息90 sec，warm-up 5 min。'),'每组休息90 秒，热身 5 分钟。')
 def test_catalog_degree_symbol_is_not_a_foreign_action(self):
  value=result();ex=value['sessions'][0]['exercises'][0];ex['library_id']='0739';ex.pop('library_query')
  req=request();req['payload']['profile']['venue']='健身房'
  self.assertEqual(core.validate_result(req,value)['sessions'][0]['exercises'][0]['library_id'],'0739')

if __name__=='__main__':unittest.main()
