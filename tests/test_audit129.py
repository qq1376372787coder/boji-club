"""Focused regressions for the independently verified Build124/128 defects."""
import copy, unittest
from ai_core import validate_request, AIError
from fitness_intelligence import safety_triage
import test_build123_review
from test_coach import request

class Audit129Tests(unittest.TestCase):
    def test_explicit_absence_is_not_emergency(self):
        for q in ['今天没胸痛，只是普通训练酸痛，怎么判断要不要休息？','胸口不痛','没有出现胸痛',
                  '今天没胸闷','以前胸痛，今天没有','没有胸痛','今天没有胸痛','没感到胸痛',
                  '未出现胸痛','否认胸痛','胸痛已经没有了','no chest pain','without chest pain',
                  'denies chest pain','I do not have chest pain','no chest pain and no fainting']:
            with self.subTest(q=q):self.assertEqual(safety_triage(q)['level'],'none')
    def test_positive_and_uncertain_danger_remains_emergency(self):
        for q in ['不是没有胸痛','不是不胸痛','并非没有胸痛','不能说没有胸痛','今天胸痛并且晕倒',
                  '没有胸痛，但喘不过气','没有休息好，胸口痛','没有休息好胸口痛','喘不过气',
                  '不能呼吸',"can't breathe",'胸痛没有缓解','以前胸痛，今天又痛','no chest pain but fainted',
                  'chest pain and no fever','not without chest pain']:
            with self.subTest(q=q):self.assertEqual(safety_triage(q)['level'],'emergency')
    def source(self):return test_build123_review.Build123Tests().source()
    def test_unstarted_plan_alongside_confirmed_session(self):
        raw=self.source();planned={'name':'深蹲','sets':[{'weight':30,'reps':10,'completed':False}]}
        raw['payload']['exercises'].append(planned)
        clean=validate_request(raw,allow_empty_report=True)['payload']
        self.assertTrue(clean['exercises'][-1]['planned_only'])
        self.assertEqual(sum(s['completed'] for ex in clean['exercises'] for s in ex['sets']),1)
        self.assertTrue(clean['workout_sessions'][0]['confirmed'])
    def test_active_session_can_coexist_with_unbound_plan(self):
        raw=self.source();raw['payload']['training_confirmed']=False;raw['payload']['workout_sessions'][0]['savedAt']=None
        raw['payload']['exercises'][0].pop('session_id');raw['payload']['exercises'][0]['sets'][0]['completed']=False
        self.assertTrue(validate_request(raw,allow_empty_report=True)['payload']['exercises'][0]['planned_only'])
    def test_actual_and_explicit_unknown_session_are_not_silently_plans(self):
        for change in ['completed','actualEntered','unknown_session']:
            raw=self.source();ex=raw['payload']['exercises'][0];ex.pop('session_id')
            raw['payload']['workout_sessions'][0]['savedAt']=None
            if change=='actualEntered':ex['sets'][0].update(completed=False,actualEntered=True)
            if change=='unknown_session':ex['session_id']='99999999-9999-4999-8999-999999999999';ex['sets'][0]['completed']=False
            with self.subTest(change=change),self.assertRaises(AIError):validate_request(raw,allow_empty_report=True)
    def test_coach_normalizes_mixed_record_context(self):
        raw=request();raw['payload']['days'][0]['payload']=self.source()['payload']
        raw['payload']['days'][0]['payload']['exercises'].append({'name':'深蹲','sets':[{'weight':20,'reps':10,'completed':False}]})
        clean=validate_request(raw)
        self.assertTrue(clean['payload']['days'][0]['payload']['exercises'][-1]['planned_only'])

if __name__=='__main__':unittest.main()
