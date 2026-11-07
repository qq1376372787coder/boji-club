"""P2「coach 后端链路休眠」闸门契约测试（纯源码，可本地运行）。

休眠口径（与 iOS 侧对齐）：
- 唯一开关：app_config 的 ``coach_enabled``（bool，默认 false = 休眠）；
- 休眠时 coach 专属入口回 ``503 + error_code=coach_disabled``，端点保留、数据保留；
- 非 coach 的 4 项（生成计划 / 解析计划 / 饮食识别 / 日报 / 周报）不经过任何
  coach 闸门，因此不受影响；
- Python worker（backend/）不设第二个开关，避免双开关半开状态。

本文件把这些口径钉成回归契约：闸门少了、误伤其他 kind、或默认值被改成 true，
测试立刻失败。
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FLAG = "coach_enabled"
DORMANT_MESSAGE = "AI 对话功能暂未开放"
ERROR_CODE = "coach_disabled"
OTHER_KINDS = ("generate_plan", "parse_plan", "food", "report", "weekly_review")

# (相对路径, 必须出现的精确闸门行, 期望出现次数, 说明)
GATES = [
    ("account-server/public/weekly.php",
     "if ($kind === 'coach' && !coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');",
     1, "提交 POST /me/ai/jobs（仅 kind=coach）"),
    ("account-server/public/weekly.php",
     "if ($jobRow['kind'] === 'coach' && !coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');",
     1, "轮询 GET /me/ai/jobs/{id} 与重试 POST /retry（仅 coach 任务）"),
    ("account-server/public/weekly.php",
     "if (!coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');",
     2, "对话读取 GET /me/ai/conversations 与 /messages"),
    ("account-server/public/ai-runs.php",
     "if (!coachEnabled($db)) fail('AI 对话功能暂未开放，请稍后再试。', 503, 'coach_disabled');",
     4, "SSE：Run 创建 / 快照 / 事件流 / 取消"),
    ("account-server/public/index.php",
     "if(!coachEnabled($db))fail('AI 对话功能暂未开放，请稍后再试。',503,'coach_disabled');",
     1, "上下文引用 POST /me/ai/context/resolve"),
    ("account-server/public/action-execution.php",
     "if(!coachEnabled($db))return ['results'=>",
     1, "coach 消息能力执行 → rejected，不产生业务写入"),
    ("account-server/process-club-automation.php",
     "if(($request['kind']??'')==='coach'&&!coachEnabled($db)){$coachSkipped++;continue;}",
     1, "自动跟进 cron 内部提交的 coach 任务"),
]

# 每个文件里 coachEnabled( 的总次数（含 app-config.php 中的函数定义一次）
EXPECTED_OCCURRENCES = {
    "account-server/public/app-config.php": 1,   # 函数定义
    "account-server/public/weekly.php": 4,
    "account-server/public/ai-runs.php": 4,
    "account-server/public/index.php": 1,
    "account-server/public/action-execution.php": 1,
    "account-server/process-club-automation.php": 1,
}


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class CoachDormancyContractTests(unittest.TestCase):
    def test_every_gate_exists_with_expected_count(self):
        for relative, anchor, count, description in GATES:
            with self.subTest(site=description, file=relative):
                body = read(relative)
                actual = body.count(anchor)
                self.assertEqual(actual, count, f"{description}：闸门应出现 {count} 次，实际 {actual} 次（{relative}）")

    def test_gate_totals_match(self):
        for relative, expected in EXPECTED_OCCURRENCES.items():
            with self.subTest(file=relative):
                self.assertEqual(read(relative).count("coachEnabled("), expected,
                                 f"{relative} 中 coachEnabled( 调用次数漂移")

    def test_no_gate_touches_the_other_four_kinds(self):
        # 任何闸门语句都不得以非 coach 的 kind 为条件，否则会误伤 4 项。
        for relative in EXPECTED_OCCURRENCES:
            for line in read(relative).splitlines():
                if "coachEnabled(" not in line or "function coachEnabled" in line:
                    continue
                with self.subTest(file=relative, line=line.strip()[:80]):
                    for kind in OTHER_KINDS:
                        self.assertNotIn(f"'{kind}'", line, f"闸门不得以 {kind} 为条件：{line.strip()}")

    def test_flag_defaults_to_off_and_is_the_single_switch(self):
        config = read("account-server/public/app-config.php")
        self.assertIsNotNone(
            re.search(r"'coach_enabled'\s*=>\s*\[\s*'type'\s*=>\s*'bool'\s*,\s*'default'\s*=>\s*false\s*\]", config),
            "coach_enabled 必须声明为 bool 且默认 false（休眠）")
        self.assertIn("function coachEnabled(PDO $db): bool", config)
        self.assertIn("appFeatureEnabled($db, 'coach_enabled')", config)
        # 未发布 / 未配置一律按 false 处理（fail-closed）。
        self.assertIn("return (bool)($published['config'][$key] ?? false);", config)
        # /account/v1/config 始终携带该键（published 从 defaults 起步），客户端可直接读。
        self.assertIn("$published = appConfigDefaults();", config)

    def test_gates_respond_with_the_documented_error_shape(self):
        for relative, _, _, _ in GATES:
            body = read(relative)
            with self.subTest(file=relative):
                if "coachEnabled(" not in body:
                    continue
                # HTTP 闸门必须带 error_code；CLI 闸门用 continue / rejected。
                for line in body.splitlines():
                    if "coachEnabled(" not in line or "function coachEnabled" in line:
                        continue
                    is_http = "fail(" in line
                    is_cli = "continue;" in line or "return ['results'" in line
                    self.assertTrue(is_http or is_cli,
                                    f"闸门必须以 fail() 或 CLI 跳过方式生效：{line.strip()}")
                    if is_http:
                        self.assertIn(ERROR_CODE, line, f"HTTP 闸门必须带 error_code={ERROR_CODE}")

    def test_python_worker_has_no_second_switch_and_still_accepts_all_kinds(self):
        # 单开关决策：worker 不再加一个同名开关，避免“半开”状态。
        for relative in ("backend/server.py", "backend/ai_core.py"):
            body = read(relative)
            self.assertNotIn(FLAG, body, f"{relative} 不应存在第二个 {FLAG} 开关")
            self.assertNotIn(ERROR_CODE, body, f"{relative} 不应存在 {ERROR_CODE} 拒绝逻辑")
        # 4 项 + coach 仍全部在 worker 的任务白名单里（回退时无需改 worker）。
        core = read("backend/ai_core.py")
        self.assertIn('kind not in ("generate_plan", "parse_plan", "food", "report", "weekly_review", "coach")', core)
        # 队列排空：claim 仍优先 coach，休眠前排队的任务照常被处理完。
        server = read("backend/server.py")
        self.assertIn("kind='coach'", server)

    def test_data_and_code_are_kept_for_rollback(self):
        # 休眠只加闸门：历史表、读写函数、coach 业务代码必须还在。
        self.assertTrue((ROOT / "account-server/public/ai-conversations.php").exists())
        self.assertTrue((ROOT / "backend/coach_core.py").exists())
        runs = read("account-server/public/ai-runs.php")
        self.assertIn("function aiRunCreate(", runs)
        self.assertIn("function aiRunStream(", runs)


if __name__ == "__main__":
    unittest.main(verbosity=2)
