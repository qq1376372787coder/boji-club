import unittest,sys,copy,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
import ai_core,training_feedback as feedback
SESSION='00000000-0000-4000-8000-000000000001'
EXERCISE='00000000-0000-4000-8000-000000000002'
def sid(i):return f'00000000-0000-4000-8000-{i+100:012d}'
def request(total=6,done=6,timed=None,confirmed=True):
    sets=[{'id':sid(i),'weight':0 if timed else 20,'reps':0 if timed else 10,'durationSeconds':timed,'completed':i<done} for i in range(total)]
    targets=[{'id':sid(i),'exerciseID':EXERCISE,'unit':'time' if timed else 'reps','targetSeconds':timed} for i in range(total)]
    session={'id':SESSION,'startedAt':800000000,'endedAt':800003000,'executionBaseline':{'version':1,'capturedAt':800000000,'sets':targets}}
    if confirmed:session['savedAt']=800003001
    return {'kind':'report','date':'2026-10-13','payload':{'exercises':[{'name':'平板支撑' if timed else '卧推','exercise_id':EXERCISE,'session_id':SESSION,'sets':sets}],'meals':[],'workout_sessions':[session],'training_confirmed':confirmed,'training_feedback_version':1}}
def evaluate(raw):return feedback.evaluate(ai_core.validate_request(raw)['payload'])
class TrainingFeedbackTests(unittest.TestCase):
 def test_full_execution_green(self):self.assertEqual(evaluate(request())['status'],'green')
 def test_partial_execution_yellow(self):self.assertEqual(evaluate(request(done=4))['status'],'yellow')
 def test_major_gap_red_only_after_confirmation(self):self.assertEqual(evaluate(request(done=2))['status'],'red')
 def test_small_plan_not_automatically_red(self):self.assertEqual(evaluate(request(total=3,done=1))['status'],'yellow')
 def test_unconfirmed_gray_despite_full_boxes(self):self.assertEqual(evaluate(request(confirmed=False))['reason'],'unconfirmed')
 def test_absent_baseline_gray(self):
  raw=request();raw['payload']['workout_sessions'][0].pop('executionBaseline');self.assertEqual(evaluate(raw)['reason'],'missing_baseline')
 def test_deleting_unfinished_sets_cannot_create_green(self):
  raw=request(done=4);raw['payload']['exercises'][0]['sets']=raw['payload']['exercises'][0]['sets'][:4]
  value=evaluate(raw);self.assertEqual(value['status'],'gray');self.assertEqual(value['reason'],'adjusted_plan')
 def test_replacement_gray_instead_of_punishment(self):
  raw=request();raw['payload']['exercises'][0]['sets'][3]['id']=sid(1000)
  self.assertEqual(evaluate(raw)['reason'],'adjusted_plan')
 def test_added_completed_sets_do_not_replace_original_targets(self):
  raw=request(done=2);raw['payload']['exercises'][0]['sets']+= [{'id':sid(1000),'weight':20,'reps':10,'completed':True}]
  value=evaluate(raw);self.assertEqual(value['status'],'red');self.assertTrue(any('新增组' in e for e in value['evidence']))
 def test_zero_external_weight_not_penalized(self):
  raw=request()
  for s in raw['payload']['exercises'][0]['sets']:s['weight']=0
  self.assertEqual(evaluate(raw)['status'],'green')
 def test_higher_weight_cannot_improve_color(self):
  raw=request(done=2)
  for s in raw['payload']['exercises'][0]['sets']:s['weight']=200
  self.assertEqual(evaluate(raw)['status'],'red')
 def test_fewer_reps_does_not_claim_bad_intensity(self):
  raw=request()
  for s in raw['payload']['exercises'][0]['sets']:s['reps']=8
  self.assertEqual(evaluate(raw)['status'],'green')
 def test_meal_completion_never_changes_training_feedback(self):
  raw=request();original=evaluate(raw)
  raw['payload']['meals']=[{'name':'早餐','calories':300,'protein':20,'carbs':20,'fat':15}];raw['payload']['meals_complete']=True
  self.assertEqual(evaluate(raw),original)
 def test_timed_actual_must_match_original_target(self):
  raw=request(total=1,done=1,timed=600);raw['payload']['exercises'][0]['sets'][0]['durationSeconds']=60
  self.assertEqual(evaluate(raw)['status'],'red')
 def test_mixed_workout_not_red_solely_for_skipped_cardio(self):
  raw=request(total=7,done=6);raw['payload']['exercises'][0]['sets'][-1].update(reps=0,durationSeconds=600)
  raw['payload']['workout_sessions'][0]['executionBaseline']['sets'][-1].update(unit='time',targetSeconds=600)
  self.assertEqual(evaluate(raw)['status'],'yellow')
 def test_timer_tolerance_is_explicit_and_stable(self):
  raw=request(total=1,done=1,timed=600);raw['payload']['exercises'][0]['sets'][0]['durationSeconds']=540
  self.assertEqual(evaluate(raw)['status'],'green')
  raw['payload']['exercises'][0]['sets'][0]['durationSeconds']=539;self.assertEqual(evaluate(raw)['status'],'yellow')
 def test_unit_change_is_adjustment(self):
  raw=request();raw['payload']['exercises'][0]['sets'][0].update(reps=0,durationSeconds=30)
  self.assertEqual(evaluate(raw)['reason'],'adjusted_plan')
 def test_duplicate_target_rejected(self):
  raw=request();raw['payload']['workout_sessions'][0]['executionBaseline']['sets'][1]['id']=sid(0)
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(raw)
 def test_duplicate_actual_set_rejected(self):
  raw=request();raw['payload']['exercises'][0]['sets'][1]['id']=sid(0)
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(raw)
 def test_invalid_baseline_unit_rejected(self):
  raw=request();raw['payload']['workout_sessions'][0]['executionBaseline']['sets'][0]['unit']='kg'
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(raw)
 def test_missing_timer_target_rejected(self):
  raw=request(timed=30);raw['payload']['workout_sessions'][0]['executionBaseline']['sets'][0]['targetSeconds']=None
  with self.assertRaises(ai_core.AIError):ai_core.validate_request(raw)
 def test_rest_day_neutral(self):
  raw={'kind':'report','date':'2026-10-13','payload':{'body_weight_kg':70,'planned_training_day':False}}
  value=evaluate(raw);self.assertEqual((value['status'],value['reason']),('gray','rest_day'))
 def test_planned_but_unrecorded_not_red(self):
  raw={'kind':'report','date':'2026-10-13','payload':{'body_weight_kg':70,'planned_training_day':True}}
  self.assertEqual(evaluate(raw)['status'],'gray')
 def test_multiple_sessions_evaluate_separately(self):
  raw=request();extra=request(done=4);extra['payload']['workout_sessions'][0]['id']=sid(3000)
  extra['payload']['exercises'][0]['session_id']=sid(3000)
  extra['payload']['exercises'][0]['exercise_id']=sid(3500)
  for i,s in enumerate(extra['payload']['exercises'][0]['sets']):s['id']=sid(i+3000)
  for i,s in enumerate(extra['payload']['workout_sessions'][0]['executionBaseline']['sets']):s['id']=sid(i+3000);s['exerciseID']=sid(3500)
  raw['payload']['exercises']+=extra['payload']['exercises'];raw['payload']['workout_sessions']+=extra['payload']['workout_sessions']
  value=evaluate(raw);self.assertEqual(value['status'],'yellow');self.assertEqual(len(value['evidence']),2)
 def test_invalid_date_health_not_needed_for_grade(self):
  raw=request();self.assertIsNone(ai_core.validate_request(raw)['payload']['health']);self.assertEqual(evaluate(raw)['status'],'green')
 def test_unstarted_second_plan_does_not_change_first_feedback(self):
  raw=request();second=sid(5000)
  raw['payload']['workout_sessions'].append({'id':second})
  raw['payload']['exercises'].append({'name':'未开始安排','exercise_id':sid(5001),'session_id':second,'sets':[{'id':sid(5002),'weight':0,'reps':10,'completed':False}]})
  self.assertEqual(evaluate(raw)['status'],'green')
 def test_actual_set_moved_to_other_exercise_not_green(self):
  raw=request();raw['payload']['exercises'][0]['exercise_id']=sid(5000)
  self.assertEqual(evaluate(raw)['status'],'gray')
 def test_mixed_confirmed_and_unconfirmed_not_day_green(self):
  payload=ai_core.validate_request(request())['payload'];second=copy.deepcopy(payload['workout_sessions'][0]);second['id']=sid(5000);second['confirmed']=False
  exercise=copy.deepcopy(payload['exercises'][0]);exercise['session_id']=second['id']
  payload['workout_sessions'].append(second);payload['exercises'].append(exercise)
  self.assertEqual(feedback.evaluate(payload)['reason'],'partial_context')
 def test_many_sessions_show_problem_evidence_before_truncation(self):
  payload=ai_core.validate_request(request())['payload'];exercise=copy.deepcopy(payload['exercises'][0]);session=copy.deepcopy(payload['workout_sessions'][0])
  payload['exercises']=[];payload['workout_sessions']=[]
  for i in range(10):
   e=copy.deepcopy(exercise);s=copy.deepcopy(session);s['id']=sid(6000+i);e['session_id']=s['id']
   if i==9:
    for item in e['sets'][2:]:item['completed']=False
   payload['exercises'].append(e);payload['workout_sessions'].append(s)
  value=feedback.evaluate(payload);self.assertEqual(value['status'],'red');self.assertIn('优先调整',value['evidence'][0]);self.assertEqual(len(value['evidence']),8)
 def test_model_cannot_override_status(self):
  clean=ai_core.validate_request(request(done=2))
  model={'kind':'report','summary':'已记录内容。','training':'本次训练已有记录。','nutrition':'没有饮食记录。','recovery':'没有恢复数据。','notes':[],'training_feedback':{'status':'green','score':100}}
  output=ai_core.validate_result(clean,model)
  self.assertEqual(output['training_feedback']['status'],'red');self.assertNotIn('score',output['training_feedback'])
 def test_same_facts_same_color_despite_different_wording(self):
  req=ai_core.validate_request(request(done=4));raw={'kind':'report','summary':'小结','training':'已登记。','nutrition':'暂无饮食记录。','recovery':'暂无恢复数据。','notes':[]}
  first=ai_core.validate_result(req,raw)['training_feedback'];raw['training']='这次有四组完成登记。'
  self.assertEqual(first,ai_core.validate_result(req,raw)['training_feedback'])
 def test_model_payload_preserves_measurements_without_target_ids(self):
  raw=ai_core.validate_request(request())['payload'];model=feedback.model_payload(raw)
  self.assertEqual(model['exercises'][0]['sets'][0]['weight'],20)
  self.assertEqual(model['exercises'][0]['session_id'],model['workout_sessions'][0]['id'])
  self.assertNotIn('executionBaseline',model['workout_sessions'][0]);self.assertNotIn('id',model['exercises'][0]['sets'][0])
  self.assertIn('executionBaseline',raw['workout_sessions'][0])
 def test_feedback_prompt_uses_fixed_conclusion(self):
  value=json.loads(ai_core.messages_for(ai_core.validate_request(request(done=2)))[1]['content'])
  self.assertEqual(value['固定训练反馈']['固定结论'],'优先调整')
 def test_palette_contrast(self):
  def luminance(hex):
   values=[int(hex[i:i+2],16)/255 for i in [0,2,4]]
   a=[v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4 for v in values]
   return .2126*a[0]+.7152*a[1]+.0722*a[2]
  for bg,ink in [('EAF3EC','376247'),('FAF1D8','705519'),('F8E9E7','8C3F38'),('EFF0F1','4F565E')]:
   self.assertGreaterEqual((luminance(bg)+.05)/(luminance(ink)+.05),4.5)

if __name__=='__main__':unittest.main()
