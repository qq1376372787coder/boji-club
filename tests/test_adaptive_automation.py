import copy, datetime as dt, sys, unittest, uuid
import tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import adaptive_core as adaptive
import automation_core as auto
from ai_core import validate_request, text, sequence, iso_date, AIError

SID='11111111-1111-1111-1111-111111111111'
EX='22222222-2222-2222-2222-222222222222'
SET='33333333-3333-3333-3333-333333333333'
STAMP=dt.datetime(2020,1,15,12,tzinfo=dt.timezone.utc).timestamp()
KEY='2020-01-15'
def state():
    return {'days':{KEY:{'exercises':[{'id':EX,'name':'卧推','muscle':'胸','workoutSessionID':SID,'sets':[{'id':SET,'weight':20,'reps':10,'completed':True}]}],
        'workoutSessions':[{'id':SID,'startedAt':STAMP-auto.APPLE_EPOCH-120,'endedAt':STAMP-auto.APPLE_EPOCH-60,'savedAt':STAMP-auto.APPLE_EPOCH-30}],
        'meals':[{'name':'鸡蛋','calories':150,'protein':12,'carbs':1,'fat':10}]}},'aiJobs':[]}
def body():
    return {'owner':13,'settings':{'version':1,'enabled':True,'daily':True,'weekly':False,'workout':False,'partial':True,'hour':0,'zone':'UTC','enabled_at':STAMP-3600},'state':state(),'coverage':{KEY:True},'coverage_current':True,'known_ids':[]}
def upcoming():
    return [{'date':'2020-01-16','label':'训练','exercises':[{'name':'卧推','muscle':'胸','library_id':'bench','sets':[{'weight':20,'reps':10}],'rest_seconds':60}]}]
class AdaptiveTests(unittest.TestCase):
    def request(self):return {'payload':{'upcoming':upcoming(),'proposal_allowed':True}}
    def change(self,**kw):
        d={'date':'2020-01-16','exercise':0,'set':0,'field':'reps','value':11,'reason':'根据已登记的训练，保守调整目标。'};d.update(kw);return d
    def clean(self,changes):return adaptive.clean_proposal(self.request(),{'changes':changes},(text,sequence,iso_date))
    def test_exact_baseline_retained(self):
        value=self.clean([self.change()]);self.assertEqual(value['baseline'],upcoming());self.assertEqual(value['version'],1)
    def test_foreign_coordinates_and_fields_rejected(self):
        for kwargs in [{'date':'2020-01-17'},{'exercise':1},{'set':1},{'exercise':True},{'field':'delete'},{'value':True}]:
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):self.clean([self.change(**kwargs)])
    def test_load_increase_and_large_rep_jump_rejected(self):
        for kwargs in [{'field':'weight','value':21},{'value':14},{'value':1.5},{'value':float('nan')}]:
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):self.clean([self.change(**kwargs)])
    def test_load_reduction_and_rest_are_valid(self):
        self.clean([self.change(field='weight',value=18)])
        change=self.change(field='rest_seconds',value=90);change.pop('set');self.clean([change])
    def test_unchanged_duplicate_and_unit_mutation_rejected(self):
        for changes in [[self.change(value=10)],[self.change(),self.change()],[self.change(field='durationSeconds',value=20)]]:
            with self.assertRaises(ValueError):self.clean(changes)
    def test_disabled_or_missing_context_never_proposes(self):
        request=self.request();request['payload']['proposal_allowed']=False
        with self.assertRaises(ValueError):adaptive.clean_proposal(request,{'changes':[self.change()]},(text,sequence,iso_date))
    def test_empty_upcoming_normalizes_without_permission(self):
        raw={'kind':'coach','date':KEY,'payload':{'version':1,'conversation_id':SID,'question':'接下来该关注什么？','days':[]}}
        clean=validate_request(raw);self.assertFalse(clean['payload']['proposal_allowed'])
    def test_mixed_units_and_past_schedule_rejected(self):
        from ai_core import number
        for rows in [upcoming(),upcoming()]:
            if rows is not None:
                rows[0]['date']=KEY
                with self.assertRaises(ValueError):adaptive.clean_upcoming(rows,KEY,(text,number,sequence,iso_date))
        rows=upcoming();rows[0]['exercises'][0]['sets'].append({'weight':0,'reps':0,'durationSeconds':30})
        with self.assertRaises(ValueError):adaptive.clean_upcoming(rows,KEY,(text,number,sequence,iso_date))
    def supported(self):
        request=self.request();days=[]
        for date in ['2020-01-14','2020-01-15']:
            sid=str(uuid.uuid5(uuid.NAMESPACE_URL,date))
            days.append({'date':date,'payload':{'exercises':[{'library_id':'bench','session_id':sid,'sets':[{'weight':20,'reps':10,'completed':True}]}],'workout_sessions':[{'id':sid,'confirmed':True}]}})
        for day in days:
            ex=day['payload']['exercises'][0];ex['exercise_id']=EX;ex['sets'][0]['id']=SET
            day['payload']['workout_sessions'][0]['executionBaseline']={'version':1,'capturedAt':STAMP-auto.APPLE_EPOCH-600,'sets':[{'id':SET,'exerciseID':EX,'unit':'reps','targetReps':10,'targetWeight':20}]}
        request['payload']['days']=days;return request
    def test_small_increase_requires_two_confirmed_comparable_days(self):
        request=self.supported()
        value=adaptive.clean_proposal(request,{'changes':[self.change(field='weight',value=22.5)]},(text,sequence,iso_date))
        self.assertEqual(value['changes'][0]['value'],22.5)
        request['payload']['days']=request['payload']['days'][:1]
        with self.assertRaises(ValueError):adaptive.clean_proposal(request,{'changes':[self.change(field='weight',value=22.5)]},(text,sequence,iso_date))
    def test_duplicate_day_or_changed_load_is_not_progression_evidence(self):
        for mutation in ['date','weight','confirmed','duplicate']:
            request=self.supported();day=request['payload']['days'][0]
            if mutation=='date':day['date']='2020-01-15'
            if mutation=='weight':day['payload']['exercises'][0]['sets'][0]['weight']=15
            if mutation=='confirmed':day['payload']['workout_sessions'][0]['confirmed']=False
            if mutation=='duplicate':day['payload']['exercises']*=2
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):adaptive.clean_proposal(request,{'changes':[self.change(field='weight',value=22.5)]},(text,sequence,iso_date))
    def test_excessive_increase_still_rejected_with_evidence(self):
        with self.assertRaises(ValueError):adaptive.clean_proposal(self.supported(),{'changes':[self.change(field='weight',value=25)]},(text,sequence,iso_date))
    def test_custom_movement_identity_is_canonical(self):
        from ai_core import number
        rows=upcoming();rows[0]['exercises'][0].update(custom_id='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',custom_unit='次');rows[0]['exercises'][0].pop('library_id')
        clean=adaptive.clean_upcoming(rows,KEY,(text,number,sequence,iso_date))
        self.assertEqual(clean[0]['exercises'][0]['custom_id'],'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
class AutomationTests(unittest.TestCase):
    def prepare(self,b=None,now=STAMP):return auto.prepare(b or body(),validate_request,now)
    def test_partial_daily_uses_real_records(self):
        jobs=self.prepare();self.assertEqual(len(jobs),1);self.assertEqual(jobs[0]['request']['kind'],'report')
        self.assertEqual(jobs[0]['client_id'],'a170da11-2020-0115-0000-00000000000d')
    def test_disabled_is_no_work(self):
        b=body();b['settings']['enabled']=False;self.assertEqual(self.prepare(b),[])
    def test_no_default_daily_quota_added(self):
        self.assertNotEqual(auto.identity(13,'weekly',KEY),auto.identity(14,'weekly',KEY))
        self.assertEqual(auto.identity(13,'workout',SID),auto.identity(13,'workout',SID))
    def test_before_optin_or_before_due_no_task(self):
        b=body();b['settings']['enabled_at']=STAMP+10;self.assertEqual(self.prepare(b),[])
        b=body();b['settings']['hour']=23;self.assertEqual(self.prepare(b),[])
    def test_known_job_is_not_duplicated(self):
        b=body();b['known_ids']=[auto.identity(13,'daily',KEY)];self.assertEqual(self.prepare(b),[])
    def test_empty_php_objects_are_not_nonempty_lists(self):
        b=body();b['coverage']=[];self.assertEqual(len(self.prepare(b)),1)
        b['state']={'days':[]};self.assertEqual(self.prepare(b),[])
        b['state']=[];self.assertEqual(self.prepare(b),[])
        b['state']={'days':[{'date':KEY}]}
        with self.assertRaises(ValueError):self.prepare(b)
    def test_nullable_legacy_fields_do_not_crash_scheduling(self):
        b=body();b['state']['days'][KEY].update(bodyWeight=None,goalVersions=None,workoutSessions=None,exercises=[])
        self.assertEqual(len(self.prepare(b)),1)
    def test_manual_pending_report_blocks_an_automatic_duplicate(self):
        b=body();b['existing_reports']=[KEY];self.assertEqual(self.prepare(b),[])
    def test_one_unusable_context_does_not_discard_another_valid_task(self):
        b=body();b['settings']['workout']=True;deferred=[]
        def normalize(raw):
            if raw['kind']=='coach':raise AIError('invalid_request','记录范围暂不可用')
            return validate_request(raw)
        jobs=auto.prepare(b,normalize,STAMP,on_skip=deferred.append)
        self.assertEqual(len(jobs),1);self.assertEqual(jobs[0]['request']['kind'],'report')
        self.assertEqual(deferred,[{'mode':'workout','date':KEY,'status':'context_unavailable'}])
    def test_unconfirmed_training_is_not_reviewed(self):
        b=body();b['state']['days'][KEY]['workoutSessions'][0].pop('savedAt');self.assertEqual(self.prepare(b),[])
    def test_empty_but_started_session_still_blocks_daily(self):
        b=body();b['state']['days'][KEY]['exercises']=[];b['state']['days'][KEY]['workoutSessions'][0].pop('savedAt')
        self.assertEqual(self.prepare(b),[])
        b['state']['days'][KEY].update(workoutStartedAt=STAMP-auto.APPLE_EPOCH,workoutSessions=None)
        self.assertEqual(self.prepare(b),[])
    def test_default_requires_verified_meal_coverage(self):
        b=body();b['settings']['partial']=False;b['coverage_current']=False;self.assertEqual(self.prepare(b),[])
        b['coverage_current']=True;self.assertEqual(len(self.prepare(b)),1)
    def test_no_records_or_only_plan_is_no_work(self):
        b=body();b['state']['days'][KEY]['meals']=[]
        for ex in b['state']['days'][KEY]['exercises']:
            for s in ex['sets']:s['completed']=False
        self.assertEqual(self.prepare(b),[])
    def test_health_only_shared_data_is_eligible_for_partial_daily(self):
        # AUD-003/FIX-003：只确认分享健康体重时，和手动体重一样应触发日报。
        b=body();day=b['state']['days'][KEY]
        day['meals']=[];day['exercises']=[];day['workoutSessions']=[]
        source={'id':'com.apple.health','name':'Apple 健康'}
        day['health']={'date':KEY,'timeZone':'UTC','updatedAt':STAMP-auto.APPLE_EPOCH,
            'bodyMass':{'value':55,'source':source,'recordedAt':STAMP-auto.APPLE_EPOCH-60},
            'workouts':[]}
        jobs=self.prepare(b)
        self.assertEqual(len(jobs),1)
        self.assertEqual(jobs[0]['request']['kind'],'report')
        self.assertIsNotNone(jobs[0]['request']['payload'].get('health'))
        # An empty shared summary is still no data; it must not invent a report.
        empty=body();empty_day=empty['state']['days'][KEY]
        empty_day['meals']=[];empty_day['exercises']=[];empty_day['workoutSessions']=[]
        empty_day['health']={'date':KEY,'timeZone':'UTC','updatedAt':STAMP-auto.APPLE_EPOCH,'workouts':[]}
        self.assertEqual(self.prepare(empty),[])
    def test_workout_only_exact_saved_session_and_no_before_optin(self):
        b=body();b['settings'].update(daily=False,workout=True)
        jobs=self.prepare(b);self.assertEqual(jobs[0]['request']['payload']['source_session'],SID)
        self.assertEqual(jobs[0]['request']['payload']['purpose'],'workout')
        b['settings']['enabled_at']=STAMP-10;self.assertEqual(self.prepare(b),[])
    def test_identity_and_unknown_profile_are_not_forwarded(self):
        b=body();b['state'].update(profile={'nickname':'private-user'},phone='private-phone')
        p=self.prepare(b)[0]['request']['payload'];self.assertNotIn('private',str(p));self.assertIsNone(p['goal_context']['days'][0]['profile'])
    def test_single_meal_unknown_nutrition_does_not_break_revalidation(self):
        b=body();b['state']['days'][KEY]['meals'][0]['nutritionKnown']=False
        task=self.prepare(b)[0];validate_request(task['request'])
    def test_timezone_and_flags_are_validated(self):
        for change in [{'hour':25},{'zone':'not/a-zone'},{'partial':1}]:
            b=body();b['settings'].update(change)
            with self.assertRaises((ValueError,KeyError)):self.prepare(b)
    def test_weekly_is_not_fabricated_for_sparse_data(self):
        b=body();b['settings'].update(daily=False,weekly=True,enabled_at=STAMP-15*86400)
        self.assertEqual(self.prepare(b,STAMP+5*86400),[])
    def test_weekly_requires_observed_full_week_after_optin(self):
        b=body();b['settings'].update(daily=False,weekly=True,enabled_at=STAMP-15*86400)
        for i in [4,3]:
            date=dt.date.fromisoformat(KEY)-dt.timedelta(days=i);day=copy.deepcopy(b['state']['days'][KEY])
            day['workoutSessions'][0]['id']=str(uuid.uuid4());day['exercises'][0]['workoutSessionID']=day['workoutSessions'][0]['id']
            b['state']['days'][date.isoformat()]=day
        jobs=self.prepare(b);self.assertEqual(len(jobs),1);self.assertEqual(jobs[0]['request']['payload']['purpose'],'weekly')
        b['settings']['enabled_at']=STAMP-86400;self.assertEqual(self.prepare(b),[])
    def test_recovered_metadata_identifies_pending_automatic_coach(self):
        from server import JobStore
        b=body();b['settings'].update(daily=False,workout=True)
        raw=self.prepare(b)[0];request=validate_request(raw['request'])
        with tempfile.TemporaryDirectory() as directory:
            store=JobStore(Path(directory)/'jobs.sqlite3');store.create(raw['client_id'],request)
            metadata=store.metadata([raw['client_id']])[0]
            self.assertEqual(metadata['purpose'],'workout');self.assertNotIn('payload',metadata)
if __name__=='__main__':unittest.main()
