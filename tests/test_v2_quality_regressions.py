"""Regressions for verified V2.0 quality issues (timezone, safety, quota, routing)."""
import datetime as dt
import importlib.util
import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
sys.path.insert(0, str(ROOT / 'tests'))
import ai_core as core
import server
from adaptive_core import clean_schedule_proposal
from test_backend_v2 import request as plan_request, result as plan_result


def food_request():
    return {'kind': 'food', 'date': '2026-10-12',
            'payload': {'source': 'text', 'description': '两个鸡蛋', 'meal_category': '早餐'}}


def report_body(date):
    return {'kind': 'report', 'date': date, 'payload': {
        'exercises': [{'name': '深蹲', 'sets': [{'weight': 20, 'reps': 10, 'completed': True}]}],
        'meals': []}}


def long_report():
    base = ('本周训练记录显示两次下肢训练，深蹲和硬拉都有已完成组。'
            '从已保存的数据看，动作选择和组次安排可以执行，但重量进度仍需更多日期验证。'
            '饮食方面只对已确认完整的日期作判断，未确认的日期只说明记录范围。'
            '恢复方面只引用自报疲劳与疼痛，不把主观感受改写成客观结论。'
            '下一次先保持现有安排，再按实际完成情况记录，不用补齐记录来证明计划有效。') * 4
    return {'summary': base, 'training': base, 'nutrition': base, 'recovery': base,
            'reason': base, 'notes': [], 'photoFeedback': []}


class TimezoneBoundary(unittest.TestCase):
    def test_legacy_report_without_zone_accepts_latest_local_today(self):
        now = dt.datetime(2026, 10, 19, 15, 30, tzinfo=dt.timezone.utc)
        value = core.validate_request(report_body('2026-10-20'), now=now)
        self.assertEqual(value['date'], '2026-10-20')

    def test_legacy_report_still_rejects_actual_future(self):
        now = dt.datetime(2026, 10, 19, 15, 30, tzinfo=dt.timezone.utc)
        with self.assertRaises(core.AIError) as caught:
            core.validate_request(report_body('2026-10-21'), now=now)
        self.assertEqual(caught.exception.code, 'future_date')


class NutritionGuardrails(unittest.TestCase):
    def test_numeric_prescription_in_report_notes_is_rejected(self):
        request = {'kind': 'report', 'payload': {'coaching_version': 1,
                                                 'nutritionTarget': {'generalGuidanceOnly': True}}}
        result = long_report()
        core.validate_coaching(request, result)
        result['notes'] = ['建议每天摄入1500千卡，蛋白质控制在120克。']
        with self.assertRaises(ValueError):
            core.validate_coaching(request, result)

    def test_numeric_prescription_in_weekly_photo_feedback_is_rejected(self):
        request = {'kind': 'weekly_review', 'payload': {'coaching_version': 1,
                                                        'nutritionTarget': {'generalGuidanceOnly': True}}}
        result = long_report()
        core.validate_coaching(request, result)
        result['photoFeedback'] = ['每天摄入1500千卡更容易看到变化。']
        with self.assertRaises(ValueError):
            core.validate_coaching(request, result)


class PerAccountAdmission(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = server.JobStore(Path(self.tmp.name) / 'jobs.sqlite3')
        self.owner = 'a' * 64

    def tearDown(self):
        self.tmp.cleanup()

    def test_one_owner_cannot_hold_the_global_queue(self):
        self.store.update_settings({'account_pending_limit': 2, 'pending_limit': 100})
        self.store.create(str(uuid.uuid4()), food_request(), quota_owner=self.owner)
        self.store.create(str(uuid.uuid4()), food_request(), quota_owner=self.owner)
        with self.assertRaises(core.AIError) as caught:
            self.store.create(str(uuid.uuid4()), food_request(), quota_owner=self.owner)
        self.assertEqual(caught.exception.code, 'capacity')
        other = 'b' * 64
        self.store.create(str(uuid.uuid4()), food_request(), quota_owner=other)

    def test_retry_respects_the_same_per_account_limit(self):
        self.store.update_settings({'account_pending_limit': 1, 'pending_limit': 100})
        first = str(uuid.uuid4())
        self.store.create(first, food_request(), quota_owner=self.owner)
        self.store.fail(first, core.AIError('synthetic', 'fixture'), 3)
        self.store.create(str(uuid.uuid4()), food_request(), quota_owner=self.owner)
        with self.assertRaises(core.AIError):
            self.store.retry(first, quota_owner=self.owner)


class AttemptTelemetry(unittest.TestCase):
    def test_log_failure_does_not_discard_a_valid_result(self):
        providers = [core.Provider('longcat', 'https://example.invalid', 'fixture', 'synthetic', 60, True, True, 10)]
        transport = lambda provider, messages, limit: (plan_result(), {})
        router = core.Router(providers, transport)

        def broken_log(_event):
            raise sqlite3.OperationalError('database is locked')

        value, name, _ = router.run(plan_request(), broken_log)
        self.assertEqual(name, 'longcat')
        self.assertEqual(value['kind'], 'plan')


class ProviderCircuit(unittest.TestCase):
    def providers(self, key='synthetic'):
        return [core.Provider(n, 'https://example.invalid', 'fixture', key, 60, True, True, 10)
                for n in ('longcat', 'mimo')]

    def test_credential_change_clears_open_circuit(self):
        router = core.Router(self.providers())
        for _ in range(3):
            router.record(router.providers[0], core.AIError('upstream_timeout', 'fixture', True, True))
        self.assertFalse(router.acquire(router.providers[0]))
        router.replace_providers(self.providers(key='corrected'))
        self.assertTrue(router.acquire(router.providers[0]))


class ScheduleProposals(unittest.TestCase):
    def request(self):
        return {'date': '2026-10-15', 'payload': {
            'proposal_allowed': True,
            'upcoming': [{'date': '2026-10-16'}, {'date': '2026-10-17'}]}}

    def clean(self, moves):
        helpers = (str, lambda value, *_: value, dt.date.fromisoformat)
        return clean_schedule_proposal(self.request(), {'moves': moves}, helpers)

    def test_move_cannot_overwrite_an_existing_session(self):
        with self.assertRaises(ValueError):
            self.clean([{'from': '2026-10-16', 'to': '2026-10-17'}])

    def test_move_cannot_chain_onto_another_moves_source(self):
        with self.assertRaises(ValueError):
            self.clean([{'from': '2026-10-16', 'to': '2026-10-18'},
                        {'from': '2026-10-18', 'to': '2026-10-20'}])

    def test_simple_move_still_allowed(self):
        value = self.clean([{'from': '2026-10-16', 'to': '2026-10-18'}])
        self.assertEqual(value['moves'], [{'from': '2026-10-16', 'to': '2026-10-18'}])


class ExerciseCatalogGuards(unittest.TestCase):
    def test_non_dict_instruction_steps_do_not_crash_detail(self):
        import os
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as folder:
            fixture = Path(folder) / 'exercises.json'
            fixture.write_text('[]', encoding='utf-8')
            with patch.dict(os.environ, {'EXERCISES_JSON': str(fixture)}):
                spec = importlib.util.spec_from_file_location('exercise_api', ROOT / 'exercise-server' / 'api.py')
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
        item = {'id': '0001', 'name': 'Squat', 'instructions': {'en': 'Stand tall.'},
                'instruction_steps': ['not-a-dict']}
        value = module.detail(item, 'en')
        self.assertEqual(value['instruction_steps'], [])


if __name__ == '__main__':
    unittest.main()
