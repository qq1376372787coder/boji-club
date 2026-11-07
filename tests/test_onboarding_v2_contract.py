"""Fast, synthetic contract tests for the restricted onboarding assistant.

No network, database, provider or real health data. These are ordinary build
checks; concurrency, migration and end-to-end HTTP acceptance remain for the
independent audit.
"""
import datetime as dt
import sys
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))

import ai_core  # noqa: E402
import coach_core  # noqa: E402
import onboarding_core  # noqa: E402

HELPERS = (ai_core.text, ai_core.number, ai_core.sequence, ai_core.iso_date, ai_core.validate_request)
TODAY = dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date().isoformat()
SESSION = '00f975d1-a20a-40ae-97c2-51dce60e5647'
CONVERSATION = '8b6e1f50-2a2b-4f31-9bc0-23c42cd4a7bb'


def context(question, allowed=None):
    return {
        'schema_version': 1, 'prompt_version': onboarding_core.PROMPT_VERSION,
        'task_kind': 'plan_create', 'session_id': SESSION, 'session_revision': 2,
        'profile_revision': 0, 'confirmed_facts': {}, 'draft_fields': {},
        'skipped_fields': [], 'required_missing_fields': ['goal'],
        'allowlisted_fields': allowed or ['goal', 'venue', 'equipment', 'days_per_week', 'session_minutes'],
        'allowed_source_ids': [], 'safety_blocked': False, 'safety_message': None,
        'question': question,
    }


def raw_result(question, candidates, answer='这些条件我先记为待核对资料。你之前有规律做过力量训练吗？'):
    return {'kind': 'coach', 'notes': [], 'coach': {
        'answer': answer, 'source_ids': [], 'actions': [],
        'onboarding': {'schema_version': 1, 'candidates': candidates},
    }}


def request_for(question, ctx):
    return {'kind': 'coach', 'date': TODAY, 'payload': {
        'version': 1, 'conversation_id': CONVERSATION, 'question': question,
        'history': [], 'days': [], 'upcoming': [], 'purpose': 'onboarding_assist',
        '_onboarding_context': ctx,
    }}


class OnboardingOutputContract(unittest.TestCase):
    def test_multi_field_extraction_is_accepted(self):
        question = '我想增肌，在家有哑铃，一周三次，每次半小时。'
        candidates = [
            {'field': 'goal', 'value': '增肌塑形', 'unit': None, 'evidence_quote': '我想增肌'},
            {'field': 'venue', 'value': '在家', 'unit': None, 'evidence_quote': '在家'},
            {'field': 'equipment', 'value': ['哑铃'], 'unit': None, 'evidence_quote': '有哑铃'},
            {'field': 'days_per_week', 'value': 3, 'unit': 'days_per_week', 'evidence_quote': '一周三次'},
            {'field': 'session_minutes', 'value': 30, 'unit': 'minutes', 'evidence_quote': '每次半小时'},
        ]
        result = coach_core.clean_result(request_for(question, context(question)), raw_result(question, candidates),
                                         (ai_core.text, ai_core.sequence, ai_core.iso_date))
        self.assertEqual(len(result['coach']['onboarding']['candidates']), 5)
        self.assertEqual(result['coach']['prompt_version'], onboarding_core.PROMPT_VERSION)

    def test_quote_not_from_this_turn_is_rejected(self):
        question = '我想增肌。'
        candidate = [{'field': 'goal', 'value': '增肌塑形', 'unit': None, 'evidence_quote': '没有说过'}]
        with self.assertRaises(ValueError):
            onboarding_core.clean_result(request_for(question, context(question)), raw_result(question, candidate),
                                         (ai_core.text, ai_core.sequence))

    def test_model_cannot_add_trust_fields(self):
        question = '我想增肌。'
        candidate = [{'field': 'goal', 'value': '增肌塑形', 'unit': None, 'evidence_quote': '我想增肌', 'confirmed': True}]
        with self.assertRaises(ValueError):
            onboarding_core.clean_result(request_for(question, context(question)), raw_result(question, candidate),
                                         (ai_core.text, ai_core.sequence))

    def test_limitation_clearance_is_not_accepted(self):
        question = '我没有不适。'
        candidate = [{'field': 'limitations', 'value': '无', 'unit': None, 'evidence_quote': '我没有不适'}]
        with self.assertRaises(ValueError):
            onboarding_core.clean_result(request_for(question, context(question, ['limitations'])),
                                         raw_result(question, candidate),
                                         (ai_core.text, ai_core.sequence))

    def test_short_onboarding_answer_allowed_but_long_answer_rejected(self):
        question = '我想增肌。'
        candidate = [{'field': 'goal', 'value': '增肌塑形', 'unit': None, 'evidence_quote': '我想增肌'}]
        long_answer = '这些条件我先记为待核对资料。' * 30
        with self.assertRaises(ValueError):
            onboarding_core.clean_result(request_for(question, context(question)),
                                         raw_result(question, candidate, long_answer),
                                         (ai_core.text, ai_core.sequence))

    def test_server_safety_output_needs_no_candidates(self):
        question = '我胸痛还能练吗？'
        raw = {'kind': 'coach', 'notes': [], 'coach': {'answer': '请先停止训练并尽快寻求医疗评估。', 'source_ids': [], 'actions': []}}
        result = coach_core.clean_result(request_for(question, context(question)), raw,
                                         (ai_core.text, ai_core.sequence, ai_core.iso_date), server_safety=True)
        self.assertTrue(result['coach']['safety_blocked'])
        self.assertEqual(result['coach']['onboarding']['candidates'], [])

    def test_onboarding_purpose_without_server_context_is_rejected(self):
        raw = {'version': 1, 'conversation_id': CONVERSATION, 'question': '我想增肌', 'history': [],
               'days': [], 'purpose': 'onboarding_assist'}
        with self.assertRaises(ValueError):
            coach_core.clean_request(raw, TODAY, HELPERS)

    def test_context_continue_cannot_invent_sources(self):
        source = {'type': 'report', 'job_id': CONVERSATION, 'version': '2026-10-25 08:00:00',
                  'content': {'summary': '服务端来源摘要'}}
        request = {'kind': 'coach', 'date': TODAY, 'payload': {
            'version': 1, 'conversation_id': CONVERSATION, 'question': '这份报告说明什么？',
            'history': [], 'days': [], 'upcoming': [], 'purpose': 'context_continue',
            '_context_source': source,
        }}
        raw = {'kind': 'coach', 'notes': [], 'coach': {'answer': '这份来源只覆盖该快照日期，不能代表之后的新记录；缺失记录也不当作零。', 'source_ids': ['day/2026-10-25'], 'actions': []}}
        with self.assertRaises(ValueError):
            coach_core.clean_result(request, raw, (ai_core.text, ai_core.sequence, ai_core.iso_date))


class V2PlanRequestContract(unittest.TestCase):
    def body(self, **overrides):
        profile = {
            'goal': '增肌塑形', 'experience': '新手', 'venue': '在家', 'focus': '全身',
            'trainingDays': [2, 4, 6], 'sessionMinutes': 30, 'equipment': ['哑铃'], 'ageGroup': 'adult',
        }
        profile.update(overrides.pop('profile', {}))
        return {'kind': 'generate_plan', 'date': TODAY, 'payload': {
            'profile': profile, '_v2_profile': True, '_v2_schema_version': 1,
            'timeZone': 'Asia/Shanghai', 'plan_days': 7,
        }}

    def test_unknown_body_numbers_remain_unknown_and_days_are_not_auto_selected(self):
        request = ai_core.validate_request(self.body())
        profile = request['payload']['profile']
        self.assertIsNone(profile['age'])
        self.assertIsNone(profile['height'])
        self.assertIsNone(profile['weight'])
        self.assertEqual(profile['trainingDays'], [2, 4, 6])
        self.assertEqual(profile['daysPerWeek'], 3)
        self.assertTrue(request['payload']['_v2_profile'])

    def test_missing_training_days_is_rejected_instead_of_defaulting(self):
        with self.assertRaises(ai_core.AIError):
            ai_core.validate_request(self.body(profile={'trainingDays': []}))

    def test_home_equipment_is_required(self):
        with self.assertRaises(ai_core.AIError):
            ai_core.validate_request(self.body(profile={'equipment': []}))


class MealDraftCorrectionContract(unittest.TestCase):
    def body(self, unit='个'):
        return {'kind': 'food', 'date': TODAY, 'payload': {
            'source': 'text', 'description': '香蕉改为苹果，这是一根不是 100g',
            'meal_category': '午餐', 'timeZone': 'Asia/Shanghai',
            'draft_context': {
                'draft_id': CONVERSATION, 'revision': 2, 'name': '香蕉', 'category': '午餐',
                'components': [{'name': '香蕉', 'amount': 1, 'unit': unit, 'calories': 90}],
                'fraction': 1, 'nutrition_sources': [], 'uncertainty_note': '分量待确认',
            },
        }}

    def test_draft_correction_keeps_units_and_revision(self):
        clean = ai_core.validate_request(self.body())['payload']['draft_context']
        self.assertEqual(clean['draft_id'], CONVERSATION)
        self.assertEqual(clean['components'][0]['unit'], '个')
        self.assertEqual(clean['revision'], 2)

    def test_unknown_unit_is_rejected(self):
        with self.assertRaises(ai_core.AIError):
            ai_core.validate_request(self.body('克'))


class MealDraftFractionContract(unittest.TestCase):
    def request(self):
        body=MealDraftCorrectionContract().body()
        body['payload']['draft_context']['fraction']=0.5
        return ai_core.validate_request(body)

    def result(self):
        return {'kind':'meal','is_food':True,'name':'苹果','notes':[],
                'components':[{'name':'苹果','amount':1,'unit':'个','calories':100,'protein':5,'carbs':11,'fat':4,'basis':'described','details':['大小待核对']}]}

    def test_correction_preserves_fraction_without_rescaling_base_nutrients(self):
        clean=ai_core.validate_result(self.request(),self.result())
        self.assertEqual(clean['consumed_fraction'],0.5)
        self.assertEqual(clean['calories'],100)
        self.assertEqual(clean['components'][0]['unit'],'个')
        self.assertEqual(clean['prompt_version'],'boji.draft_correction.v2')

    def test_explicit_ratio_validated_independently(self):
        result=self.result();result['consumed_fraction']=0.25
        self.assertEqual(ai_core.validate_result(self.request(),result)['consumed_fraction'],0.25)
        for ratio in [-1,1.5,True,float('nan')]:
            result['consumed_fraction']=ratio
            with self.subTest(ratio=ratio),self.assertRaises(ai_core.AIError):
                ai_core.validate_result(self.request(),result)


if __name__ == '__main__':
    unittest.main()
