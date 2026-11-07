"""Real report validators and routing with synthetic data; no paid model calls."""
import copy,json,unittest
from test_phase1_v18 import sample
from test_backend_offline import weekly_request,weekly_result
from ai_core import AIError,Provider,Router,validate_request,validate_result,messages_for,analysis_facts,analysis_text
from weekly_core import sanitize_composition_text

def report(text='已有记录'):
    return {'kind':'report','summary':text,'training':text,'nutrition':text,'recovery':text,'notes':[]}

class DetailedAnalysisTests(unittest.TestCase):
    def test_record_volume_is_not_treated_as_muscle_growth_score(self):
        output=analysis_text('全周记录14组。刺激量明显偏低，增肌推进空间被卡住。')
        self.assertIn('全周记录14组',output);self.assertNotIn('明显偏低',output);self.assertNotIn('被卡住',output)
        self.assertIn('不能判断',output)
    def test_cautious_statement_about_missing_stimulus_evidence_is_kept(self):
        text='不能凭少量记录断言刺激量不足。'
        self.assertEqual(analysis_text(text),text)
    def test_missing_body_fat_does_not_erase_a_separate_profile_weight(self):
        text='体脂没有测量，资料体重68公斤，不代表本周实际测量。'
        self.assertEqual(sanitize_composition_text(text,{'bodyFat':None,'bodyFatSource':''}),text)
    def test_daily_removes_numeric_prescription_but_keeps_actual_data(self):
        self.assertEqual(analysis_text('已登记30公斤8次。下次尝试做满3组，每组8次。'), '已登记30公斤8次。')
        self.assertIn('3天饮食',analysis_text('建议登记3天饮食。'))
        self.assertEqual(analysis_text('这只是未登记，不代表没吃。建议下次登记1次餐食。'),'这只是未登记，不代表没吃。建议下次登记1次餐食。')
    def test_blocked_weekly_plan_does_not_survive_as_prose(self):
        raw=weekly_result();raw['sessions'][0]['exercises'][0]['name']='新增无基线动作'
        raw['training']='本周记录14组。下周补上上肢与髋部动作，每次14组。'
        output=validate_result(validate_request(weekly_request()),raw)
        self.assertEqual(output['decision'],'insufficient');self.assertEqual(output['sessions'],[])
        self.assertEqual(output['training'],'本周记录14组。')
        self.assertGreater(len(output['reason']),150)
    def test_empty_health_metadata_is_not_shared_measurement(self):
        raw=sample();raw['payload']['health']['workouts']=[];raw['payload']['health'].pop('activeEnergy');raw['payload'].pop('workout_link')
        facts=analysis_facts(validate_request(raw))
        self.assertEqual(facts['有已分享健康数据的日期'],[])
    def test_weekly_facts_separate_future_preference_from_actual_training(self):
        request=validate_request(weekly_request());facts=analysis_facts(request)
        self.assertEqual(len(facts['有已完成训练记录的日期']),7)
        self.assertEqual(facts['下周可训练天数偏好'],2)
        self.assertEqual(facts['下周已选择可训练星期'],['周一','周三'])
        self.assertTrue(facts['下周星期已确定'])
    def test_facts_are_delivered_with_user_message_without_changing_request(self):
        request=validate_request(weekly_request());before=copy.deepcopy(request)
        content=json.loads(messages_for(request)[1]['content'])
        self.assertEqual(content['数据口径'],analysis_facts(request));self.assertEqual(request,before)
    def test_sparse_daily_facts_do_not_claim_training_or_diet_complete(self):
        request=validate_request(sample());facts=analysis_facts(request)
        self.assertEqual(facts['已登记完成组数'],1)
        self.assertEqual(facts['有饮食记录的日期'],[])
        self.assertIn('不能',facts['记录完整性'])
    def test_repeated_weight_history_is_deduplicated_in_facts(self):
        raw=weekly_request()
        for row in raw['payload']['days']:row['payload']['body_weight_history']=[{'date':'2026-09-20','kilograms':68}]
        facts=analysis_facts(validate_request(raw))
        self.assertEqual(facts['每日体重实际测量日期与公斤数'],[{'日期':'2026-09-20','公斤':68}])
    def test_new_report_version_is_kept_but_not_added_to_old_requests(self):
        raw=sample();self.assertNotIn('analysis_version',validate_request(raw)['payload'])
        raw['payload']['analysis_version']=2
        self.assertEqual(validate_request(raw)['payload']['analysis_version'],2)
    def test_weekly_version_is_kept_and_invalid_versions_rejected(self):
        raw=weekly_request();raw['payload']['analysis_version']=2
        self.assertEqual(validate_request(raw)['payload']['analysis_version'],2)
        for invalid in (True,1,3,'2'):
            raw['payload']['analysis_version']=invalid
            with self.subTest(invalid=invalid),self.assertRaises(AIError):validate_request(raw)
    def test_long_daily_result_roundtrips_without_truncation(self):
        paragraph='完成记录中的一组，并说明下一次检查方法。\n'*50
        raw=report(paragraph)
        output=validate_result(validate_request(sample()),raw)
        feedback=output.pop('training_feedback');self.assertEqual(feedback['status'],'gray')
        self.assertEqual(output,raw)
    def test_long_weekly_result_keeps_evidence_and_reason(self):
        raw=weekly_result();raw.update(decision='keep',sessions=[])
        for key in ['summary','training','nutrition','recovery','reason']: raw[key]='实际记录支持的明确判断。\n'*60
        output=validate_result(validate_request(weekly_request()),raw)
        for key in ['summary','training','nutrition','recovery','reason']: self.assertEqual(output[key],raw[key])
    def test_existing_short_reports_still_valid(self):
        output=validate_result(validate_request(sample()),report())
        feedback=output.pop('training_feedback');self.assertEqual(feedback['status'],'gray')
        self.assertEqual(output,report())
    def test_unbounded_report_field_is_rejected(self):
        with self.assertRaises(AIError): validate_result(validate_request(sample()),report('长'*1501))
    def test_report_budget_actually_reaches_transport(self):
        seen=[]
        def transport(provider,messages,budget): seen.append(budget); return report(),{}
        result=Router([Provider('mimo','https://example.invalid','fixture','unused')],transport=transport).run(validate_request(sample()),lambda _:None)
        self.assertEqual(seen,[6144]);self.assertEqual(result[0]['kind'],'report')
    def test_weekly_budget_and_no_unrequested_plan(self):
        seen=[];raw=weekly_result();raw.update(decision='keep',sessions=[])
        def transport(provider,messages,budget):seen.append(budget);return raw,{}
        result=Router([Provider('mimo','https://example.invalid','fixture','unused')],transport=transport).run(validate_request(weekly_request()),lambda _:None)
        self.assertEqual(seen,[8192]);self.assertEqual(result[0]['sessions'],[])
    def test_sharp_prompt_requires_evidence_and_specific_actions(self):
        for request in [sample(),weekly_request()]:
            prompt=messages_for(validate_request(request))[0]['content']
            self.assertIn('具体数字/日期',prompt);self.assertIn('批评行为和计划，不攻击人格',prompt);self.assertIn('可观察的检查点',prompt)
    def test_daily_preserves_missing_meal_and_energy_rules(self):
        prompt=messages_for(validate_request(sample()))[0]['content']
        self.assertIn('未记全餐时不能断言全天摄入不足或过量',prompt)
        self.assertIn('不能仅凭少量记录给身体效果下结论',prompt)
    def test_pain_keeps_no_plan_even_in_long_weekly_output(self):
        request=weekly_request();request['payload']['survey']['pain']='有疼痛'
        raw=weekly_result();raw['training']='记录分析。'*120
        output=validate_result(validate_request(request),raw)
        self.assertEqual(output['decision'],'insufficient');self.assertEqual(output['sessions'],[])

if __name__=='__main__':unittest.main()
