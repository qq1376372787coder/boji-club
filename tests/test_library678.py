"""API and AI boundary behavior for expanded catalog, using original source fixtures."""
import unittest,json,urllib.parse,sys,copy
from pathlib import Path
import test_library350 as library_fixture
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
import ai_core
from curated_library import candidate_prompt,resolve_generated_movement

class ExpandedLibraryTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  library_fixture.CuratedLibraryTests.setUpClass();cls.api=library_fixture.CuratedLibraryTests.api;cls.http=library_fixture.CuratedLibraryTests.http
 @classmethod
 def tearDownClass(cls):library_fixture.CuratedLibraryTests.tearDownClass()
 def request(self,path):return library_fixture.CuratedLibraryTests.request(self,path)
 def test_type_filters_partition_visible_catalog(self):
  count=0
  for kind in ['力量／稳定性','有氧','体能／全身','拉伸／活动度']:
   path='/api/v1/exercises?training_type='+urllib.parse.quote(kind)+'&limit=100'
   page=self.request(path);count+=page['total']
   self.assertTrue(all(x['training_type_zh']==kind for x in page['items']))
  self.assertEqual(count,678)
 def test_aerobic_is_duration_and_distinct_from_conditioning(self):
  page=self.request('/api/v1/exercises?training_type='+urllib.parse.quote('有氧')+'&limit=100')
  self.assertEqual(page['total'],20)
  self.assertTrue(all(x['suggested_recording_unit']=='time' for x in page['items']))
  self.assertNotIn('2133',{x['id'] for x in page['items']})
  self.assertEqual(self.request('/api/v1/exercises/2133')['training_type_zh'],'体能／全身')
 def test_supplemental_does_not_borrow_media(self):
  for x in self.api.SUPPLEMENTAL_EXERCISES:
   detail=self.request('/api/v1/exercises/'+x['id'])
   self.assertTrue(detail['catalog_visible']);self.assertIsNone(detail['gif_url']);self.assertIsNone(detail['image_url'])
   self.assertFalse(detail['has_demo']);self.assertGreater(len(detail['instruction_steps']),0)
 def test_new_chinese_and_english_resolve_the_same_record(self):
  for query,id in [('划船机','boji-cardio-row'),('rowing machine','boji-cardio-row'),('平板支撑','boji-basic-plank'),('plank','boji-basic-plank'),('body weight squat','boji-basic-squat'),('鸟狗式','boji-basic-bird-dog')]:
   self.assertEqual(self.request('/api/v1/resolve?q='+urllib.parse.quote(query))['item']['id'],id)
   self.assertEqual(ai_core.recommended_reference(query)['id'],id)
 def test_original_350_preserved_and_659_hidden_retained(self):
  old=json.loads((ROOT/'exercise-server/exercise-catalog-350-zh.json').read_text(encoding='utf-8'))
  self.assertTrue({x['id'] for x in old} <= set(self.api.CURATED))
  original_ids={x['id'] for x in self.api.ORIGINAL_EXERCISES}
  self.assertEqual(len(original_ids-set(self.api.CURATED)),659)
  self.assertEqual(self.request('/api/v1/health')['retained_count'],1324)
 def test_source_and_media_mapping_never_changes(self):
  source={x['id']:x for x in self.api.ORIGINAL_EXERCISES}
  for row in self.api.CURATED_ROWS:
   if row['id'] in source:
    for field in ['name','equipment','image','gif_url','media_id']:self.assertEqual(row[field],source[row['id']].get(field))
 def test_new_home_basics_are_available_without_invented_equipment(self):
  home=ai_core.home_movements({'equipment':'徒手'})
  self.assertTrue({'bodyweight squat','plank','bird dog','wall sit','marching in place','low impact step jack'}<=set(home))
  self.assertNotIn('rowing machine',home)
 def test_prompt_uses_core_subset_with_recording_units(self):
  prompt=candidate_prompt();data=json.loads(prompt.split('目录：',1)[1])
  self.assertLess(len(data),400)
  self.assertIn('boji-basic-squat',{x['id'] for x in data})
  self.assertIn('boji-cardio-row',{x['id'] for x in data})
  self.assertNotIn('3294',{x['id'] for x in data})
  self.assertTrue(all(x.get('unit','reps') in ('time','reps') for x in data))
  self.assertEqual(next(x for x in data if x['id']=='boji-cardio-row')['unit'],'time')
 def test_timed_cardio_plan_rejects_counted_sets(self):
  from test_backend_v2 import request,result
  req=request();req['payload']['profile']['venue']='健身房'
  output=result()
  for s in output['sessions']:
   s['exercises'][0]={'name':'划船机','muscle':'心肺耐力','library_query':'rowing machine','library_id':'boji-cardio-row','sets':[{'weight':None,'reps':0,'durationSeconds':600}]}
  parsed=ai_core.validate_result(req,copy.deepcopy(output));self.assertEqual(parsed['sessions'][0]['exercises'][0]['library_id'],'boji-cardio-row')
  for s in output['sessions']:s['exercises'][0]['sets']=[{'weight':None,'reps':10}]
  with self.assertRaises(ai_core.AIError):ai_core.validate_result(req,output)
 def test_conflicting_new_id_and_query_rejected(self):
  with self.assertRaises(ValueError):resolve_generated_movement({'library_id':'boji-cardio-row','library_query':'brisk walking'})
 def test_combined_type_body_equipment_search(self):
  page=self.request('/api/v1/exercises?training_type='+urllib.parse.quote('有氧')+'&body_part=cardio&q='+urllib.parse.quote('划船机'))
  self.assertEqual([x['id'] for x in page['items']],['boji-cardio-row'])
  self.assertEqual(self.request('/api/v1/exercises?training_type='+urllib.parse.quote('力量／稳定性')+'&q='+urllib.parse.quote('划船机'))['total'],0)
 def test_health_distinguishes_supplemental_count(self):
  health=self.request('/api/v1/health')
  self.assertEqual((health['count'],health['retained_count'],health['supplemental_count']),(678,1324,13))

if __name__=='__main__':unittest.main()
