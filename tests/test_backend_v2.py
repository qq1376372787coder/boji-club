"""Meaningful repair regressions on synthetic requests and SQLite only."""
import copy, importlib.util, json, os, sys, tempfile, threading, time, unittest, uuid
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
import ai_core as core
import server

def request():
 return core.validate_request({'kind':'generate_plan','date':'2026-09-30','payload':{'profile':{'age':28,'height':175,'weight':68,'daysPerWeek':3,'trainingDays':[1,3,5],'homeTrainingDays':[],'goal':'增肌塑形','experience':'新手','venue':'在家','equipment':'徒手','focus':'全身'}}})
def result():
 ex=lambda q:{'name':'测试动作','muscle':'全身','library_query':q,'sets':[{'weight':None,'reps':0,'durationSeconds':30}] if q=='side plank' else [{'weight':None,'reps':10}]}
 return {'kind':'plan','notes':[],'title':'Fixture','sessions':[{'date':d,'label':'Fixture','exercises':[ex('lunge'),ex('knee push up'),ex('side plank')]} for d in ['2026-09-30','2026-10-02','2026-10-05']]}

class Repairs(unittest.TestCase):
 def test_mimo_authorization_header(self):
  captured=[]
  class Response:
   chunks=[json.dumps({'choices':[{'finish_reason':'stop','message':{'content':'{"ok":true}'}}]}).encode(),b'']
   def __enter__(self):return self
   def __exit__(self,*args):pass
   def read1(self,*args):return self.chunks.pop(0)
  class Opener:
   def open(self,request,**kwargs):captured.append(request.get_header('Authorization'));return Response()
  with patch.object(core.urllib.request,'build_opener',return_value=Opener()):
   output,_=core.call_provider(core.Provider('mimo','https://example.invalid','fixture','synthetic-key'),[],32)
  self.assertTrue(output['ok']);self.assertEqual(captured,['Bearer synthetic-key'])
 def test_plan_accepts_selected_dates_and_home_equipment(self):
  self.assertEqual(len(core.validate_result(request(),result())['sessions']),3)
 def test_plan_rejects_wrong_weekday(self):
  v=result();v['sessions'][0]['date']='2026-10-01'
  with self.assertRaises(core.AIError):core.validate_result(request(),v)
 def test_plan_rejects_unavailable_home_equipment(self):
  v=result();v['sessions'][0]['exercises'][0]['library_query']='barbell squat'
  with self.assertRaises(core.AIError):core.validate_result(request(),v)
 def test_plan_rejects_insufficient_exercises(self):
  v=result();v['sessions'][0]['exercises']=v['sessions'][0]['exercises'][:1]
  with self.assertRaises(core.AIError):core.validate_result(request(),v)
 def test_retry_enforces_maintenance_and_capacity(self):
  with tempfile.TemporaryDirectory() as tmp:
   store=server.JobStore(Path(tmp)/'jobs.db');store.create('failed-fixture',request())
   with store.connect() as db:db.execute("UPDATE jobs SET status='failed'")
   store.set_accepting(False)
   with self.assertRaises(core.AIError) as caught:store.retry('failed-fixture')
   self.assertEqual(caught.exception.code,'maintenance');store.set_accepting(True);store.update_settings({'pending_limit':30})
   for i in range(30):store.create('active-'+str(i),request())
   with self.assertRaises(core.AIError) as caught:store.retry('failed-fixture')
   self.assertEqual(caught.exception.code,'capacity')
   with store.connect() as db:self.assertEqual(db.execute("SELECT count(*) FROM jobs WHERE status='queued'").fetchone()[0],30)
 def test_cleanup_failure_does_not_kill_dispatcher(self):
  class Broken:
   claims=0
   def capacity_settings(self):return {'worker_limit':1}
   def cleanup(self):raise OSError('synthetic')
   def claim(self,interactive_only=False):self.claims+=1;return None
  store=Broken();worker=server.Workers(store,None);worker.thread.start();time.sleep(.7)
  self.assertTrue(worker.thread.is_alive());self.assertGreater(store.claims,0)
  worker.stop.set();worker.thread.join(2);worker.pool.shutdown()
 def test_photo_fallback_only_uses_configured_image_providers(self):
  """照片请求的收件方 = 已配置且支持图片的供应商；顺序与具体名单不作断言。

  历史用例（test_photo_fallback_respects_named_recipient）断言照片只发给具名
  供应商 mimo、拒绝 longcat。供应商已切换为 deepseek/minimax，同意文案同步为
  2026-10-26.deepseek-minimax-v1，PROVIDER_DEFAULTS 也只剩这两家，因此旧断言
  的前提（mimo/longcat 可作为收件方）已不存在。是否把照片/健康数据进一步收窄
  到其中一家仍未决（评估报告决策①）；本用例只锁定当前成立且必须保持的事实：
  回退路径会用尽所有已配置的图片供应商，且不会引入名单外的第三方。
  """
  req={'kind':'food','date':'2026-09-30','payload':{'image_base64':'fixture','mime':'image/jpeg','context':''}}
  calls=[]
  def transport(provider,*args):calls.append(provider.name);raise core.AIError('upstream_timeout','synthetic',True,True)
  configured={name for name in core.PROVIDER_DEFAULTS}
  providers=[core.Provider(n,'invalid','fixture','synthetic',supports_images=True) for n in sorted(configured)]
  with self.assertRaises(core.AIError):core.Router(providers,transport).run(req)
  self.assertEqual(sorted(calls),sorted(configured))
  self.assertTrue(set(calls)<=configured)
 def test_chinese_search_and_offset(self):
  with tempfile.TemporaryDirectory() as tmp:
   data=Path(tmp)/'exercises.json';data.write_text(json.dumps([{'id':json.loads((ROOT/'exercise-server/exercise-catalog-350-zh.json').read_text(encoding='utf-8'))[i]['id'],'name':'Dumbbell Bench Press','equipment':'dumbbell','body_part':'chest'} for i in range(45)]),encoding='utf-8')
   spec=importlib.util.spec_from_file_location('ex_fixture',ROOT/'exercise-server/api.py');module=importlib.util.module_from_spec(spec)
   with patch.dict(os.environ,{'EXERCISES_JSON':str(data)}):spec.loader.exec_module(module)
   handler=object.__new__(module.Handler);values={};handler.send_json=lambda status,value,cache=None:values.update(value)
   handler.path='/api/v1/exercises?q=%E5%93%91%E9%93%83&limit=40&offset=40';handler.do_GET()
   self.assertEqual(values['total'],45);self.assertEqual(len(values['items']),5)

if __name__=='__main__':unittest.main(verbosity=2)
