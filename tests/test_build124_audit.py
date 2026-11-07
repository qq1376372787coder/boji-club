import copy
import tempfile
import unittest
import uuid
from unittest.mock import patch
from pathlib import Path

from ai_core import AIError, validate_request, validate_result, messages_for
from server import JobStore
from test_coach import request, answer


class Audit124Tests(unittest.TestCase):
    def test_weight_exact_intents_units_and_negations(self):
        from fast_intent import weight_input
        for text, expected in [('记70公斤',70),('请记录今天早上体重72.3公斤',72.3),('今天早上体重70.2公斤，记录',70.2),('登记体重154磅',69.9),('记录140斤',70),('记录70.25公斤',70.3)]:
            self.assertEqual(weight_input(text),expected)
        self.assertEqual(weight_input('记录体重154','lb'),69.9)
        for text in ('记70','我有点累','不要记录70公斤','昨天体重70公斤，记录','体重70公斤','“记录70公斤”','如果记录70公斤','记录大概70公斤','记录10公斤'):
            self.assertIsNone(weight_input(text),text)

    def test_weight_fast_path_uses_whitelisted_call_and_no_model(self):
        from ai_core import Router
        body=request()
        body['payload']['question']='记70公斤。'
        body['payload']['capabilities']=[{'capability':'body.record_weight','description':'登记体重','input':{'type':'object','properties':{'date':{'type':'string'},'kilograms':{'type':'number'}},'required':['date','kilograms']}}]
        value,provider,_=Router([],transport=lambda *a:self.fail('unexpected model call')).run(validate_request(body))
        self.assertEqual(provider,'deterministic')
        self.assertEqual(value['coach']['capability_calls'][0]['input']['kilograms'],70)

    def referenced(self, kind='plan_day'):
        body = request()
        body['payload']['days'] = []
        body['payload']['_references'] = [{'id': 'ref/1', 'kind': kind,
            'from': '2020-01-16', 'to': '2020-01-20', 'label': '引用记录',
            'source_version': 'a' * 64, 'snapshot': [{'date': '2020-01-16'}]}]
        return validate_request(body)

    def result(self, kind='training', date='2020-01-16'):
        out = answer()
        out['coach']['source_ids'] = ['ref/1']
        out['coach']['actions'] = [{'type': kind, 'date': date}]
        return out

    def test_future_plan_reference_navigation(self):
        for kind in ('training', 'plans'):
            value = validate_result(self.referenced(), self.result(kind))
            self.assertEqual(value['coach']['actions'][0]['date'], '2020-01-16')

    def test_reference_range_does_not_authorise_invented_date(self):
        with self.assertRaises(AIError):
            validate_result(self.referenced(), self.result(date='2020-01-19'))

    def test_plan_reference_does_not_supply_body_or_nutrition_facts(self):
        for kind in ('body', 'nutrition', 'daily', 'schedule_shift'):
            with self.assertRaises(AIError):
                validate_result(self.referenced(), self.result(kind))

    def test_typed_body_reference_navigation(self):
        self.assertEqual(validate_result(self.referenced('body_range'), self.result('body'))['kind'], 'coach')

    def test_prompt_places_calls_under_coach(self):
        body = request()
        body['payload']['capabilities'] = [{'capability': 'training.get_today',
            'description': '读取训练', 'input': {'type': 'object', 'properties': {}}}]
        prompt = messages_for(validate_request(body))[0]['content']
        self.assertIn('coach 对象内填写 "capability_calls"', prompt)

    def usage(self, usages, provider='deepseek'):
        with tempfile.TemporaryDirectory() as directory:
            store = JobStore(Path(directory) / 'jobs.sqlite3')
            job = str(uuid.uuid4())
            store.create(job, validate_request(request()))
            for usage in usages:
                store.attempt(job, {'provider': provider, 'model': 'fixture', 'outcome': 'success',
                    'duration_ms': 1, 'usage': usage})
            store.complete(job, validate_result(validate_request(request()), answer()), provider, 'fixture')
            return store.get(job)['usage']

    def test_usage_aggregates_fallback_attempts(self):
        self.assertEqual(self.usage([{'prompt_tokens': 3, 'completion_tokens': 4},
            {'input_tokens': 5, 'output_tokens': 6}]),
            {'attempt_count': 2, 'prompt_tokens': 8, 'completion_tokens': 10})

    def test_missing_usage_is_unknown_instead_of_zero(self):
        self.assertIsNone(self.usage([{}])['prompt_tokens'])

    def test_deterministic_path_reports_zero(self):
        self.assertEqual(self.usage([], 'deterministic')['prompt_tokens'], 0)

    def test_unknown_provider_usage_cannot_invent_token_counts(self):
        self.assertIsNone(self.usage([{'prompt_tokens': True, 'completion_tokens': -1}])['completion_tokens'])

    def test_incomplete_prefix_is_withheld_until_complete_validation(self):
        from ai_core import Router, Provider
        emitted = []
        out = answer()
        out['coach']['answer'] = '123456789012 ' + out['coach']['answer']
        def transport(provider, messages, limit, on_text=None):
            on_text('123456789012')
            self.assertFalse(any(kind == 'delta' for kind, text in emitted))
            on_text(out['coach']['answer'])
            return out, {'prompt_tokens': 1, 'completion_tokens': 2}
        with patch('ai_core.call_provider', transport):
            router = Router([Provider('deepseek', 'https://example.test', 'fixture', 'fixture')], transport=transport)
            value, _, _ = router.run(validate_request(request()), on_text=lambda k, t: emitted.append((k,t)))
        self.assertEqual(value['coach']['answer'], out['coach']['answer'])
        self.assertTrue(any(kind == 'delta' for kind, text in emitted))


if __name__ == '__main__':
    unittest.main()
