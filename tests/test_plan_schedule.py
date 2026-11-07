"""Rolling-week regressions and accurate AI failure classification."""
import copy,datetime,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import ai_core as core
from test_backend_v2 import request,result

class PlanScheduleTests(unittest.TestCase):
    def value(self,date='2026-10-09',venue='健身房'):
        value=request();value['date']=date;value['payload']['profile']['venue']=venue
        return value

    def test_friday_keeps_today_and_crosses_calendar_week(self):
        schedule=core.plan_schedule(self.value())
        self.assertEqual([day['date'] for day in schedule],['2026-10-09','2026-10-12','2026-10-14'])
        self.assertEqual([day['weekday'] for day in schedule],[5,1,3])

    def test_every_start_weekday_has_exact_selected_sessions(self):
        for offset in range(7):
            date=datetime.date(2026,10,5)+datetime.timedelta(days=offset)
            value=self.value(date.isoformat());p=value['payload']['profile'];p['venue']='两者都有';p['homeTrainingDays']=[5]
            schedule=core.plan_schedule(value)
            self.assertEqual(len(schedule),p['daysPerWeek'])
            for day in schedule:
                actual=datetime.date.fromisoformat(day['date'])
                self.assertTrue(0 <= (actual-date).days <= 6)
                self.assertEqual(day['weekday'],actual.isoweekday())
                self.assertEqual(day['venue'],'在家' if actual.isoweekday()==5 else '健身房')

    def test_year_and_leap_day_boundaries(self):
        for start in ['2026-12-31','2028-02-27']:
            value=self.value(start);p=value['payload']['profile'];p['trainingDays']=list(range(1,8));p['daysPerWeek']=7
            schedule=core.plan_schedule(value)
            self.assertEqual(len({day['date'] for day in schedule}),7)
            self.assertEqual(schedule[-1]['date'],(datetime.date.fromisoformat(start)+datetime.timedelta(days=6)).isoformat())

    def test_generate_prompt_has_exact_dates_and_valid_example(self):
        value=self.value();messages=core.messages_for(value)
        self.assertNotIn('28天',messages[0]['content'])
        self.assertEqual(json.loads(messages[1]['content'])['allowed_training_sessions'],core.plan_schedule(value))
        system=messages[0]['content'];prefix='\n输出结构（仅演示一堂课的格式，必须覆盖全部允许日期）：'
        example=json.loads(system.split(prefix,1)[1].split('\n',1)[0])
        complete=copy.deepcopy(example);complete['sessions']=[dict(copy.deepcopy(example['sessions'][0]),date=day['date']) for day in core.plan_schedule(value)]
        self.assertEqual(len(core.validate_result(value,complete)['sessions']),3)

    def test_parse_plan_retains_28_day_window(self):
        value=self.value();value['kind']='parse_plan';value['payload']['text']='周一深蹲三组'
        messages=core.messages_for(value)
        self.assertIn('28天',messages[0]['content'])
        self.assertNotIn('allowed_training_sessions',json.loads(messages[1]['content']))

    def test_invalid_results_not_reported_as_connection_failure(self):
        providers=[core.Provider(name,'https://example.invalid','test','test') for name in ['mimo','deepseek']]
        def transport(*args):raise core.AIError('invalid_output','test',True,True)
        with self.assertRaises(core.AIError) as caught:core.Router(providers,transport).run(self.value())
        self.assertEqual(caught.exception.code,'invalid_output')
        self.assertFalse(caught.exception.retryable)

    def test_actual_connection_failure_keeps_availability_code(self):
        providers=[core.Provider('mimo','https://example.invalid','test','test')]
        def transport(*args):raise core.AIError('upstream_timeout','test',True,True)
        with self.assertRaises(core.AIError) as caught:core.Router(providers,transport).run(self.value())
        self.assertEqual(caught.exception.code,'all_unavailable')

    def test_fallback_still_returns_valid_plan(self):
        value=request();calls=[]
        providers=[core.Provider(name,'https://example.invalid','test','test') for name in ['mimo','deepseek']]
        def transport(provider,*args):
            calls.append(provider.name)
            if provider.name=='mimo':raise core.AIError('invalid_output','test',True,True)
            return result(),{}
        cleaned,provider,_=core.Router(providers,transport).run(value)
        self.assertEqual(provider,'deepseek');self.assertEqual(calls,['mimo','deepseek'])
        self.assertEqual(len(cleaned['sessions']),3)

if __name__=='__main__':unittest.main()
