"""Plan reasons use validated evidence; malformed optional prose cannot veto a plan."""
import copy
import sys
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
import ai_core as core
import plan_explanation as reasons
from test_backend_v2 import request, result


def explained_request():
    value = request()
    value['payload']['plan_explanation_version'] = 1
    return core.validate_request(value)


PROSE = '你选择了增肌塑形，因此安排采用基础推与拉动作配合下肢练习，先建立可执行的记录起点。首次训练请核对动作是否熟悉，并把实际完成情况和难度留下来，后续再据此调整。'


class PlanReasons(unittest.TestCase):
    def test_legacy_plan_output_stays_unchanged(self):
        self.assertNotIn('explanation', core.validate_result(request(), result()))
        self.assertNotIn('本请求需要在同一个JSON中添加 explanation', core.messages_for(request())[0]['content'])

    def test_flag_only_enables_supported_contract(self):
        for value in (True, False, 0, 2, 1.0, '1', {}, []):
            with self.subTest(value=value):
                req = request(); req['payload']['plan_explanation_version'] = value
                with self.assertRaises(core.AIError):
                    core.validate_request(req)
        self.assertEqual(explained_request()['payload']['plan_explanation_version'], 1)

    def test_prompt_is_same_request(self):
        messages = core.messages_for(explained_request())
        self.assertEqual(len(messages), 2)
        self.assertIn(reasons.PROMPT, messages[0]['content'])
        self.assertIn('allowed_training_sessions', messages[1]['content'])

    def test_optional_missing_or_invalid_prose_does_not_fail_plan(self):
        baseline = core.validate_result(request(), result())
        for raw in (None, [], 'bad', {}, {'body': {'invalid': True}}, {'sessions': [None, {}]}):
            with self.subTest(raw=raw):
                value = result(); value['explanation'] = raw
                saved = core.validate_result(explained_request(), value)
                explanation = saved.pop('explanation')
                self.assertEqual(saved, baseline)
                self.assertEqual(explanation['version'], 1)
                self.assertEqual(len(explanation['summary']), 3)
                self.assertEqual([s['id'] for s in explanation['sections']], list(reasons.TOPICS))

    def test_trusted_evidence_matches_actual_plan_and_profile(self):
        value = core.validate_result(explained_request(), result())
        detail = {s['id']: s for s in value['explanation']['sections']}
        self.assertIn('28 岁 · 175 厘米 · 68 公斤', detail['body']['basis'])
        self.assertIn('9 项动作、9 组，其中 3 组按秒', detail['volume']['basis'])
        for s in value['sessions']:
            self.assertIn(s['date'], detail['schedule']['basis'])
        self.assertIn('徒手', detail['selection']['basis'])
        self.assertEqual([s['date'] for s in value['explanation']['sessions']], [s['date'] for s in value['sessions']])
        self.assertTrue(all(s['weight'] is None for day in value['sessions'] for e in day['exercises'] for s in e['sets']))

    def test_model_cannot_replace_basis_or_summary(self):
        value = result(); value['explanation'] = {'basis': '999公斤', 'summary': ['胖子'], 'sections': [{'id': 'body', 'detail': '体脂很高'}]}
        actual = core.validate_result(explained_request(), value)['explanation']
        self.assertEqual(actual, core.validate_result(explained_request(), result())['explanation'])

    def test_muscle_evidence_uses_catalog_instead_of_model_label(self):
        value = result()
        for s in value['sessions']:
            for e in s['exercises']: e['muscle'] = '模型乱写的部位'
        saved = core.validate_result(explained_request(), value)
        section = next(s for s in saved['explanation']['sections'] if s['id'] == 'selection')
        self.assertNotIn('模型乱写', section['basis'])
        for s in saved['sessions']:
            for e in s['exercises']:
                row = core.CURATED_MOVEMENTS[e['library_id']]
                self.assertIn(row['category_zh'], section['basis'])

    def test_valid_prose_is_retained(self):
        value = result(); value['explanation'] = {key: PROSE for key in reasons.TOPICS}
        explanation = core.validate_result(explained_request(), value)['explanation']
        self.assertTrue(all(s['detail'] == PROSE for s in explanation['sections']))

    def test_checked_body_quantities_are_retained_and_wrong_quantities_fall_back(self):
        body = '你填写的年龄是二十八岁，身高一百七十五厘米，体重六十八公斤。这些是自填背景，不能据此推断体脂或体能，实际训练反馈更重要。'
        value = result(); value['explanation'] = {'body': body}
        saved = core.validate_result(explained_request(), value)
        self.assertEqual(saved['explanation']['sections'][4]['detail'], body)
        for wrong in ('九十八公斤', '98公斤', '９８公斤', '-68公斤', '负六十八公斤'):
            value['explanation']['body'] = body.replace('六十八公斤', wrong)
            self.assertNotEqual(core.validate_result(explained_request(), value)['explanation']['sections'][4]['detail'], value['explanation']['body'])

    def test_body_numbers_cannot_be_reused_as_a_starting_load(self):
        text = '你是训练新手，建议使用六十八公斤作为训练起始负重，这样可以帮助你更有效地完成基础训练。'
        self.assertEqual(reasons.clean_prose(text, 'fallback', {'公斤':{68}}), 'fallback')

    def test_unprescribed_rest_time_does_not_enter_volume_reason(self):
        prose = '请优先保证动作质量，并在每组之间休息六十秒，这样有助于继续练习且保持记录完整。'
        value = result(); value['explanation'] = {'volume': prose}
        self.assertNotEqual(core.validate_result(explained_request(), value)['explanation']['sections'][3]['detail'], prose)

    def test_common_chinese_quantities_and_decimal_units(self):
        for word, number in [('二十八',28),('一百七十五',175),('四十五',45),('一七五',175),('六十八点五',68.5),('６８．５',68.5),('两',2)]:
            self.assertEqual(reasons.quantity_number(word), number)
        prose = '你填写的体重是六十八点五公斤，它只是自填的背景信息，不能替代实际称重或体能评估。'
        self.assertEqual(reasons.clean_prose(prose, 'fallback', {'公斤':{68.5}}), prose)

    def test_recovery_days_are_not_mistaken_for_training_frequency(self):
        value = result()
        correct = '每周三次训练，训练日之间间隔一天，保留恢复空档。请记录实际完成情况，再结合训练感受核对是否适合继续。'
        value['explanation'] = {'schedule': correct}
        self.assertEqual(core.validate_result(explained_request(), value)['explanation']['sections'][1]['detail'], correct)
        wrong = correct.replace('每周三次', '每周两次')
        value['explanation']['schedule'] = wrong
        self.assertNotEqual(core.validate_result(explained_request(), value)['explanation']['sections'][1]['detail'], wrong)
        value['explanation']['volume'] = '每组练三次，并在动作稳定的前提下完整记录实际完成情况，以便后续核对训练难度。'
        self.assertNotEqual(core.validate_result(explained_request(), value)['explanation']['sections'][3]['detail'], value['explanation']['volume'])

    def test_quantity_context_does_not_cross_a_sentence(self):
        correct = '训练日之间保留恢复空档。三天均为居家徒手训练，符合已填写的器械条件。每周三次，间隔一天，首次执行仍请记录真实的训练感受。'
        value = result(); value['explanation'] = {'schedule': correct}
        self.assertEqual(core.validate_result(explained_request(), value)['explanation']['sections'][1]['detail'], correct)

    def test_untrusted_numerical_clinical_code_or_shaming_prose_falls_back(self):
        for raw in ('你已经练了3天，这说明你的出勤情况十分优秀，应该马上继续加量。',
                    '你的恢复能力很差，因此我们必须安排更加严格的休息计划来帮助你。',
                    '你的体脂率是百分之三十，必须减肥，这套训练保证减脂成功。',
                    '按照每次三组安排进行训练就可以改善你的日常状态以及训练表现。',
                    '你的BMI需要尽快改善，因此我们为你特别安排了这套训练方案。',
                    '你已经摆烂很久，这些基础动作就是给不认真训练的人准备的。',
                    '此处的代码字段代表身体资料，可以帮助你理解训练方案如何生成。',
                    'x' * 800, PROSE + '\x00'):
            with self.subTest(raw=raw):
                self.assertEqual(reasons.clean_prose(raw, 'fallback'), 'fallback')

    def test_class_purpose_needs_exact_canonical_exercise_order(self):
        req = explained_request()
        valid = core.validate_result(req, result())
        purposes = [{'date': s['date'], 'exercise_ids': [e['library_id'] for e in s['exercises']], 'purpose': PROSE} for s in valid['sessions']]
        value = result(); value['explanation'] = {'sessions': purposes}
        self.assertTrue(all(s['purpose'] == PROSE for s in core.validate_result(req, value)['explanation']['sessions']))
        for change in ('order', 'missing', 'duplicate', 'unknown_date'):
            bad = copy.deepcopy(value)
            items = bad['explanation']['sessions']
            if change == 'order': items[0]['exercise_ids'].reverse()
            elif change == 'missing': items[0]['exercise_ids'].pop()
            elif change == 'duplicate': items.append(copy.deepcopy(items[0]))
            else: items[0]['date'] = '2099-01-01'
            actual = core.validate_result(req, bad)['explanation']['sessions']
            self.assertNotEqual(actual[0]['purpose'], PROSE, change)
            self.assertEqual(actual[1]['purpose'], PROSE, change)

    def test_invalid_core_plan_still_fails(self):
        value = result(); value['explanation'] = {key: PROSE for key in reasons.TOPICS}
        value['sessions'][0]['date'] = '2026-10-01'
        with self.assertRaises(core.AIError): core.validate_result(explained_request(), value)

    def test_plan_and_explanation_use_one_transport_request(self):
        calls = []
        def transport(provider, messages, limit):
            calls.append(provider.name)
            self.assertIn(reasons.PROMPT, messages[0]['content'])
            self.assertEqual(limit, 12288)
            return result(), {}
        router = core.Router([core.Provider('longcat', 'invalid', 'synthetic', 'test', priority=10)], transport)
        saved, provider, _ = router.run(explained_request())
        self.assertEqual(calls, ['longcat'])
        self.assertEqual(provider, 'longcat')
        self.assertEqual(saved['explanation']['version'], 1)

    def test_fallback_provider_gets_same_explanation_request(self):
        calls = []
        def transport(provider, messages, limit):
            calls.append(provider.name)
            self.assertIn(reasons.PROMPT, messages[0]['content'])
            if provider.name == 'longcat': raise core.AIError('upstream_timeout', 'fixture', True, True)
            return result(), {}
        providers = [core.Provider(n, 'invalid', 'fixture', 'test', priority=i) for i, n in enumerate(('longcat', 'mimo', 'deepseek'), 10)]
        saved, provider, _ = core.Router(providers, transport).run(explained_request())
        self.assertEqual(calls, ['longcat', 'mimo']); self.assertEqual(provider, 'mimo')
        self.assertEqual(saved['explanation']['version'], 1)


if __name__ == '__main__': unittest.main(verbosity=2)
