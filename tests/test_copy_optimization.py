"""Behavior checks for translated exercise content; no account or private data."""
import importlib.util,json,os,tempfile,threading,unittest,urllib.parse,urllib.request
from pathlib import Path
from http.server import ThreadingHTTPServer

ROOT=Path(__file__).resolve().parents[1]

class CopyOptimizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.dataset=[{'id':'0025','name':'barbell bench press','body_part':'chest','equipment':'barbell','target':'pectorals','instructions':{'zh':'握住电缆手柄。重复所需的重复次数。','en':'Original instruction.'},'instruction_steps':{'zh':['握住电缆手柄。']}},
                     {'id':'2963','name':'captains chair straight leg raise','body_part':'waist','equipment':'body weight','target':'abs','instructions':{'zh':'保持核心参与。'},'instruction_steps':{'zh':['保持核心参与。']}},
                     {'id':'0987','name':'band one arm single leg split squat','body_part':'upper legs','equipment':'band','instructions':{'zh':'向前伸出一条腿，将脚尖放在身后的一步上。','en':'Original English.'},'instruction_steps':{'zh':['Ambiguous direction.']}}]
        data=Path(cls.temp.name)/'data.json';data.write_text(json.dumps(cls.dataset),encoding='utf-8')
        previous=os.environ.get('EXERCISES_JSON');os.environ['EXERCISES_JSON']=str(data)
        try:
            spec=importlib.util.spec_from_file_location('exercise_copy_test',ROOT/'exercise-server/api.py')
            cls.api=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.api)
        finally:
            if previous is None:os.environ.pop('EXERCISES_JSON',None)
            else:os.environ['EXERCISES_JSON']=previous
        cls.http=ThreadingHTTPServer(('127.0.0.1',0),cls.api.Handler)
        cls.worker=threading.Thread(target=cls.http.serve_forever,daemon=True);cls.worker.start()
    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown();cls.http.server_close();cls.worker.join();cls.temp.cleanup()
    def request(self,path):
        with urllib.request.urlopen(f'http://127.0.0.1:{self.http.server_port}'+path,timeout=3) as response:return json.load(response)
    def test_additive_translation_preserves_canonical_name_and_id(self):
        value=self.api.summary(self.dataset[0]);self.assertEqual(value['id'],'0025');self.assertEqual(value['name'],'barbell bench press');self.assertEqual(value['name_zh'],'平板杠铃卧推')
    def test_new_chinese_name_search_does_not_require_english_alias(self):
        result=self.request('/api/v1/exercises?q='+urllib.parse.quote('队长椅直腿举腿'));self.assertEqual([x['id'] for x in result['items']],['2963'])
    def test_english_query_still_matches_existing_canonical_name(self):
        result=self.request('/api/v1/exercises?q='+urllib.parse.quote('barbell bench press'));self.assertEqual(result['items'][0]['id'],'0025')
    def test_clear_translation_repairs_apply_to_text_and_steps(self):
        result=self.api.detail(self.dataset[0],'zh');self.assertIn('拉力器手柄',result['instructions']);self.assertNotIn('重复所需',result['instructions']);self.assertIn('拉力器手柄',result['instruction_steps'][0])
    def test_english_original_is_not_rewritten(self):
        self.assertEqual(self.api.detail(self.dataset[0],'en')['instructions'],'Original instruction.')
    def test_conflicting_direction_is_withheld_and_explained(self):
        result=self.api.detail(self.dataset[2],'zh');self.assertTrue(result['copy_review_needed']);self.assertEqual(result['instruction_steps'],[]);self.assertIn('正在核对',result['instructions']);self.assertNotIn('身后',result['instructions'])

if __name__=='__main__':unittest.main()
