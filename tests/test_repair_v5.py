"""Fifth-round regressions: offline, synthetic requests, no model calls."""
import copy, gc, json, sys, tempfile, time, tracemalloc, unittest, uuid
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'backend'))
from ai_core import AIError, validate_request, validate_result, requires_duration
from server import JobStore
from weekly_core import sanitize_composition_text
from food_core import clean_food
from ai_core import text, number, sequence
from test_backend_offline import weekly_request, weekly_result
from test_backend_v2 import request as plan_request, result as plan_result

class RepairV5(unittest.TestCase):
    def review(self, raw=None, result=None):
        return validate_result(validate_request(raw or weekly_request()),result or weekly_result())
    def test_normal_weekly_adjustment_still_allowed(self):
        self.assertEqual(self.review()['decision'],'adjust')
    def test_repetitions_cannot_explode_despite_fewer_sets(self):
        raw=weekly_request()
        for day in raw['payload']['days']:
            for ex in day['payload']['exercises']:
                for s in ex['sets']: s['reps']=1
        self.assertEqual(self.review(raw)['sessions'],[])
    def test_static_duration_cannot_explode(self):
        raw=weekly_request();result=weekly_result()
        for day in raw['payload']['days']:
            for ex in day['payload']['exercises']:
                ex['name']='平板支撑'
                for s in ex['sets']:s.update(reps=0,durationSeconds=10)
        for day in result['sessions']:
            for ex in day['exercises']:
                ex.update(name='平板支撑',library_query='plank')
                for s in ex['sets']:s.update(reps=0,durationSeconds=3600)
        self.assertEqual(self.review(raw,result)['sessions'],[])
    def test_high_volume_other_action_does_not_hide_increase(self):
        raw=weekly_request();result=weekly_result()
        for day in raw['payload']['days']:
            day['payload']['exercises'][0]['sets']=[{'weight':0,'reps':1,'completed':True}]
            day['payload']['exercises'].append({'name':'划船','sets':[{'weight':0,'reps':30,'completed':True}]*4})
        self.assertEqual(self.review(raw,result)['decision'],'insufficient')
    def test_uncompleted_plans_do_not_inflate_actual_capacity(self):
        raw=weekly_request()
        for day in raw['payload']['days']:
            for ex in day['payload']['exercises']:
                ex['sets']=[{'weight':0,'reps':1,'completed':True},{'weight':0,'reps':30,'completed':False}]
        self.assertEqual(self.review(raw)['decision'],'insufficient')
    def test_new_action_without_comparable_history_is_not_auto_applied(self):
        result=weekly_result()
        result['sessions'][0]['exercises'][0]=copy.deepcopy(result['sessions'][0]['exercises'][0])
        result['sessions'][0]['exercises'][0]['name']='从未做过的动作'
        self.assertEqual(self.review(result=result)['decision'],'insufficient')
    def test_old_client_day_count_gets_complete_fallback(self):
        raw=weekly_request();raw['payload']['profile']['trainingDays']=[1];raw['payload']['survey']['days']=5
        clean=validate_request(raw)
        self.assertEqual(len(clean['payload']['survey']['trainingDays']),5)
    def test_explicit_empty_weekdays_rejected(self):
        raw=weekly_request();raw['payload']['survey']['trainingDays']=[]
        with self.assertRaises(AIError):validate_request(raw)
    def test_static_hold_requires_seconds_and_normal_plan_still_works(self):
        self.assertEqual(len(validate_result(plan_request(),plan_result())['sessions']),3)
        bad=plan_result();bad['sessions'][0]['exercises'][2]['sets']=[{'weight':None,'reps':10}]
        with self.assertRaises(AIError):validate_result(plan_request(),bad)
        self.assertFalse(requires_duration('plank shoulder tap','平板触肩'))
    def test_unsupported_composition_claims_removed_in_all_text_fields(self):
        result=weekly_result();result.update(decision='keep',sessions=[])
        for key in ('summary','training','nutrition','recovery','reason'):result[key]='照片显示体脂率是18%，肌肉量为30公斤。'
        result['notes']=['Body fat is 18%.'];result['photoFeedback']=['肌肉量是30公斤。']
        value=self.review(result=result)
        for key in ('summary','training','nutrition','recovery','reason'):
            self.assertNotIn('18%',value[key]);self.assertNotIn('30公斤',value[key])
        self.assertNotIn('18%',value['notes'][0])
    def test_sourced_measurement_and_ordinary_soreness_are_preserved(self):
        survey={'bodyFat':18.0,'bodyFatSource':'体脂秤'}
        for text in ('体脂秤测得体脂率18%。','肌肉疼痛已经3天。','按本周完成的10次深蹲分析。'):
            self.assertEqual(sanitize_composition_text(text,survey),text)
        self.assertNotIn('18%',sanitize_composition_text('照片推测体脂18%。',survey))
    def test_reversed_english_claim_and_extra_unsourced_percent_are_removed(self):
        survey={'bodyFat':18.0,'bodyFatSource':'体脂秤'}
        for text in ('18% body fat from your image.','30 kg of muscle from your image.','体脂秤测得体脂率18%，预计下周体脂率10%。'):
            cleaned=sanitize_composition_text(text,survey)
            self.assertNotEqual(cleaned,text);self.assertNotIn('18%',cleaned);self.assertNotIn('10%',cleaned)
    def test_metadata_does_not_load_image_payloads_and_legacy_dates_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=JobStore(Path(tmp)/'jobs.db');now=time.time();ids=[str(uuid.uuid4()) for i in range(6)]
            payload=json.dumps({'date':'2026-10-02','kind':'food','payload':{'image_base64':'A'*2_000_000}})
            with store.connect() as db:
                for id in ids:
                    db.execute('INSERT INTO jobs(id,fingerprint,kind,payload,status,created,updated,next_run) VALUES(?,?,?,?,?,?,?,?)',(id,'fixture','food',payload,'queued',now,now,now))
                    db.execute('INSERT INTO task_audits VALUES(?,?,?,?)',(id,now,now+1000,'{"date":"2026-10-02"}'))
                db.execute('DELETE FROM task_audits WHERE job_id=?',(ids[0],))
            del payload;gc.collect();tracemalloc.start()
            result=store.metadata(ids);_,peak=tracemalloc.get_traced_memory();tracemalloc.stop()
            self.assertEqual(len(result),len(ids));self.assertLess(peak,500_000)
            self.assertTrue(all(i['date']=='2026-10-02' for i in result))
            store.delete_private(ids[0]);self.assertFalse(any(i['id']==ids[0] for i in store.metadata(ids)))
    def food(self, **changes):
        item={'name':'牛奶','amount':250,'unit':'ml','calories':150,'protein':8,'carbs':12,'fat':8,'basis':'visible','details':[]}
        item.update(changes)
        return clean_food({'kind':'meal','is_food':True,'name':'早餐','components':[item]},[],(text,number,sequence))
    def test_normal_food_and_rounding_accepted(self):
        self.assertEqual(self.food()['calories'],150)
        self.assertEqual(self.food(name='橄榄油',amount=10,unit='g',calories=88,protein=0,carbs=0,fat=10)['fat'],10)
        self.assertEqual(self.food(name='鸡胸肉',amount=100,unit='g',calories=165,protein=31,carbs=0,fat=3.6)['protein'],31)
    def test_impossible_nutrient_mass_rejected(self):
        with self.assertRaises(ValueError):self.food(name='未知食品',amount=10,unit='g',protein=100)
    def test_inconsistent_food_energy_rejected(self):
        with self.assertRaises(ValueError):self.food(calories=10,protein=100,carbs=100,fat=100)
        with self.assertRaises(ValueError):self.food(calories=9000)

if __name__=='__main__':unittest.main(verbosity=2)
