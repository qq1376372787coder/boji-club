"""Batch 2 AI reliability regressions: retryable outages, probe cleanup, fallback and output guards."""
import datetime as dt
import http.client
import json
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
sys.path.insert(0, str(ROOT / 'tests'))
import ai_core as core
import server
from test_backend_v2 import request as plan_request, result as plan_result
from test_backend_offline import weekly_request, weekly_result
from test_experience_v36 import modern


FIXED_NOW = dt.datetime(2026, 10, 19, 4, 30, tzinfo=dt.timezone.utc)  # 2026-10-19 12:30 Asia/Shanghai
SHANGHAI_TODAY = '2026-10-19'


def daily_request():
    return core.validate_request({
        'kind': 'report',
        'date': '2026-09-30',
        'payload': {'exercises': [{'name': '深蹲', 'sets': [{'weight': 20, 'reps': 10, 'completed': True}]}], 'meals': []},
    })


def daily_result(value='记录正常。'):
    return {'kind': 'report', 'summary': value, 'training': value, 'nutrition': value, 'recovery': value, 'notes': []}


def coach_request(date='2020-01-15'):
    return {
        'kind': 'coach',
        'date': date,
        'payload': {
            'version': 1,
            'conversation_id': '00000000-0000-4000-8000-000000000002',
            'question': '这次训练下一次需要注意什么？',
            'history': [],
            'days': [{'date': date, 'payload': {
                'exercises': [{'name': '深蹲', 'sets': [{'weight': 20, 'reps': 10, 'completed': True}]}],
                'meals': [], 'training_confirmed': True, 'meals_complete': False,
            }}],
            '_routing_version': 2,
        },
    }


def coach_result(answer=None):
    answer = answer or ('根据 1 月 15 日已登记的一组深蹲，先核对实际重量与次数；这里只能看到完成登记，'
                        '不能据此判断动作标准或力量增长。下一次继续记录相同动作的实际表现，再作比较。')
    return {'kind': 'coach', 'notes': [], 'coach': {'answer': answer, 'source_ids': ['day/2020-01-15'], 'actions': []}}


class Batch2Reliability(unittest.TestCase):
    def providers(self, names=(('deepseek', 10), ('minimax', 20))):
        return [core.Provider(name, 'https://example.invalid', 'fixture', 'synthetic-key', 60, True, True, priority)
                for name, priority in names]
    def routed_plan(self):
        value=plan_request();value['payload']['_routing_version']=3;return value
    def ordered_router(self, transport):
        router=core.Router(self.providers(),transport)
        router.routing_metrics.order=lambda providers,request:sorted(providers,key=lambda p:p.priority)
        return router

    # 1. Every provider transiently failed -> retryable all_unavailable, job backoff.
    def test_all_transient_provider_failures_are_retryable(self):
        seen = []
        def transport(provider, *args):
            seen.append(provider.name)
            raise core.AIError('upstream_429', 'synthetic', True, True)
        with self.assertRaises(core.AIError) as caught:
            self.ordered_router(transport).run(self.routed_plan())
        self.assertEqual(caught.exception.code, 'all_unavailable')
        self.assertTrue(caught.exception.retryable)
        self.assertEqual(seen, ['deepseek', 'minimax'])

    def test_all_providers_circuit_open_is_retryable(self):
        now = [1000.0]
        providers = self.providers()
        router = core.Router(providers, lambda *_: self.fail('transport must not run'), clock=lambda: now[0])
        for provider in providers:
            for _ in range(3):
                router.record(provider, core.AIError('upstream_timeout', 'synthetic', True, True))
        with self.assertRaises(core.AIError) as caught:
            router.run(plan_request())
        self.assertEqual(caught.exception.code, 'all_unavailable')
        self.assertTrue(caught.exception.retryable)

    def test_all_unavailable_job_backoff_but_invalid_output_and_timeout_terminal(self):
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            store.create('transient-fixture', plan_request())
            store.fail('transient-fixture', core.AIError('all_unavailable', 'synthetic', True), 1)
            value = store.get('transient-fixture')
            self.assertEqual(value['status'], 'retrying')
            self.assertGreater(value['retry_after'], 0)
            store.fail('transient-fixture', core.AIError('all_unavailable', 'synthetic', True), 2)
            self.assertEqual(store.get('transient-fixture')['status'], 'retrying')
            store.fail('transient-fixture', core.AIError('all_unavailable', 'synthetic', True), 3)
            self.assertEqual(store.get('transient-fixture')['status'], 'failed')
            for code in ('invalid_output', 'task_timeout'):
                store.create('terminal-' + code, plan_request())
                store.fail('terminal-' + code, core.AIError(code, 'synthetic', True), 1)
                self.assertEqual(store.get('terminal-' + code)['status'], 'failed')

    # 2. Unexpected transport/storage exceptions must not strand a half-open probe.
    def test_unexpected_transport_errors_do_not_strand_provider(self):
        errors = (http.client.IncompleteRead(b''), http.client.BadStatusLine(''), sqlite3.OperationalError('synthetic'))
        for error in errors:
            with self.subTest(error=type(error).__name__):
                now = [1000.0]
                provider = core.Provider('mimo', 'https://example.invalid', 'fixture', 'synthetic-key')
                def transport(provider, *args, error=error):
                    raise error
                router = core.Router([provider], transport, clock=lambda: now[0])
                for _ in range(3):
                    router.record(provider, core.AIError('upstream_timeout', 'synthetic', True, True))
                now[0] = 1061.0
                with self.assertRaises(core.AIError) as caught:
                    router.run(plan_request())
                self.assertEqual(caught.exception.code, 'all_unavailable')
                self.assertTrue(caught.exception.retryable)
                self.assertFalse(router.health['mimo']['probe'])
                now[0] = 1122.0
                self.assertTrue(router.acquire(provider))

    def test_finally_clears_probe_when_validation_escapes(self):
        now = [1000.0]
        provider = core.Provider('mimo', 'https://example.invalid', 'fixture', 'synthetic-key')
        router = core.Router([provider], lambda *_: (plan_result(), {}), clock=lambda: now[0])
        for _ in range(3):
            router.record(provider, core.AIError('upstream_timeout', 'synthetic', True, True))
        now[0] = 1061.0
        with patch.object(core, 'validate_result', side_effect=RuntimeError('synthetic')):
            with self.assertRaises(RuntimeError):
                router.run(plan_request())
        self.assertFalse(router.health['mimo']['probe'])
        self.assertTrue(router.acquire(provider))

    def test_provider_replaced_mid_run_does_not_raise_on_record(self):
        provider = core.Provider('mimo', 'https://example.invalid', 'fixture', 'synthetic-key')
        router = core.Router([provider], lambda *_: (plan_result(), {}))
        router.replace_providers([])
        router.record(provider, core.AIError('upstream_timeout', 'synthetic', True, True))
        router.clear_probe(provider)
        self.assertFalse(router.acquire(provider))

    # 3. Provider-specific refusal falls through; all refuse is distinct/terminal.
    def test_content_filter_falls_back_to_next_provider(self):
        seen = []
        def transport(provider, *args):
            seen.append(provider.name)
            if provider.name == 'deepseek':
                raise core.AIError('request_blocked', 'synthetic', False, True)
            return plan_result(), {}
        value, provider, _ = self.ordered_router(transport).run(self.routed_plan())
        self.assertEqual(seen, ['deepseek', 'minimax'])
        self.assertEqual(provider, 'minimax')
        self.assertEqual(value['kind'], 'plan')

    def test_call_provider_marks_content_filter_and_refusal_as_fallback(self):
        class Response:
            def __init__(self, payload):
                self.chunks = [payload, b'']
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read1(self, *args):
                return self.chunks.pop(0)
        class Opener:
            def __init__(self, payload):
                self.payload = payload
            def open(self, *args, **kwargs):
                return Response(self.payload)
        choices = ({'finish_reason': 'content_filter', 'message': {'content': ''}},
                   {'finish_reason': 'stop', 'message': {'content': '', 'refusal': 'no'}})
        for choice in choices:
            payload = json.dumps({'choices': [choice]}).encode()
            with patch.object(core.urllib.request, 'build_opener', return_value=Opener(payload)):
                with self.assertRaises(core.AIError) as caught:
                    core.call_provider(core.Provider('mimo', 'https://example.invalid', 'fixture', 'synthetic-key'), [], 32)
            self.assertEqual(caught.exception.code, 'request_blocked')
            self.assertTrue(caught.exception.fallback)
            self.assertFalse(caught.exception.retryable)

    def test_all_providers_refusing_is_terminal_request_blocked(self):
        seen = []
        def transport(provider, *args):
            seen.append(provider.name)
            raise core.AIError('request_blocked', 'synthetic', False, True)
        with self.assertRaises(core.AIError) as caught:
            self.ordered_router(transport).run(self.routed_plan())
        self.assertEqual(caught.exception.code, 'request_blocked')
        self.assertFalse(caught.exception.retryable)
        self.assertFalse(caught.exception.fallback)
        self.assertEqual(seen, ['deepseek', 'minimax'])

    def test_refusal_plus_transient_failure_stays_retryable(self):
        def transport(provider, *args):
            if provider.name == 'deepseek':
                raise core.AIError('request_blocked', 'synthetic', False, True)
            raise core.AIError('upstream_429', 'synthetic', True, True)
        with self.assertRaises(core.AIError) as caught:
            self.ordered_router(transport).run(self.routed_plan())
        self.assertEqual(caught.exception.code, 'all_unavailable')
        self.assertTrue(caught.exception.retryable)

    # 4. reason must also be sanitized when a weekly candidate is blocked.
    def test_weekly_reason_cannot_keep_blocked_dose_prescription(self):
        raw = weekly_result()
        raw.update(decision='keep', sessions=[])
        raw['reason'] = '本周记录完整。下周把卧推加到30公斤，做4组，每组8次；深蹲也加到40公斤做5组。'
        output = core.validate_result(core.validate_request(weekly_request()), raw)
        self.assertEqual(output['decision'], 'keep')
        self.assertIn('本周记录完整', output['reason'])
        self.assertNotIn('30公斤', output['reason'])
        self.assertNotIn('4组', output['reason'])
        self.assertNotIn('40公斤', output['reason'])

    # 5. Negated/conditional safety sentences survive prescription stripping.
    def test_analysis_text_preserves_negated_and_conditional_safety(self):
        for sentence in ('如果疼痛，不要做3组。',
                         '不要做3组，先确认疼痛来源。',
                         '请勿尝试4组。',
                         '不能做3组。',
                         '不要补上上肢动作。'):
            with self.subTest(sentence=sentence):
                self.assertEqual(core.analysis_text(sentence, True), sentence)
        self.assertEqual(core.analysis_text('已登记30公斤8次。下次尝试做满3组，每组8次。'), '已登记30公斤8次。')
        fallback = core.analysis_text('下次尝试做满3组。')
        self.assertNotIn('记录不足', fallback)
        self.assertNotIn('不足以支持', fallback)

    # 6. Weekly baseline uses only explicitly confirmed training.
    def test_weekly_baseline_excludes_unconfirmed_completed_sets(self):
        raw = modern(training=2, food=0, scope='training', planned=3)
        for row in raw['payload']['days'][2:]:
            row['payload']['exercises'] = [{'name': '深蹲', 'sets': [{'weight': 20, 'reps': 10, 'completed': True}] * 20}]
        value = core.validate_request(raw)
        self.assertEqual(value['payload']['readiness']['confirmedTrainingDays'], 2)
        output = core.validate_result(value, weekly_result())
        self.assertEqual(output['decision'], 'insufficient')
        self.assertEqual(output['sessions'], [])
        self.assertIn('2个有完成组的日期', output['reason'])
        self.assertIn('4组训练', output['reason'])

    # 7. Future dates are rejected when the client's zone declares them future.
    def test_future_dates_rejected_for_report_coach_and_weekly(self):
        tomorrow = '2026-10-20'
        for kind in ('report', 'coach', 'weekly_review'):
            with self.subTest(kind=kind):
                with self.assertRaises(core.AIError) as caught:
                    core.validate_request({'kind': kind, 'date': tomorrow,
                                           'payload': {'timeZone': 'Asia/Shanghai'}}, now=FIXED_NOW)
                self.assertEqual(caught.exception.code, 'future_date')
        today = {'kind': 'report', 'date': SHANGHAI_TODAY, 'payload': {
            'exercises': [{'name': '深蹲', 'sets': [{'weight': 20, 'reps': 10, 'completed': True}]}], 'meals': []}}
        self.assertEqual(core.validate_request(today, now=FIXED_NOW)['date'], SHANGHAI_TODAY)

    def test_coach_future_uses_client_zone_and_rejects_actual_future(self):
        # R11 regression: at UTC 15:30 on 2026-10-19:
        # Tokyo (UTC+9) is 00:30 on 2026-10-20 -> 2026-10-20 is valid today.
        now = dt.datetime(2026, 10, 19, 15, 30, tzinfo=dt.timezone.utc)
        report_payload = {'exercises': [{'name': '深蹲', 'sets': [{'weight': 20, 'reps': 10, 'completed': True}]}], 'meals': [], 'timeZone': 'Asia/Tokyo'}
        body = {'kind': 'report', 'date': '2026-10-20', 'payload': report_payload}
        req = core.validate_request(body, now=now)
        self.assertEqual(req['date'], '2026-10-20')
        # Tomorrow in Tokyo (2026-10-21) must still be rejected.
        future_body = {'kind': 'report', 'date': '2026-10-21',
                       'payload': {'exercises': [], 'meals': [], 'timeZone': 'Asia/Tokyo'}}
        with self.assertRaises(core.AIError) as caught:
            core.validate_request(future_body, now=now)
        self.assertEqual(caught.exception.code, 'future_date')
        # Hawaii (UTC-10) is 05:30 on 2026-10-19 -> 2026-10-20 is future in Honolulu!
        honolulu_body = {'kind': 'report', 'date': '2026-10-20',
                         'payload': {'exercises': [], 'meals': [], 'timeZone': 'Pacific/Honolulu'}}
        with self.assertRaises(core.AIError) as caught:
            core.validate_request(honolulu_body, now=now)
        self.assertEqual(caught.exception.code, 'future_date')
        # Invalid timezone string must be rejected
        invalid_tz = {'kind': 'report', 'date': '2026-10-20',
                      'payload': {'exercises': [], 'meals': [], 'timeZone': 'Invalid/Zone'}}
        with self.assertRaises(core.AIError) as caught:
            core.validate_request(invalid_tz, now=now)
        self.assertEqual(caught.exception.code, 'invalid_request')

    def test_http_rejects_future_report_before_queue(self):
        tomorrow = (dt.datetime.now(ZoneInfo('Asia/Shanghai')).date() + dt.timedelta(days=1)).isoformat()
        with tempfile.TemporaryDirectory() as folder:
            store = server.JobStore(Path(folder) / 'jobs.sqlite3')
            http = server.make_server(store, core.Router([]), 'batch2-test-token-1234567890', port=0)
            threading.Thread(target=http.serve_forever, daemon=True).start()
            try:
                body = {'id': str(uuid.uuid4()), 'kind': 'report', 'date': tomorrow,
                        'payload': {'timeZone': 'Asia/Shanghai'}}
                request = urllib.request.Request(
                    'http://127.0.0.1:' + str(http.server_address[1]) + '/v1/jobs',
                    data=json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer batch2-test-token-1234567890', 'Content-Type': 'application/json'})
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request, timeout=5)
                self.assertEqual(caught.exception.code, 400)
                self.assertEqual(json.loads(caught.exception.read())['code'], 'future_date')
                with store.connect() as db:
                    self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
            finally:
                http.shutdown()
                http.server_close()

    # 8. Output validation rejects URLs, internal fields, markup and garbage,
    #    without blocking ordinary Chinese prose with units or acronyms.
    def test_output_validation_rejects_urls_markup_fields_and_garbage(self):
        cases = (
            ('记录正常。请访问 https://example.com 查看。', 'output_url'),
            ('记录正常。见 www.example.com。', 'output_url'),
            ('记录正常。<script>alert(1)</script>', 'output_markup'),
            ('记录正常。```json\n{}\n```', 'output_markup'),
            ('记录正常。session_id 为 abc。', 'output_internal_fields'),
            ('记录正常。completed 为 true。', 'output_internal_fields'),
            ('This is only English prose about training.', 'output_language'),
            ('记录正常。\x00', 'output_characters'),
            ('记录正常。\ufffd', 'output_characters'),
        )
        for value, reason in cases:
            with self.subTest(value=value):
                with self.assertRaises(core.AIError) as caught:
                    core.validate_result(daily_request(), daily_result(value))
                self.assertEqual(caught.exception.code, 'invalid_output')
                self.assertEqual(caught.exception.reason, reason)

    def test_output_validation_applies_to_weekly_and_coach(self):
        weekly = weekly_result()
        weekly.update(decision='keep', sessions=[])
        weekly['summary'] = '本周记录完整。详情见 https://example.com。'
        with self.assertRaises(core.AIError) as caught:
            core.validate_result(core.validate_request(weekly_request()), weekly)
        self.assertEqual(caught.exception.reason, 'output_url')

        weekly = weekly_result()
        weekly.update(decision='keep', sessions=[])
        weekly['training'] = 'This week the training was consistent.'
        with self.assertRaises(core.AIError) as caught:
            core.validate_result(core.validate_request(weekly_request()), weekly)
        self.assertEqual(caught.exception.reason, 'output_language')

        weekly = weekly_result()
        weekly.update(decision='keep', sessions=[])
        weekly['reason'] = '记录完整，继续观察。workout_sessions 显示两次训练。'
        with self.assertRaises(core.AIError) as caught:
            core.validate_result(core.validate_request(weekly_request()), weekly)
        self.assertEqual(caught.exception.reason, 'output_internal_fields')

        request = core.validate_request(coach_request())
        with self.assertRaises(core.AIError) as caught:
            core.validate_result(request, coach_result('记录已收到，请访问 https://example.com 查看详细安排。这里不能判断动作标准。'))
        self.assertEqual(caught.exception.reason, 'output_url')
        with self.assertRaises(core.AIError) as caught:
            core.validate_result(request, coach_result('记录已收到。session_id 显示完成。这里不能判断动作标准或力量增长。'))
        self.assertEqual(caught.exception.reason, 'output_internal_fields')

    def test_normal_prose_with_units_and_acronyms_is_not_blocked(self):
        value = '已登记 3 组，每组 10 次，重量 30 kg；本周 RPE 8，BMI 22.5。记录完整，继续按计划执行。'
        output = core.validate_result(daily_request(), daily_result(value))
        self.assertEqual(output['summary'], value)
        weekly = core.validate_result(core.validate_request(weekly_request()), weekly_result())
        self.assertEqual(weekly['decision'], 'adjust')
        coach = core.validate_result(core.validate_request(coach_request()), coach_result())
        self.assertEqual(coach['kind'], 'coach')


if __name__ == '__main__':
    unittest.main(verbosity=2)
