"""Regression cases from the Build 105 audit; synthetic records, no providers."""
import copy,datetime as dt,json,sys,tempfile,time,unittest,uuid
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from server import JobStore
from ai_core import validate_request,text,sequence,iso_date,AIError
import automation_core as auto,adaptive_core as adaptive
from test_adaptive_automation import body,STAMP,KEY
import test_adaptive_automation as fixtures
import test_coach as coach_fixture

class ReportArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=JobStore(Path(self.temp.name)/'jobs.sqlite3')
        self.owner='a'*64
    def tearDown(self):self.temp.cleanup()
    def report(self,kind='report',purpose=None):
        request=auto.prepare(body(),validate_request,now=STAMP)[0]['request'];request=validate_request(request)
        if kind=='coach':request=validate_request(coach_fixture.request())
        request['kind']=kind
        result={'kind':kind,'summary':'合成报告'}
        if purpose:result={'kind':'coach','coach':{'answer':'合成训练解读','purpose':purpose}}
        job=str(uuid.uuid4());self.store.create(job,request,quota_owner=self.owner)
        self.assertTrue(self.store.complete(job,result,'fixture','fixture'))
        return job,result
    def age(self,job):
        with self.store.connect() as db:
            db.execute('UPDATE jobs SET created=? WHERE id=?',(time.time()-45*86400,job))
            db.execute('UPDATE task_audits SET expires=? WHERE job_id=?',(time.time()-1,job))
        self.store.cleanup()
    def test_report_survives_task_and_audit_cleanup(self):
        job,result=self.report();self.age(job)
        self.assertEqual(self.store.get(job)['result'],result)
        self.assertEqual(self.store.get(job)['status'],'succeeded')
        with self.store.connect() as db:
            row=db.execute('SELECT status,payload,result FROM jobs WHERE id=?',(job,)).fetchone()
            self.assertEqual(tuple(row),('deleted','{}',None))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM task_audits WHERE job_id=?',(job,)).fetchone()[0],0)
    def test_expired_report_metadata_has_original_date(self):
        job,_=self.report();self.age(job);row=self.store.metadata([job])[0]
        self.assertEqual((row['date'],row['status']),(KEY,'succeeded'))
    def test_workout_and_weekly_results_remain_discoverable(self):
        for purpose in ['workout','weekly']:
            job,result=self.report('coach',purpose);self.age(job)
            self.assertEqual(self.store.get(job)['result'],result)
            self.assertEqual(self.store.metadata([job])[0]['purpose'],purpose)
    def test_plain_dialogue_has_no_permanent_report_archive(self):
        job,_=self.report('coach','dialogue');self.age(job)
        self.assertEqual(self.store.get(job)['status'],'deleted')
        self.assertIsNone(self.store.get(job)['result'])
    def test_explicit_delete_removes_retained_result(self):
        job,_=self.report();self.age(job);self.store.delete_private(job)
        self.assertEqual(self.store.get(job)['status'],'deleted')
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM report_archive').fetchone()[0],0)
    def test_account_erasure_removes_archives_after_task_owner_scrub(self):
        job,_=self.report();self.age(job);self.store.erase_owner(self.owner)
        self.assertIsNone(self.store.get(job)['result'])
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT COUNT(*) FROM report_archive').fetchone()[0],0)
    def test_archive_account_binding_cannot_change_after_cleanup(self):
        job,_=self.report();self.age(job)
        with self.assertRaises(AIError):self.store.bind_owners([{'id':job,'owner':'b'*64}])
    def test_legacy_success_is_backfilled_before_cleanup(self):
        job,result=self.report()
        with self.store.connect() as db:db.execute('DELETE FROM report_archive WHERE job_id=?',(job,))
        self.age(job);self.assertEqual(self.store.get(job)['result'],result)
    def test_deleted_report_cannot_be_backfilled_again(self):
        job,_=self.report();self.store.delete_private(job);self.store.cleanup()
        again=JobStore(self.store.path)
        self.assertIsNone(again.get(job)['result'])
    def test_archive_stores_result_without_request_photo_or_profile(self):
        job,_=self.report()
        with self.store.connect() as db:
            names={r['name'] for r in db.execute('PRAGMA table_info(report_archive)')}
            self.assertNotIn('payload',names);self.assertNotIn('profile',names)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM report_archive WHERE job_id=?',(job,)).fetchone()[0],1)

class ProposalBaselineTests(unittest.TestCase):
    def request(self):return fixtures.AdaptiveTests().supported()
    # progression.policy.v1：20kg 上限 = min(2.5kg, 5%) = 1.0kg → 21.0。
    # 用上限内的值，下面 5 个"证据不足"用例才测得到证据校验本身，
    # 不会被加重上限先行拒绝（统一前用 22.5，是旧的 max(2.5,5%) 口径）。
    def clean(self,r):return adaptive.clean_proposal(r,{'changes':[fixtures.AdaptiveTests().change(field='weight',value=21.0)]},(text,sequence,iso_date))
    def test_actual_below_original_targets_cannot_support_load_increase(self):
        r=self.request()
        for day in r['payload']['days']:day['payload']['workout_sessions'][0]['executionBaseline']['sets'][0]['targetReps']=12
        with self.assertRaises(ValueError):self.clean(r)
    def test_no_original_baseline_cannot_support_load_increase(self):
        r=self.request()
        for day in r['payload']['days']:day['payload']['workout_sessions'][0].pop('executionBaseline')
        with self.assertRaises(ValueError):self.clean(r)
    def test_changed_original_weight_cannot_support_increase(self):
        r=self.request()
        for day in r['payload']['days']:day['payload']['workout_sessions'][0]['executionBaseline']['sets'][0]['targetWeight']=15
        with self.assertRaises(ValueError):self.clean(r)
    def test_changed_group_id_cannot_manufacture_original_completion(self):
        r=self.request();r['payload']['days'][0]['payload']['exercises'][0]['sets'][0]['id']=str(uuid.uuid4())
        with self.assertRaises(ValueError):self.clean(r)
    def test_future_harder_reps_must_also_be_observed(self):
        r=self.request();r['payload']['upcoming'][0]['exercises'][0]['sets'][0]['reps']=15
        with self.assertRaises(ValueError):self.clean(r)
    def test_original_targets_met_on_two_dates_support_conservative_increase(self):
        self.assertEqual(self.clean(self.request())['changes'][0]['value'],21.0)

class GoalContextTests(unittest.TestCase):
    def goal(self,when,identifier=None):return {'version':1,'id':identifier or str(uuid.uuid4()),'recordedAt':when-auto.APPLE_EPOCH,'profile':{'age':30,'height':175,'weight':70,'goal':'增肌'}}
    def row(self,state):return auto.report_day(state,KEY,{},'UTC')['goal_context']['days'][0]
    def test_goal_before_window_is_used_as_explicit_baseline(self):
        state=body()['state'];state['automationGoalBaseline']=[self.goal(STAMP-45*86400)]
        self.assertEqual(self.row(state)['profile']['goal'],'增肌')
        self.assertFalse(self.row(state)['goalChangedDuringDay'])
    def test_first_goal_is_not_a_goal_change(self):
        state=body()['state'];state['days'][KEY]['goalVersions']=[self.goal(STAMP-3600)]
        self.assertFalse(self.row(state)['goalChangedDuringDay'])
    def test_prior_goal_then_single_new_goal_is_a_change(self):
        state=body()['state'];state['automationGoalBaseline']=[self.goal(STAMP-45*86400)]
        state['days'][KEY]['goalVersions']=[self.goal(STAMP-3600)]
        self.assertTrue(self.row(state)['goalChangedDuringDay'])
    def test_two_same_day_goals_are_a_change(self):
        state=body()['state'];state['days'][KEY]['goalVersions']=[self.goal(STAMP-3600),self.goal(STAMP-1800)]
        self.assertTrue(self.row(state)['goalChangedDuringDay'])
    def test_duplicated_goal_baseline_cannot_fake_two_changes(self):
        state=body()['state'];g=self.goal(STAMP-3600);state['automationGoalBaseline']=[g];state['days'][KEY]['goalVersions']=[g]
        self.assertFalse(self.row(state)['goalChangedDuringDay'])
    def test_future_goal_is_never_backfilled(self):
        state=body()['state'];state['automationGoalBaseline']=[self.goal(STAMP+86400)]
        self.assertIsNone(self.row(state)['profile'])

if __name__=='__main__':unittest.main()
