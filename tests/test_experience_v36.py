"""Cycle/readiness contract and real queue admission; no provider calls."""
import copy, datetime as dt, tempfile, unittest, uuid
from pathlib import Path
from test_backend_offline import weekly_request
from ai_core import AIError, validate_request, messages_for, analysis_facts, validate_coaching
from server import JobStore
from weekly_core import review_readiness

def modern(training=2, food=3, scope='combined', planned=3):
    raw=weekly_request(); p=raw['payload']
    p.update(review_version=1, timeZone='Asia/Shanghai', scope=scope,
             cycle={'start':'2026-09-21','plannedDates':[f'2026-09-{21+i}' for i in range(planned)]})
    for i,row in enumerate(p['days']):
        day=row['payload'];day['training_confirmed']=i<training
        if i>=training:day['exercises']=[]
        day['meals_complete']=i<food
        day['meals']=[{'name':'米饭鸡蛋蔬菜','calories':1600,'protein':85,'carbs':160,'fat':45,'nutrition_known':True}] if i<food else []
    return raw

class CycleAdmission(unittest.TestCase):
    def test_combined_uses_confirmed_days_not_record_count(self):
        p=validate_request(modern())['payload']
        self.assertEqual(p['readiness'],{'confirmedTrainingDays':2,'completeFoodDays':3,'requiredTrainingDays':2})
    def test_incomplete_food_can_choose_training_without_nutrition_judgment(self):
        raw=modern(food=0,scope='training');p=validate_request(raw)
        self.assertEqual(p['payload']['scope'],'training')
        self.assertIn('不判断全天摄入达标',messages_for(p)[0]['content'])
    def test_combined_rejects_less_than_three_complete_days(self):
        with self.assertRaises(AIError) as got:validate_request(modern(food=2))
        self.assertEqual(got.exception.code,'weekly_not_ready')
    def test_unknown_nutrition_does_not_unlock_full_review(self):
        raw=modern();raw['payload']['days'][0]['payload']['meals'][0]['nutrition_known']=False
        with self.assertRaises(AIError):validate_request(raw)
    def test_many_meals_on_one_day_are_still_one_day(self):
        raw=modern(food=1);raw['payload']['days'][0]['payload']['meals']*=12
        with self.assertRaises(AIError):validate_request(raw)
    def test_checked_but_unsaved_training_does_not_count(self):
        raw=modern();raw['payload']['days'][0]['payload']['training_confirmed']=False
        with self.assertRaises(AIError):validate_request(raw)
    def test_one_day_original_plan_can_be_reviewed(self):
        p=validate_request(modern(training=1,planned=1))['payload']
        self.assertEqual(p['readiness']['requiredTrainingDays'],1)
    def test_one_training_day_is_not_enough_for_three_day_plan(self):
        with self.assertRaises(AIError):validate_request(modern(training=1))
    def test_zero_reps_cannot_be_marked_confirmed(self):
        raw=modern()
        for s in raw['payload']['days'][0]['payload']['exercises'][0]['sets']:s['reps']=0
        with self.assertRaises(AIError):validate_request(raw)
    def test_timed_training_is_eligible(self):
        raw=modern()
        for row in raw['payload']['days'][:2]:
            row['payload']['exercises']=[{'name':'平板支撑','sets':[{'weight':0,'reps':0,'durationSeconds':30,'completed':True}]}]
        self.assertEqual(validate_request(raw)['payload']['readiness']['confirmedTrainingDays'],2)
    def test_cycle_is_not_calendar_week_and_rejects_mismatched_start(self):
        raw=modern();raw['payload']['cycle']['start']='2026-09-20'
        with self.assertRaises(AIError):validate_request(raw)
    def test_cycle_end_must_have_passed(self):
        value=validate_request(modern());p=value['payload']
        with self.assertRaises(AIError):review_readiness(p,p,dt.date(2026,9,27),today=dt.date(2026,9,27))
        self.assertEqual(review_readiness(p,p,dt.date(2026,9,27),today=dt.date(2026,9,28))['scope'],'combined')
    def test_modern_questionnaire_has_no_implicit_good_state(self):
        for key in ('fatigue','difficulty','pain','diet'):
            raw=modern();raw['payload']['survey'][key]=''
            with self.assertRaises(AIError):validate_request(raw)
    def test_missing_cycle_day_rejected(self):
        raw=modern();raw['payload']['days'].pop()
        with self.assertRaises(AIError):validate_request(raw)
    def test_flags_cannot_be_truthy_strings(self):
        raw=modern();raw['payload']['days'][0]['payload']['meals_complete']='true'
        with self.assertRaises(AIError):validate_request(raw)
    def test_legacy_empty_input_is_blocked_before_queue(self):
        raw=weekly_request()
        for row in raw['payload']['days']:row['payload']['exercises']=[]
        value=validate_request(raw)
        with tempfile.TemporaryDirectory() as folder:
            store=JobStore(Path(folder)/'jobs.sqlite3')
            with self.assertRaises(AIError) as got:store.create(str(uuid.uuid4()),value)
            self.assertEqual(got.exception.code,'weekly_not_ready')
            with store.connect() as db:self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
    def test_old_request_normalization_stays_idempotent(self):
        value=validate_request(weekly_request())
        self.assertNotIn('readiness',value['payload']);self.assertNotIn('scope',value['payload'])
        with tempfile.TemporaryDirectory() as folder:
            store=JobStore(Path(folder)/'jobs.sqlite3');identity=str(uuid.uuid4())
            first=store.create(identity,value);second=store.create(identity,value)
            self.assertEqual(first['id'],second['id'])
    def test_facts_separate_full_food_from_unknown_values(self):
        raw=modern(scope='training');raw['payload']['days'][0]['payload']['meals'][0]['nutrition_known']=False
        facts=analysis_facts(validate_request(raw))
        self.assertEqual(len(facts['明确确认饮食已记完的日期']),3)
        self.assertEqual(facts['完整饮食但有未知营养值的日期'],['2026-09-21'])
    def test_special_nutrition_context_survives_validation(self):
        raw=modern();raw['payload']['nutritionTarget']={'caloriesMin':1800,'caloriesMax':2000,'proteinMin':70,'proteinMax':100,'fatMin':40,'fatMax':60,'meals':3,'strategy':'需要个别评估','generalGuidanceOnly':True}
        request=validate_request(raw)
        self.assertEqual(request['payload']['nutritionTarget'],{'generalGuidanceOnly':True})
        self.assertIn('不引用其中数字',messages_for(request)[0]['content'])
        raw=modern();raw['payload']['nutritionTarget']={'generalGuidanceOnly':True}
        self.assertEqual(validate_request(raw)['payload']['nutritionTarget'],{'generalGuidanceOnly':True})
        raw=modern();raw['payload']['profile']['age']=17
        raw['payload']['nutritionTarget']={'caloriesMin':1800,'caloriesMax':2000,'proteinMin':70,'proteinMax':100,'fatMin':40,'fatMax':60,'meals':3,'generalGuidanceOnly':False}
        self.assertEqual(validate_request(raw)['payload']['nutritionTarget'],{'generalGuidanceOnly':True})
        row=modern()['payload']['days'][0]
        daily={'kind':'report','date':row['date'],'payload':row['payload']}
        daily['payload']['nutritionTarget']={'generalGuidanceOnly':True}
        self.assertEqual(validate_request(daily)['payload']['nutritionTarget'],{'generalGuidanceOnly':True})

class CoachingContract(unittest.TestCase):
    def report(self):
        paragraph=('已保存的组数和次数可以作为下次比较的起点。当前只能评价这些记录本身，不能据此判断实际肌肉变化或动作质量。'
                   '同名动作采用相同记录单位，比较时还需注意重量和动作是否一致。下一次按实际完成情况记录，计划中的未完成组不计入实际训练量。')
        return {key:paragraph*3 for key in ['summary','training','nutrition','recovery','reason']}
    def test_sparse_short_new_report_rejected_for_fallback(self):
        with self.assertRaises(ValueError):validate_coaching({'kind':'report','payload':{'coaching_version':1}},{k:'继续努力' for k in ['summary','training','nutrition','recovery']})
    def test_subjective_fatigue_not_converted_to_recovery_assurance(self):
        result=self.report();result['recovery']='恢复状态平稳，可以保证安全。'+result['recovery']
        with self.assertRaises(ValueError):validate_coaching({'kind':'report','payload':{'coaching_version':1}},result)
    def test_explicit_meal_confirmation_is_not_questioned_again(self):
        result=self.report();result['nutrition']='先确认是否漏记，再谈热量。'+result['nutrition']
        with self.assertRaises(ValueError):validate_coaching({'kind':'report','payload':{'coaching_version':1,'meals_complete':True}},result)
    def test_special_nutrition_context_rejects_numeric_prescriptions(self):
        result=self.report();result['nutrition']='建议每天摄入1800千卡。'+result['nutrition']
        with self.assertRaises(ValueError):validate_coaching({'kind':'report','payload':{'coaching_version':1,'nutritionTarget':{'generalGuidanceOnly':True}}},result)
        result=self.report();result['nutrition']='你登记的这餐约含1800千卡，属于记录数据，不是每日目标。'+result['nutrition']
        validate_coaching({'kind':'report','payload':{'coaching_version':1,'nutritionTarget':{'generalGuidanceOnly':True}}},result)
    def test_training_scope_does_not_require_food_records(self):
        result=self.report();result['reason']='需要补齐饮食记录才能继续训练。'+result['reason']
        with self.assertRaises(ValueError):validate_coaching({'kind':'weekly_review','payload':{'coaching_version':1,'scope':'training'}},result)
    def test_scoped_nutrition_section_is_short_and_explicit(self):
        result=self.report();validate_coaching({'kind':'weekly_review','payload':{'coaching_version':1,'scope':'training'}},result)
        self.assertEqual(result['nutrition'],'本次选择仅训练复盘，不评价饮食是否达标。')
    def test_historical_short_report_remains_readable(self):
        validate_coaching({'kind':'report','payload':{}},{'summary':'旧版短摘要'})

if __name__=='__main__':unittest.main()
