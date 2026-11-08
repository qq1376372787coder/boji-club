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




class V2CommercialAuditTests(unittest.TestCase):
    def test_card_composer_midnight_rollover_never_expires_before_created(self):
        from zoneinfo import ZoneInfo
        import card_composer
        yesterday = dt.datetime.now(ZoneInfo("Asia/Shanghai")).date() - dt.timedelta(days=1)
        req = {
            "date": yesterday.isoformat(),
            "payload": {
                "version": 1,
                "conversation_id": "11111111-2222-3333-4444-555555555555",
                "question": "今天练什么",
                "history": [],
                "days": [{
                    "date": yesterday.isoformat(),
                    "payload": {
                        "totals": {"completed_sets": 0},
                        "exercises": [{"name": "深蹲", "sets": [{"weight": 60, "reps": 10, "completed": False}] * 4}],
                        "meals": [],
                        "workout_sessions": [],
                    },
                }],
                "upcoming": [],
                "proposal_allowed": False,
                "purpose": "dialogue",
                "timeZone": "Asia/Shanghai",
            },
        }
        helpers = (lambda v, m=3000, allow_empty=False: str(v)[:m], lambda v, maximum, minimum=0: v, None)
        cards = card_composer.compose(req, [{"type": "today_training"}], helpers)
        self.assertEqual(len(cards), 1)
        card = cards[0]
        created_at = dt.datetime.fromisoformat(card["created_at"])
        expires_at = dt.datetime.fromisoformat(card["expires_at"])
        self.assertGreater(expires_at, created_at)

    def test_fitness_intelligence_uses_shanghai_timezone_by_default(self):
        from zoneinfo import ZoneInfo
        import fitness_intelligence
        fi_src = (ROOT / "backend" / "fitness_intelligence.py").read_text(encoding="utf-8")
        features = fitness_intelligence.training_features([], {}, as_of=None)
        expected_today = dt.datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
        self.assertEqual(features["window_end"], expected_today)

    def test_fitness_day_uses_requested_timezone_at_same_instant(self):
        import fitness_intelligence as fi
        instant=dt.datetime(2026,10,28,15,30,tzinfo=dt.timezone.utc)
        self.assertEqual(fi.training_features([],{},now=instant,time_zone='Asia/Shanghai')['window_end'],'2026-10-28')
        self.assertEqual(fi.training_features([],{},now=instant,time_zone='Asia/Tokyo')['window_end'],'2026-10-29')
        self.assertEqual(fi.training_features([],{},as_of=dt.date(2026,10,1),now=instant,time_zone='Asia/Tokyo')['window_end'],'2026-10-01')
        with self.assertRaises(ValueError): fi.training_features([],{},time_zone='Not/AZone')

    def test_admin_config_saves_and_renders_all_12_feature_flags(self):
        app_cfg = (ROOT / "account-server" / "public" / "app-config.php").read_text(encoding="utf-8")
        bootstrap = (ROOT / "account-server" / "admin" / "bootstrap.php").read_text(encoding="utf-8")
        # A-04 后台重构：配置表单从 index.php 迁到 config-view.php，且改为
        # 动态数组渲染（name="<?=$key?>"），静态 name="<flag>" 字符串不复存在。
        config_view = (ROOT / "account-server" / "admin" / "config-view.php").read_text(encoding="utf-8")
        expected_flags = [
            "ai_enabled", "action_system_enabled", "ai_context_references_v1",
            "ai_fast_intent_v1", "ai_router_v3", "ai_streaming_v2",
            "club_enabled", "training_commands", "direct_records",
            "ai_native_home", "onboarding_v2_enabled", "contextual_tips_enabled",
        ]
        for flag in expected_flags:
            self.assertIn(f"'{flag}'", app_cfg)
            self.assertIn(flag, bootstrap)
            self.assertIn(f"'{flag}'", config_view)
        self.assertTrue(
            'name="<?=h($key)?>"' in config_view or 'name="<?=$key?>"' in config_view,
            "config-view 必须动态渲染开关 name")
        self.assertIn("advanced_ai_flags_present", bootstrap)
        self.assertIn("advanced-settings", config_view)
        self.assertNotIn("static $cache = [];", app_cfg)

    def test_admin_redirect_and_transaction_safety_fixes(self):
        stats_php = (ROOT / "account-server" / "admin" / "statistics.php").read_text(encoding="utf-8")
        bootstrap = (ROOT / "account-server" / "admin" / "bootstrap.php").read_text(encoding="utf-8")
        index_php = (ROOT / "account-server" / "admin" / "index.php").read_text(encoding="utf-8")
        self.assertIn("if ($ownsTransaction && $db->inTransaction())", stats_php)
        self.assertIn("$db->rollBack();", stats_php)
        self.assertIn("return_page", bootstrap)
        self.assertIn('name="return_page" value="shipping"', index_php)
        self.assertIn("$kind==='physical'?'gifts':'badges'", bootstrap)

    def test_admin_ui_refactor_theme_and_progressive_tabs(self):
        css = (ROOT / "account-server" / "admin" / "style.css").read_text(encoding="utf-8").lower()
        app_js = (ROOT / "account-server" / "admin" / "app.js").read_text(encoding="utf-8")
        index_php = (ROOT / "account-server" / "admin" / "index.php").read_text(encoding="utf-8")
        self.assertIn("#e3e7f0", css)
        self.assertIn(".subnav-tabs", css)
        self.assertIn(".obs-banner", css)
        self.assertIn(".effect-guide", css)
        self.assertIn("data-tab-group", app_js)
        self.assertIn("typeof document.querySelectorAll !== 'function'", app_js)
        # A-04 重构后分组从 index.php 移入 config-view.php，旧四个分组标签已废弃；
        # 断言现行配置分区标题（结构等价物）。
        config_view = (ROOT / "account-server" / "admin" / "config-view.php").read_text(encoding="utf-8")
        for section in ["App 功能", "新用户体验", "发布记录"]:
            self.assertIn(section, config_view)

    def test_ios_feature_flags_and_crash_safety_guards(self):
        account_swift = (ROOT / "BojiClub" / "AccountService.swift").read_text(encoding="utf-8")
        shell_swift = (ROOT / "BojiClub" / "ClubAIShell.swift").read_text(encoding="utf-8")
        continuation_swift = (ROOT / "BojiClub" / "ContextContinuation.swift").read_text(encoding="utf-8")
        camera_swift = (ROOT / "BojiClub" / "MealCamera.swift").read_text(encoding="utf-8")
        for field in ["actionSystemEnabled", "onboardingV2Enabled", "contextualTipsEnabled", "aiFastIntentV1", "aiRouterV3"]:
            self.assertIn(field, account_swift)
            self.assertIn(field, shell_swift)
        # 2026-11-08 妙妙修复（P2 对话砍除连带）：原断言
        # `FeatureFlagService.shared.actionSystemEnabled` 的消费代码在
        # ClubCoachView 对话 UI（孤儿代码）删除时一并移除。行为契约收窄为
        # 「flag 接线成立」：定义在 FeatureFlagService + 从远程 config 合并；
        # 命令通道消费门禁随 P2c 接线后此断言将加强到消费点。
        self.assertIn("actionSystemEnabled = remote?.config.actionSystemEnabled ?? true", shell_swift)
        self.assertIn("flags.contextualTipsEnabled", continuation_swift)
        self.assertNotIn("as! AVCaptureVideoPreviewLayer", camera_swift)
        self.assertIn("layer.addSublayer(preview)", camera_swift)
        # 2026-11-08 妙妙修复（CI 红模块分流，智智移交）：「≥3 次才提示」
        # 崩溃保护已迁 NutritionView.swift（NutritionTrendSummary）；行为契约
        # 不变——任一窗口不足 3 条即占位提示，不做除法。（与 fix/ios-test-3count-guard 同步）
        nutrition_swift = (ROOT / "BojiClub" / "NutritionView.swift").read_text(encoding="utf-8")
        self.assertIn("recent.count >= 3 && previous.count >= 3", nutrition_swift)

    def test_all_php_files_have_php_header_and_valid_utf8(self):
        php_files = list((ROOT / "account-server").rglob("*.php")) + list((ROOT / "tests").rglob("*.php"))
        self.assertGreaterEqual(len(php_files), 75)
        for path in php_files:
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("\ufffd", text, f"Invalid UTF-8 replacement char in {path}")
            self.assertTrue(text.lstrip().startswith("<?php"), f"Missing <?php header in {path}")


if __name__ == '__main__':
    unittest.main()
