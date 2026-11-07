"""Card protocol contract tests (V2 schema v1).

Covers: envelope shape per card type, whitelist enforcement, dedup/caps,
deterministic ids, empty states instead of guesses, evidence references,
and the coach clean_result end-to-end integration.
"""
import copy
import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import card_composer
import coach_core

TODAY = dt.date.today()

def make_request(days, upcoming, date=TODAY):
    return {
        'date': date.isoformat(),
        'payload': {
            'version': 1,
            'conversation_id': '11111111-2222-3333-4444-555555555555',
            'question': '今天练什么',
            'history': [],
            'days': days,
            'upcoming': upcoming,
            'proposal_allowed': False,
            'purpose': 'dialogue',
            'timeZone': 'Asia/Shanghai',
        },
    }

def day_payload(completed_sets=0, sessions=0, meals=0, planned_exercises=None):
    return {
        'totals': {'completed_sets': completed_sets},
        'exercises': planned_exercises or [],
        'meals': [{'name': 'x'}] * meals,
        'workout_sessions': [{'id': f's{i}', 'confirmed': True} for i in range(sessions)],
    }

def planned_today(exercise_count=3, sets_per_exercise=4):
    # days[today] 的（规范化后）练习条目：name + sets
    return [{'name': f'动作{i + 1}', 'sets': [{'weight': 40, 'reps': 10, 'completed': False}] * sets_per_exercise}
            for i in range(exercise_count)]

def upcoming_session(date, label='健身房 · 全身力量'):
    return {
        'date': date.isoformat(),
        'label': label,
        'exercises': [
            {'name': '杠铃深蹲', 'muscle': '腿部', 'sets': [{'weight': 60, 'reps': 10}] * 4},
            {'name': '杠铃卧推', 'muscle': '胸部', 'sets': [{'weight': 40, 'reps': 10}] * 3},
            {'name': '坐姿划船', 'muscle': '背部', 'sets': [{'weight': 35, 'reps': 12}] * 3},
        ],
    }

HELPERS = (lambda v, m=3000, allow_empty=False: str(v)[:m], None, lambda v, maximum, minimum=0: v)

def compose(request, requests):
    return card_composer.compose(request, requests, (HELPERS[0], HELPERS[2], None))

class CardComposerTests(unittest.TestCase):
    def test_today_training_payload_comes_from_today_context(self):
        days = [{'date': TODAY.isoformat(), 'payload': day_payload(planned_exercises=planned_today(3, 4))}]
        cards = compose(make_request(days, []), [{'type': 'today_training'}])
        self.assertEqual(len(cards), 1)
        card = cards[0]
        self.assertEqual(card['card_type'], 'today_training')
        self.assertEqual(card['schema_version'], 1)
        payload = card['payload']
        self.assertEqual(payload['exercise_count'], 3)
        self.assertEqual(payload['total_sets'], 12)
        self.assertNotIn('muscle_groups', payload, 'report 上下文没有肌群字段，不得编造')
        self.assertEqual(payload['estimated_minutes'], 36)
        self.assertEqual(card['evidence_refs'], [f'day/{TODAY.isoformat()}'])
        self.assertEqual([a['action_id'] for a in card['actions']], ['start_training', 'view_plan'])
        for key in ('card_id', 'card_type', 'schema_version', 'title', 'payload', 'actions', 'evidence_refs', 'created_at', 'expires_at'):
            self.assertIn(key, card, f'envelope missing {key}')

    def test_today_training_empty_state_when_no_plan(self):
        # 今天没有任何安排（未来有也不算今天）
        days = [{'date': (TODAY - dt.timedelta(days=1)).isoformat(), 'payload': day_payload(completed_sets=10)}]
        request = make_request(days, [upcoming_session(TODAY + dt.timedelta(days=1))])
        cards = compose(request, [{'type': 'today_training'}])
        self.assertEqual(len(cards), 1)
        payload = cards[0]['payload']
        self.assertTrue(payload['empty'])
        self.assertEqual(payload['reason'], 'no_planned_session')
        self.assertIn('hint', payload)
        self.assertEqual([a['action_id'] for a in cards[0]['actions']], ['create_plan'])

    def test_training_progress_counts_confirmed_days(self):
        days = [
            {'date': (TODAY - dt.timedelta(days=1)).isoformat(), 'payload': day_payload(completed_sets=18, sessions=1)},
            {'date': (TODAY - dt.timedelta(days=2)).isoformat(), 'payload': day_payload(completed_sets=24, sessions=1)},
            {'date': (TODAY - dt.timedelta(days=3)).isoformat(), 'payload': day_payload()},
        ]
        cards = compose(make_request(days, []), [{'type': 'training_progress'}])
        payload = cards[0]['payload']
        self.assertEqual(payload['training_days'], 2)
        self.assertEqual(payload['completed_sets'], 42)
        self.assertEqual(payload['confirmed_sessions'], 2)
        self.assertEqual(cards[0]['evidence_refs'], [f'day/{(TODAY - dt.timedelta(days=1)).isoformat()}', f'day/{(TODAY - dt.timedelta(days=2)).isoformat()}'])

    def test_training_progress_empty_state(self):
        days = [{'date': (TODAY - dt.timedelta(days=1)).isoformat(), 'payload': day_payload()}]
        cards = compose(make_request(days, []), [{'type': 'training_progress'}])
        self.assertTrue(cards[0]['payload']['empty'])

    def test_insight_omitted_without_data(self):
        cards = compose(make_request([], []), [{'type': 'insight'}])
        self.assertEqual(cards, [])

    def test_insight_composes_from_recent_days(self):
        days = [
            {'date': (TODAY - dt.timedelta(days=1)).isoformat(), 'payload': day_payload(completed_sets=16)},
            {'date': (TODAY - dt.timedelta(days=2)).isoformat(), 'payload': day_payload(completed_sets=20)},
            # older than the 7 day window: must not be counted
            {'date': (TODAY - dt.timedelta(days=9)).isoformat(), 'payload': day_payload(completed_sets=99)},
        ]
        cards = compose(make_request(days, []), [{'type': 'insight'}])
        payload = cards[0]['payload']
        self.assertEqual(payload['training_days'], 2)
        self.assertEqual(payload['completed_sets'], 36)
        self.assertEqual(payload['evidence_dates'], [(TODAY - dt.timedelta(days=1)).isoformat(), (TODAY - dt.timedelta(days=2)).isoformat()])

    def test_unknown_type_dropped_and_duplicates_removed(self):
        cards = compose(make_request([], []), [
            {'type': 'today_training'}, {'type': 'today_training'},
            {'type': 'future_mutation'}, {'type': 'meal_draft'},
        ])
        self.assertEqual([c['card_type'] for c in cards], ['today_training'])

    def test_card_ids_deterministic_per_conversation(self):
        days = [{'date': TODAY.isoformat(), 'payload': day_payload(planned_exercises=planned_today())}]
        first = compose(make_request(days, []), [{'type': 'today_training'}])
        second = compose(make_request(days, []), [{'type': 'today_training'}])
        self.assertEqual(first[0]['card_id'], second[0]['card_id'])
        changed = make_request(days, [])
        changed['payload']['conversation_id'] = '99999999-2222-3333-4444-555555555555'
        different = compose(changed, [{'type': 'today_training'}])
        self.assertNotEqual(first[0]['card_id'], different[0]['card_id'])

    def test_expires_after_created(self):
        days = [{'date': TODAY.isoformat(), 'payload': day_payload(planned_exercises=planned_today())}]
        cards = compose(make_request(days, []), [{'type': 'today_training'}])
        self.assertGreater(cards[0]['expires_at'], cards[0]['created_at'])

    def test_no_requests_means_no_cards(self):
        self.assertEqual(compose(make_request([], []), None), [])

class CoachIntegrationTests(unittest.TestCase):
    def _helpers(self):
        import ai_core
        return (ai_core.text, ai_core.sequence, ai_core.iso_date)

    def _request(self, days, upcoming):
        # days 这里传原始 report 载荷（clean_request 会逐日再校验/规范化）
        raw = {
            'version': 1,
            'conversation_id': '11111111-2222-3333-4444-555555555555',
            'question': '今天练什么，帮我安排',
            'history': [],
            'days': days,
            'upcoming': upcoming,
            'timeZone': 'Asia/Shanghai',
        }
        import ai_core
        clean = coach_core.clean_request(raw, TODAY.isoformat(), (ai_core.text, ai_core.number, ai_core.sequence, ai_core.iso_date, ai_core.validate_request))
        return {'date': TODAY.isoformat(), 'payload': clean}

    @staticmethod
    def _raw_day_today_plan():
        return {
            'exercises': [
                {'name': '杠铃深蹲', 'sets': [{'weight': 60, 'reps': 10, 'completed': False}] * 4},
                {'name': '杠铃卧推', 'sets': [{'weight': 40, 'reps': 10, 'completed': False}] * 3},
                {'name': '坐姿划船', 'sets': [{'weight': 35, 'reps': 12, 'completed': False}] * 3},
            ],
            'meals': [],
        }

    @staticmethod
    def _raw_day(sets=2, confirmed=True):
        sid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        payload = {
            'exercises': [{
                'name': '杠铃卧推', 'session_id': sid,
                'sets': [{'weight': 40, 'reps': 10, 'completed': True} for _ in range(sets)],
            }],
            'meals': [{'name': '燕麦碗', 'calories': 320, 'protein': 14, 'carbs': 42, 'fat': 8}],
        }
        if confirmed:
            payload['workout_sessions'] = [{'id': sid, 'savedAt': 700000000}]
        return payload

    def test_clean_result_attaches_cards(self):
        # 今天（请求日）带已安排动作 + 昨天有确认训练
        request = self._request(
            [
                {'date': TODAY.isoformat(), 'payload': self._raw_day_today_plan()},
                {'date': (TODAY - dt.timedelta(days=1)).isoformat(), 'payload': self._raw_day(sets=18)},
            ],
            [],
        )
        raw = {
            'kind': 'coach',
            'coach': {
                'answer': '今天的安排以下方卡片为准，动作和组数都在里面。开始前先热身，组间休息按计划执行即可。这样循序渐进更稳。',
                'source_ids': [f'day/{(TODAY - dt.timedelta(days=1)).isoformat()}'],
                'actions': [],
                'card_requests': [{'type': 'today_training'}],
            },
        }
        result = coach_core.clean_result(request, raw, self._helpers())
        self.assertEqual(len(result['coach']['cards']), 1)
        self.assertEqual(result['coach']['cards'][0]['card_type'], 'today_training')
        self.assertEqual(result['coach']['cards'][0]['payload']['exercise_count'], 3)
        self.assertEqual(result['coach']['cards'][0]['payload']['total_sets'], 10)

    def test_clean_result_without_card_requests_has_no_cards_key(self):
        request = self._request(
            [{'date': (TODAY - dt.timedelta(days=1)).isoformat(), 'payload': self._raw_day(sets=18)}],
            [],
        )
        raw = {
            'kind': 'coach',
            'coach': {
                'answer': '最近有一次确认训练，节奏可以继续保持。注意休息与饮食记录的完整性，先把每餐记全再谈调整。',
                'source_ids': [f'day/{(TODAY - dt.timedelta(days=1)).isoformat()}'],
                'actions': [],
            },
        }
        result = coach_core.clean_result(request, raw, self._helpers())
        self.assertNotIn('cards', result['coach'])


class DraftCardTests(unittest.TestCase):
    """Phase 3 §4: AI-drafted meal/weight proposal cards (model content, server-validated)."""
    def setUp(self):
        import card_composer
        import ai_core
        self.cc = card_composer
        self.helpers = (ai_core.text, ai_core.sequence, ai_core.iso_date)
        self.today = TODAY.isoformat()
        self.conversation = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        self.request = {
            'id': 'r1', 'kind': 'coach', 'date': self.today,
            'payload': {'conversation_id': self.conversation, 'question': 'q', 'history': [],
                        'days': [{'date': self.today, 'payload': {'exercises': [], 'meals': [], 'totals': {'completed_sets': 0}}}],
                        'timeZone': 'Asia/Shanghai'},
        }

    def compose(self, requests):
        return self.cc.compose(self.request, requests, self.helpers)

    def test_meal_draft_composed(self):
        cards = self.compose([{'type': 'meal_draft', 'payload': {'date': self.today,
            'meals': [{'name': '鸡胸肉', 'category': '午餐', 'calories': 320, 'protein': 48}]}}])
        self.assertEqual(len(cards), 1)
        card = cards[0]
        self.assertEqual(card['card_type'], 'meal_draft')
        self.assertEqual(card['title'], '待确认的饮食记录')
        self.assertEqual(card['payload']['meals'][0]['name'], '鸡胸肉')
        self.assertEqual(card['payload']['meals'][0]['calories'], 320.0)
        self.assertEqual([a['action_id'] for a in card['actions']], ['confirm_proposal', 'dismiss_proposal'])
        self.assertEqual(card['evidence_refs'], [f'day/{self.today}'])

    def test_draft_card_ids_deterministic_per_payload(self):
        request = {'type': 'meal_draft', 'payload': {'date': self.today, 'meals': [{'name': '燕麦', 'category': '早餐'}]}}
        one = self.compose([dict(request)])
        two = self.compose([dict(request)])
        self.assertEqual(one[0]['card_id'], two[0]['card_id'])
        other = self.compose([{'type': 'meal_draft', 'payload': {'date': self.today, 'meals': [{'name': '鸡蛋', 'category': '早餐'}]}}])
        self.assertNotEqual(one[0]['card_id'], other[0]['card_id'])

    def test_wrong_date_dropped(self):
        cards = self.compose([{'type': 'meal_draft', 'payload': {'date': '2020-01-01', 'meals': [{'name': 'x', 'category': '加餐'}]}}])
        self.assertEqual(cards, [])

    def test_bounds_violations_dropped(self):
        for bad in [
            {'date': self.today, 'meals': [{'name': 'x', 'category': '宵夜'}]},
            {'date': self.today, 'meals': [{'name': '', 'category': '加餐'}]},
            {'date': self.today, 'meals': [{'name': 'x' * 101, 'category': '加餐'}]},
            {'date': self.today, 'meals': [{'name': 'x', 'category': '加餐', 'calories': 99999}]},
            {'date': self.today, 'meals': [{'name': 'x', 'category': '加餐', 'protein': '高'}]},
            {'date': self.today, 'meals': [{'name': 'x', 'category': '加餐'}] * 4},
            {'date': self.today, 'meals': []},
        ]:
            self.assertEqual(self.compose([{'type': 'meal_draft', 'payload': bad}]), [], bad)

    def test_weight_entry_composed_and_bounded(self):
        cards = self.compose([{'type': 'weight_entry', 'payload': {'date': self.today, 'kilograms': 72.5, 'bodyFatPercentage': 18.2}}])
        self.assertEqual(cards[0]['card_type'], 'weight_entry')
        self.assertEqual(cards[0]['payload']['kilograms'], 72.5)
        self.assertEqual(self.compose([{'type': 'weight_entry', 'payload': {'date': self.today, 'kilograms': 500}}]), [])
        self.assertEqual(self.compose([{'type': 'weight_entry', 'payload': {'date': self.today}}]), [])

    def test_two_draft_kinds_coexist(self):
        # sequence() 在入口就把请求截到 MAX_CARDS；两类提案卡可同轮并存。
        cards = self.compose([
            {'type': 'meal_draft', 'payload': {'date': self.today, 'meals': [{'name': 'a', 'category': '加餐'}]}},
            {'type': 'weight_entry', 'payload': {'date': self.today, 'kilograms': 70}},
        ])
        self.assertEqual([c['card_type'] for c in cards], ['meal_draft', 'weight_entry'])

    def test_expired_card_actions(self):
        cards = self.compose([{'type': 'meal_draft', 'payload': {'date': self.today, 'meals': [{'name': 'a', 'category': '加餐'}]}}])
        self.assertEqual(cards[0]['actions'][0]['kind'], 'confirm')
        self.assertEqual(cards[0]['actions'][1]['kind'], 'dismiss')


if __name__ == '__main__':
    unittest.main()
