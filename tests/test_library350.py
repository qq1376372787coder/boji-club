import importlib.util,json,os,sys,threading,unittest,urllib.parse,urllib.request
from pathlib import Path
from http.server import ThreadingHTTPServer
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'tests/fixtures/exercise-library-original.json'
sys.path.insert(0,str(ROOT/'backend'))
import ai_core
class CuratedLibraryTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  old=os.environ.get('EXERCISES_JSON');os.environ['EXERCISES_JSON']=str(SOURCE)
  try:
   spec=importlib.util.spec_from_file_location('curated_test_api',ROOT/'exercise-server/api.py');cls.api=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.api)
  finally:
   if old is None:os.environ.pop('EXERCISES_JSON',None)
   else:os.environ['EXERCISES_JSON']=old
  cls.http=ThreadingHTTPServer(('127.0.0.1',0),cls.api.Handler);cls.worker=threading.Thread(target=cls.http.serve_forever,daemon=True);cls.worker.start()
 @classmethod
 def tearDownClass(cls):cls.http.shutdown();cls.http.server_close();cls.worker.join()
 def request(self,path):
  with urllib.request.urlopen(f'http://127.0.0.1:{self.http.server_port}'+path,timeout=5) as r:return json.load(r)
 def test_paginated_catalog_exactly_350(self):
  ids=[]
  for offset in range(0,700,100):
   page=self.request('/api/v1/exercises?limit=100&offset='+str(offset));self.assertEqual(page['total'],678);ids.extend(x['id'] for x in page['items'])
  self.assertEqual(len(ids),678);self.assertEqual(set(ids),set(self.api.CURATED))
 def test_all_974_historical_records_retained(self):
  excluded=set(self.api.BY_ID)-set(self.api.CURATED);self.assertEqual(len(excluded),659)
  for id in excluded:self.assertFalse(self.api.detail(self.api.BY_ID[id],'zh')['catalog_visible'])
  result=self.request('/api/v1/exercises/3299');self.assertEqual(result['id'],'3299');self.assertFalse(result['catalog_visible'])
 def test_hidden_english_and_chinese_queries_are_empty(self):
  for query in ['full planche',self.api.NAME_ZH['3299']]:
   self.assertEqual(self.request('/api/v1/exercises?q='+urllib.parse.quote(query))['total'],0)
 def test_every_chinese_name_finds_its_own_id(self):
  for id,row in self.api.CURATED.items():
   response=self.request('/api/v1/exercises?limit=100&q='+urllib.parse.quote(row['name_zh']))
   self.assertIn(id,[x['id'] for x in response['items']],row['name_zh'])
 def test_alias_search(self):
  for query,id in [('倒蹬机','0739'),('RDL','0085'),('反向飞鸟机','0602')]:
   self.assertIn(id,[x['id'] for x in self.request('/api/v1/exercises?q='+urllib.parse.quote(query))['items']])
 def test_part_filters_cover_all_selected_rows_once(self):
  parts=self.request('/api/v1/facets')['body_parts'];self.assertIn('glutes',parts);self.assertIn('lower legs',parts)
  total=sum(self.request('/api/v1/exercises?body_part='+urllib.parse.quote(part))['total'] for part in parts);self.assertEqual(total,678)
 def test_hidden_resolution_never_exposes_legacy_items(self):
  path='/api/v1/resolve?q='+urllib.parse.quote('full planche')
  self.assertIsNone(self.request(path)['item']);self.assertIsNone(self.request(path+'&include_legacy=1')['item'])
 def test_list_cache_no_store(self):
  with urllib.request.urlopen(f'http://127.0.0.1:{self.http.server_port}/api/v1/exercises') as r:self.assertEqual(r.headers['Cache-Control'],'no-store')
 def test_health_counts_distinguish_visible_from_retained(self):
  health=self.request('/api/v1/health');self.assertEqual(health['count'],678);self.assertEqual(health['retained_count'],1324)
 def test_media_and_ids_unchanged(self):
  for row in self.api.CURATED_ROWS:
   detail=self.api.summary(self.api.BY_ID[row['id']]);self.assertEqual(detail['name'],row['name'])
   if row['gif_url']: self.assertTrue(detail['gif_url'].endswith(row['gif_url']))
   else: self.assertIsNone(detail['gif_url']);self.assertIsNone(detail['image_url']);self.assertFalse(detail['has_demo'])
 def test_home_candidates_are_selected(self):
  for equipment in ['','哑铃','哑铃、卧推凳','弹力带','壶铃','引体向上杆']:
   candidates=ai_core.home_movements({'equipment':equipment});self.assertGreaterEqual(len(candidates),3)
   self.assertTrue(all(ai_core.recommended_reference(q) is not None for q in candidates))
 def test_static_catalog_units(self):
  self.assertTrue(ai_core.requires_duration('side bridge v. 2'));self.assertTrue(ai_core.requires_duration('weighted front plank'));self.assertFalse(ai_core.requires_duration('front plank with twist'))
 def test_hidden_movement_not_recommended(self):self.assertIsNone(ai_core.recommended_reference('full planche'))
 def test_canonical_alias_ids(self):
  self.assertEqual(ai_core.movement_reference('barbell squat'),'0043');self.assertEqual(ai_core.movement_reference('glute bridge'),'3013')
 def test_generated_hidden_movement_rejected(self):
  from test_backend_v2 import request,result
  value=result();value['sessions'][0]['exercises'][0]['library_query']='full planche'
  with self.assertRaises(ai_core.AIError):ai_core.validate_result(request(),value)
 def test_generated_names_use_curated_chinese(self):
  from test_backend_v2 import request,result
  value=ai_core.validate_result(request(),result())
  for session in value['sessions']:
   for ex in session['exercises']:
    row=ai_core.recommended_reference(ex['library_query']);self.assertEqual(ex['library_id'],row['id']);self.assertEqual(ex['name'],row['name_zh'])
 def test_weekly_hidden_action_never_returns_applicable_sessions(self):
  from test_backend_offline import weekly_request,weekly_result
  value=weekly_result()
  for session in value['sessions']:
   for ex in session['exercises']:ex['library_query']='full planche'
  output=ai_core.validate_result(ai_core.validate_request(weekly_request()),value)
  self.assertEqual(output['decision'],'insufficient');self.assertEqual(output['sessions'],[])
 def test_source_still_has_1324_items(self):self.assertEqual(len(json.loads(SOURCE.read_text(encoding='utf-8-sig'))),1324)
if __name__=='__main__':unittest.main()
