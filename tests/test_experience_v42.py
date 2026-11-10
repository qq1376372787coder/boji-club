"""Plan presentation must not discard good schedules or alter their numbers."""
import copy
import unittest
from test_backend_v2 import request, result
from ai_core import AIError, Provider, Router, validate_result, plan_display_text

class ChinesePlanPresentation(unittest.TestCase):
    def test_mixed_units_and_effort_are_readable_without_losing_numbers(self):
        note = '每组休息90秒，使用RPE7；示例60kg，保持2 RIR，约45min。'
        self.assertEqual(plan_display_text(note), '每组休息90秒，使用主观用力度7；示例60公斤，保持2 预计还能完成的次数，约45分钟。')

    def test_invalid_notes_trigger_next_provider_not_silent_loss(self):
        value = request(); value['payload']['_routing_version'] = 2
        seen = []
        def transport(provider, *args):
            seen.append(provider.name); output = result()
            output['notes'] = ['Rest for 90 seconds'] if provider.name == 'longcat' else ['每组休息90秒，控制动作。']
            return output, {}
        providers = [Provider(name, 'https://example.invalid', 'fixture', 'synthetic', 60, True, True, rank)
                     for name, rank in [('longcat', 10), ('mimo', 20), ('deepseek', 30)]]
        cleaned, provider, _ = Router(providers, transport).run(value)
        self.assertEqual(seen, ['longcat', 'mimo']); self.assertEqual(provider, 'mimo')
        self.assertEqual(cleaned['notes'], ['每组休息90秒，控制动作。'])

    def test_english_headings_receive_neutral_labels_without_schedule_changes(self):
        output = result(); output['title'] = 'Upper Lower'; output['sessions'][0]['label'] = 'Day A'
        reference = validate_result(request(), result())
        cleaned = validate_result(request(), output)
        self.assertEqual(cleaned['title'], '训练计划')
        self.assertEqual(cleaned['sessions'][0]['label'], '当日训练')
        self.assertEqual(cleaned['sessions'], reference['sessions'])

    def test_chinese_headings_and_numeric_rest_survive(self):
        output = result(); output['title'] = '稳步建立训练习惯'
        output['sessions'][0]['label'] = '全身基础训练'
        output['notes'] = ['每组之间休息90秒；先做3组，再结合体感调整。']
        cleaned = validate_result(request(), output)
        self.assertEqual(cleaned['title'], output['title'])
        self.assertEqual(cleaned['sessions'][0]['label'], output['sessions'][0]['label'])
        self.assertEqual(cleaned['notes'], output['notes'])

    def test_code_and_unknown_english_are_not_exposed(self):
        for note in ['{"trainingDays":[1,3,5]}', '请读取profile.sessionMinutes()', '采用progressive overload训练']:
            with self.subTest(note=note), self.assertRaises(AIError):
                output = result(); output['notes'] = [note]
                validate_result(request(), output)

    def test_unit_translation_does_not_change_set_values(self):
        output = result(); output['notes'] = ['每组10 reps，侧桥30秒；重量单位kg。']
        reference = validate_result(request(), result())
        cleaned = validate_result(request(), output)
        self.assertEqual(cleaned['sessions'], reference['sessions'])
        self.assertEqual(cleaned['notes'], ['每组10 次数，侧桥30秒；重量单位公斤。'])

if __name__ == '__main__': unittest.main()
