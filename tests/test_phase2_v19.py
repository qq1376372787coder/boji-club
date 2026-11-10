"""Validate sparse weight records using production request normalization."""
import copy
import unittest
from test_phase1_v18 import sample
from ai_core import AIError, validate_request, messages_for


class WeightRequests(unittest.TestCase):
    def test_sparse_history_dates_preserved(self):
        raw = sample()
        raw['payload']['body_weight_history'] = [{'date': '2026-09-28', 'kilograms': 68}, {'date': '2026-10-03', 'kilograms': 68.4}]
        value = validate_request(raw)['payload']
        self.assertEqual(value['body_weight_history'], raw['payload']['body_weight_history'])
        self.assertNotIn('body_weight_kg', value)

    def test_current_weight_is_independent_of_health_consent(self):
        raw = {'kind': 'report', 'date': '2026-10-04', 'payload': {'body_weight_kg': 68.2}}
        value = validate_request(raw)['payload']
        self.assertEqual(value['body_weight_kg'], 68.2)
        self.assertIsNone(value['health'])

    def test_old_request_does_not_gain_weight_fields(self):
        value = validate_request(sample())['payload']
        self.assertNotIn('body_weight_kg', value)
        self.assertNotIn('body_weight_history', value)

    def test_empty_or_missing_weight_does_not_imply_zero(self):
        raw = sample(); raw['payload'].update(body_weight_kg=None, body_weight_history=[])
        value = validate_request(raw)['payload']
        self.assertNotIn('body_weight_kg', value)
        self.assertNotIn('body_weight_history', value)

    def test_invalid_weight_values_rejected(self):
        for value in (0, 19.9, 400.1, float('nan'), float('inf'), True):
            raw = sample(); raw['payload']['body_weight_kg'] = value
            with self.subTest(value=value), self.assertRaises(AIError): validate_request(raw)

    def test_future_measurements_rejected(self):
        raw = sample(); raw['payload']['body_weight_history'] = [{'date': '2026-10-05', 'kilograms': 68}]
        with self.assertRaises(AIError): validate_request(raw)

    def test_duplicate_measurement_dates_rejected(self):
        raw = sample(); raw['payload']['body_weight_history'] = [{'date': '2026-10-03', 'kilograms': 68}] * 2
        with self.assertRaises(AIError): validate_request(raw)

    def test_same_day_contradiction_rejected(self):
        raw = sample(); raw['payload'].update(body_weight_kg=68, body_weight_history=[{'date': '2026-10-04', 'kilograms': 69}])
        with self.assertRaises(AIError): validate_request(raw)

    def test_matching_same_day_value_accepted(self):
        raw = sample(); raw['payload'].update(body_weight_kg=68, body_weight_history=[{'date': '2026-10-04', 'kilograms': 68}])
        self.assertEqual(validate_request(raw)['payload']['body_weight_kg'], 68)

    def test_history_limit_rejected(self):
        raw = sample(); raw['payload']['body_weight_history'] = [{'date': '2026-10-03', 'kilograms': 68}] * 31
        with self.assertRaises(AIError): validate_request(raw)

    def test_history_sorted_by_real_date(self):
        raw = sample(); raw['payload']['body_weight_history'] = [{'date': '2026-10-03', 'kilograms': 68.5}, {'date': '2026-09-28', 'kilograms': 68}]
        self.assertEqual(validate_request(raw)['payload']['body_weight_history'][0]['date'], '2026-09-28')

    def test_prompt_does_not_claim_missing_days_or_growth(self):
        prompt = str(messages_for(validate_request(sample())))
        self.assertIn('不能用测量次数冒充连续天数', prompt)
        self.assertIn('没有当天测量不能称今天体重', prompt)

    def test_weekly_keeps_measured_dates_and_no_unmeasured_current_weight(self):
        raw = {'kind': 'weekly_review', 'date': '2026-10-04', 'payload': {
            'profile': {'goal': '增肌', 'experience': '新手', 'venue': '健身房', 'focus': '全身', 'age': 28, 'height': 175, 'weight': 68},
            'survey': {'days': 3}, 'days': [{'date': '2026-10-04', 'payload': {
                'body_weight_history': [{'date': '2026-09-28', 'kilograms': 68}, {'date': '2026-10-03', 'kilograms': 68.4}]}}]}}
        request = validate_request(raw)
        day = request['payload']['days'][0]
        self.assertNotIn('body_weight_kg', day)
        self.assertEqual([row['date'] for row in day['body_weight_history']], ['2026-09-28', '2026-10-03'])
        self.assertIn('必须按日期去重', str(messages_for(request)))


if __name__ == '__main__': unittest.main()
