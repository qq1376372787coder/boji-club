"""P0 动作禁忌拦截（夜间实施）验收测试。

对应 reports/动作风险标签数据-v1.md 的 T1–T9 中可离线执行的部分，以及任务要求的三组：
  组1 腰椎 limitations → 池内 avoid 剔除
  组2 无 limitations   → 池逐字节不变
  组3 骨折红旗         → 整轮拒绝（provider 不被调用）

全部离线、无 HTTP、无数据库、不调用任何付费模型。
"""
from __future__ import annotations

import datetime
import hashlib
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

import ai_core
import exercise_risk
import weekly_core
from curated_library import BY_ID, ROWS, candidate_prompt

#: 改动 1（difficulty 过滤 + 空 exclude）之后的候选池黄金基线：
#: 322 项、无进阶动作、无任何 avoid 剔除。数据文件 exercise-catalog.json 是
#: 678 契约零改动（茵茵报告 §五.6），因此该哈希只会在候选池被误改时变化。
GOLDEN_PROMPT_SHA256 = "da4e40ae4802feeeb617338ef8733e3d4f9ecd20783aeddde66c021c2f7b8f7d"

AVOID_IDS = ("0282", "0857", "3670", "0084", "0044", "1759")
LUMBAR_LIMITATION = "腰椎间盘突出"


def pool_ids(prompt: str) -> set:
    """candidate_prompt() 末尾的紧凑目录 JSON → 动作 ID 集合。"""
    return {row["id"] for row in json.loads(prompt.split("目录：", 1)[1])}


def plan_body(limitations: str, today: str) -> dict:
    weekday = datetime.date.fromisoformat(today).isoweekday()
    return {
        "kind": "generate_plan",
        "date": today,
        "payload": {
            "profile": {
                "age": 28, "height": 175, "weight": 68, "daysPerWeek": 1,
                "goal": "增肌", "experience": "中级", "venue": "健身房", "focus": "全身",
                "sessionMinutes": 60, "limitations": limitations,
                "trainingDays": [weekday], "homeTrainingDays": [],
            },
            "timeZone": "Asia/Shanghai",
        },
    }


def plan_result(queries, today: str) -> dict:
    def row(query):
        reference = ai_core.recommended_reference(query)
        return {
            "name": reference["name_zh"], "muscle": reference["category_zh"],
            "library_query": query, "sets": [{"weight": None, "reps": 10}],
        }
    return {
        "kind": "plan", "title": "测试计划", "notes": [],
        "sessions": [{"date": today, "label": "全身训练", "exercises": [row(q) for q in queries]}],
    }


class Group1PoolExclusionTests(unittest.TestCase):
    """组1：腰椎 limitations → 池内 avoid 剔除。"""

    def test_lumbar_limitations_remove_pool_avoid_items(self):
        baseline = pool_ids(candidate_prompt())
        excluded = exercise_risk.excluded_for(LUMBAR_LIMITATION)
        # 改动 1 之后仍留在池里的 avoid 只有 0282 与 0044（报告 §五.8）。
        self.assertEqual(sorted(set(excluded) & baseline), ["0044", "0282"])
        after = pool_ids(candidate_prompt(exclude_ids=excluded))
        self.assertNotIn("0282", after)
        self.assertNotIn("0044", after)
        # 只剔除命中的 avoid，其余池项一个不少。
        self.assertEqual(after, baseline - {"0282", "0044"})

    def test_excluded_ids_come_from_avoid_level_only(self):
        excluded = exercise_risk.excluded_for(LUMBAR_LIMITATION)
        self.assertEqual(excluded, ["0282", "0857", "3670", "0084", "0044"])
        for exercise_id in excluded:
            self.assertIn(exercise_id, BY_ID)
            tag = next(t for t in exercise_risk.tags() if t["id"] == exercise_id)
            self.assertEqual(tag["level"], "avoid")
            self.assertIn("lumbar", tag["regions"])

    def test_region_matching_is_deterministic(self):
        self.assertEqual(exercise_risk.limited_regions(LUMBAR_LIMITATION), {"lumbar"})
        self.assertEqual(exercise_risk.limited_regions("肩袖损伤"), {"shoulder"})
        self.assertEqual(exercise_risk.limited_regions("半月板损伤"), {"knee"})
        self.assertEqual(exercise_risk.limited_regions(" "), set())
        self.assertEqual(exercise_risk.limited_regions(None), set())
        # 未匹配文本 → 空集合 → 不拦截（报告 §五.2）。
        self.assertEqual(exercise_risk.excluded_for("今天想练背"), [])

    def test_avoid_only_and_regions_must_intersect(self):
        lumbar = exercise_risk.limited_regions(LUMBAR_LIMITATION)
        self.assertTrue(exercise_risk.is_avoid("0282", lumbar))
        self.assertTrue(exercise_risk.is_avoid("0044", lumbar))
        # caution 永不拦截（报告 §五.1）：0735 是腰部 caution。
        self.assertFalse(exercise_risk.is_avoid("0735", lumbar))
        # 部位不相交不拦截：膝部 avoid 对腰部 limitations 无效。
        self.assertFalse(exercise_risk.is_avoid("1759", lumbar))
        # 无 limitations → 空部位 → 不拦截。
        self.assertFalse(exercise_risk.is_avoid("0044", set()))

    def test_data_file_contract(self):
        self.assertEqual(exercise_risk.VERSION, 1)
        tags = exercise_risk.tags()
        self.assertEqual(len(tags), 33)
        self.assertEqual(sorted(t["id"] for t in tags if t["level"] == "avoid"), sorted(AVOID_IDS))
        self.assertEqual(len({t["id"] for t in tags}), 33)
        for tag in tags:
            self.assertEqual(sorted(tag), ["id", "level", "name_zh", "reason", "regions"])
            self.assertIn(tag["id"], BY_ID, f"{tag['id']} 必须在 exercise-catalog.json 中")
            self.assertEqual(BY_ID[tag["id"]]["name_zh"], tag["name_zh"])


class Group2BaselineTests(unittest.TestCase):
    """组2：无 limitations → 池逐字节不变。"""

    def test_empty_exclusions_are_byte_identical(self):
        baseline = candidate_prompt()
        self.assertEqual(candidate_prompt(exclude_ids=exercise_risk.excluded_for("")), baseline)
        self.assertEqual(candidate_prompt(exclude_ids=[]), baseline)
        self.assertEqual(candidate_prompt(exclude_ids=None), baseline)

    def test_pool_matches_golden_baseline(self):
        baseline = candidate_prompt()
        self.assertEqual(hashlib.sha256(baseline.encode("utf-8")).hexdigest(), GOLDEN_PROMPT_SHA256,
                         "候选池与改动后基线不一致：难度过滤或目录数据被改动")

    def test_pool_is_322_without_advanced_movements(self):
        ids = pool_ids(candidate_prompt())
        self.assertEqual(len(ids), 322, "改动 1 后基础池应为 322 项（332 - 10 进阶）")
        advanced = {row["id"] for row in ROWS if row.get("difficulty_zh") != "常规"}
        self.assertEqual(len(advanced & {row["id"] for row in ROWS if row.get("selection_tier_zh") == "基础常用"
                                          and row.get("training_type_zh") in ("力量／稳定性", "有氧")}), 10)
        self.assertFalse(ids & advanced, "进阶动作不得出现在自动制定候选池")


class Group3RedFlagTests(unittest.TestCase):
    """组3：骨折红旗 → 整轮拒绝，且不触达任何 provider。"""

    @staticmethod
    def _forbidden_transport(*_args, **_kwargs):
        raise AssertionError("红旗请求不得触达供应商")

    def test_fracture_red_flag_rejects_whole_round(self):
        request = ai_core.validate_request(plan_body("骨折", ai_core.shanghai_today().isoformat()))
        router = ai_core.Router(providers=[], transport=self._forbidden_transport)
        with self.assertRaises(ai_core.AIError) as caught:
            router.run(request)
        self.assertEqual(caught.exception.code, "safety_review_required")
        self.assertFalse(caught.exception.retryable)

    def test_emergency_words_still_reject(self):
        for limitation in ("胸痛", "晕厥", "高烧"):
            with self.subTest(limitation=limitation):
                request = ai_core.validate_request(plan_body(limitation, ai_core.shanghai_today().isoformat()))
                router = ai_core.Router(providers=[], transport=self._forbidden_transport)
                with self.assertRaises(ai_core.AIError) as caught:
                    router.run(request)
                self.assertEqual(caught.exception.code, "safety_review_required")


class OutputValidationFallbackTests(unittest.TestCase):
    """输出校验兜底：模型违规输出 avoid 动作 → 拒绝；错误码映射不失真。"""

    def test_generate_plan_rejects_avoid_when_limited(self):
        today = ai_core.shanghai_today().isoformat()
        request = ai_core.validate_request(plan_body(LUMBAR_LIMITATION, today))
        with self.assertRaises(ai_core.AIError) as caught:
            ai_core.validate_result(request, plan_result(["barbell squat", "barbell bench press", "barbell good morning"], today))
        self.assertEqual(caught.exception.code, "invalid_output")
        self.assertEqual(caught.exception.reason, "plan_body_limits")

    def test_generate_plan_accepts_avoid_without_limitations(self):
        today = ai_core.shanghai_today().isoformat()
        request = ai_core.validate_request(plan_body("", today))
        ai_core.validate_result(request, plan_result(["barbell squat", "barbell bench press", "barbell good morning"], today))

    def test_generate_plan_accepts_clean_plan_when_limited(self):
        today = ai_core.shanghai_today().isoformat()
        request = ai_core.validate_request(plan_body(LUMBAR_LIMITATION, today))
        ai_core.validate_result(request, plan_result(["barbell squat", "barbell bench press", "pull up"], today))

    def test_caution_movement_is_not_rejected(self):
        today = ai_core.shanghai_today().isoformat()
        request = ai_core.validate_request(plan_body(LUMBAR_LIMITATION, today))
        ai_core.validate_result(request, plan_result(["barbell squat", "barbell bench press", BY_ID["0735"]["name"]], today))

    def test_error_code_and_repair_hint_are_wired(self):
        self.assertEqual(ai_core.output_reason(ValueError("movement limited by body profile")), "plan_body_limits")
        self.assertIn("plan_body_limits", ai_core.OUTPUT_REPAIR_HINTS)

    def test_parse_plan_import_is_not_blocked(self):
        # 导入路径不拦（报告 §五.7）：parse_plan 不进入 generate_plan 的 avoid 校验分支，
        # 即便原文里含 avoid 动作也原样保留，只提示用户核对。
        today = ai_core.shanghai_today().isoformat()
        body = plan_body(LUMBAR_LIMITATION, today)
        body["kind"] = "parse_plan"
        body["payload"]["text"] = "周一 杠铃早安式 3x10"
        request = ai_core.validate_request(body)
        self.assertEqual(request["kind"], "parse_plan")
        ai_core.validate_result(request, plan_result(["barbell squat", "barbell bench press", "barbell good morning"], today))


class WeeklyAdjustGuardTests(unittest.TestCase):
    """周报 adjust：avoid → decision=insufficient + reason 含禁忌说明；caution 不拦。"""

    HELPERS = (ai_core.text, ai_core.number, ai_core.sequence, ai_core.iso_date)

    @staticmethod
    def _fixture(limitations, items):
        today = ai_core.shanghai_today()
        session_date = today + datetime.timedelta(days=1)
        evidence = []
        for offset in (1, 2):
            evidence.append({
                "date": (today - datetime.timedelta(days=offset)).isoformat(),
                "exercises": [{"name": name, "sets": [{"completed": True, "reps": 10, "weight": 40} for _ in range(6)]}
                              for _, name, _ in items],
            })
        request = {
            "date": today.isoformat(),
            "payload": {
                "photos": [],
                "profile": {"venue": "健身房", "equipment": "", "equipmentOther": "", "sessionMinutes": 60,
                            "limitations": limitations, "trainingDays": [1, 2, 3, 4, 5, 6, 7]},
                "survey": {"pain": "无疼痛", "trainingDays": [session_date.isoweekday()], "days": 1,
                           "bodyFat": None, "bodyFatSource": ""},
                "days": evidence,
            },
        }
        result = {
            "kind": "weekly_review", "decision": "adjust",
            "summary": "本周完成情况良好。", "training": "本周共完成24组训练。",
            "nutrition": "本次未评估饮食。", "recovery": "恢复状态正常。", "appearance": "",
            "reason": "本周有完成记录，建议小幅延续。", "notes": [], "photoFeedback": [],
            "sessions": [{"date": session_date.isoformat(), "label": "全身", "exercises": [
                {"name": name, "muscle": muscle, "library_query": query, "sets": [{"weight": None, "reps": 10}, {"weight": None, "reps": 10}]}
                for query, name, muscle in items]}],
        }
        return request, result

    def _clean(self, limitations, items):
        request, result = self._fixture(limitations, items)
        return weekly_core.clean_result(request, result, self.HELPERS)

    def test_control_plan_still_adjusts(self):
        clean = self._clean(LUMBAR_LIMITATION, [("barbell squat", "杠铃深蹲", "腿部"),
                                                ("barbell bench press", "杠铃卧推", "胸")])
        self.assertEqual(clean["decision"], "adjust")
        self.assertEqual(len(clean["sessions"]), 1)

    def test_avoid_candidate_blocks_the_adjustment(self):
        clean = self._clean(LUMBAR_LIMITATION, [("barbell squat", "杠铃深蹲", "腿部"),
                                                ("barbell good morning", "杠铃早安式", "臀")])
        self.assertEqual(clean["decision"], "insufficient")
        self.assertEqual(clean["sessions"], [])
        self.assertIn("身体情况不匹配", clean["reason"])

    def test_caution_candidate_is_not_blocked(self):
        clean = self._clean(LUMBAR_LIMITATION, [("barbell squat", "杠铃深蹲", "腿部"),
                                                (BY_ID["0735"]["name"], "仰卧起坐", "腹部")])
        self.assertEqual(clean["decision"], "adjust")

    def test_avoid_candidate_without_limitations_is_not_blocked(self):
        clean = self._clean("", [("barbell squat", "杠铃深蹲", "腿部"),
                                 ("barbell good morning", "杠铃早安式", "臀")])
        self.assertEqual(clean["decision"], "adjust")


if __name__ == "__main__":
    unittest.main(verbosity=2)
