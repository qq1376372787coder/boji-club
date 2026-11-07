"""Static contract guards for the durable Run/SSE layer.

These guard the invariants that are easy to break during refactors. They do not
execute PHP; the executable suite is tests/test_ai_runs.php (needs PHP+MySQL).
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AIRunContractTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_migration_is_expand_only_and_idempotent(self):
        sql = self.read("account-server/migrations/20261025-ai-runs.sql")
        for table in ("ai_runs", "ai_run_events"):
            self.assertIn(f"CREATE TABLE IF NOT EXISTS {table}", sql)
        self.assertIn("UNIQUE KEY ai_runs_client (user_id, client_message_id)", sql)
        self.assertIn("PRIMARY KEY (run_id, seq)", sql)
        self.assertIn("ON DELETE CASCADE", sql)
        for column in ("ai_usage_ledger", "ai_action_proposals", "data_operations"):
            self.assertIn(f"ALTER TABLE {column} ADD COLUMN IF NOT EXISTS trace_id", sql)
        self.assertNotIn("DROP TABLE", sql.upper())
        self.assertNotIn("DROP COLUMN", sql.upper())

    def test_fresh_schema_contains_run_tables(self):
        schema = self.read("account-server/schema.sql")
        self.assertIn("CREATE TABLE IF NOT EXISTS ai_runs", schema)
        self.assertIn("CREATE TABLE IF NOT EXISTS ai_run_events", schema)

    def test_streaming_flag_defaults_off(self):
        config = self.read("account-server/public/app-config.php")
        self.assertRegex(config, r"'ai_streaming_v2'\s*=>\s*\['type'\s*=>\s*'bool',\s*'default'\s*=>\s*false\]")
        self.assertIn("appFeatureEnabled($db, 'ai_streaming_v2')", self.read("account-server/public/ai-runs.php"))

    def test_endpoints_and_sse_contract(self):
        runs = self.read("account-server/public/ai-runs.php")
        index = self.read("account-server/public/index.php")
        for endpoint in ("/me/ai/conversations/([A-Za-z0-9_-]{8,64})/runs", "/me/ai/runs/([0-9a-f-]{36})/events",
                         "/me/ai/runs/([0-9a-f-]{36})", "/me/ai/runs/([0-9a-f-]{36})/cancel"):
            self.assertIn(endpoint, index)
        for header in ("Content-Type: text/event-stream", "Cache-Control: no-cache, no-transform, no-store",
                       "X-Accel-Buffering: no", "Connection: keep-alive"):
            self.assertIn(header, runs)
        self.assertIn("HTTP_LAST_EVENT_ID", index)
        self.assertIn("after_seq", index)
        self.assertIn(": heartbeat", runs)
        self.assertIn("retry: 3000", runs)
        self.assertIn("connection_aborted", runs)

    def test_create_is_idempotent_and_quota_checked(self):
        runs = self.read("account-server/public/ai-runs.php")
        self.assertIn("aiMayPostJob", runs)
        self.assertIn("aiCoachQuotaLeft", runs)
        self.assertIn("request_hash", runs)
        self.assertIn("409", runs)
        self.assertIn("lockActiveUser", runs)
        self.assertIn("aiCoachTurnRecord", runs)
        self.assertIn("ai_action_messages", runs)

    def test_cancel_never_overwrites_terminal_state(self):
        runs = self.read("account-server/public/ai-runs.php")
        self.assertIn("FOR UPDATE", runs)
        self.assertIn("aiRunTerminal", runs)
        self.assertIn("不能取消", runs)

    def test_worker_leases_and_never_claims_unseen_completion(self):
        worker = self.read("account-server/process-ai-runs.php")
        self.assertIn("FOR UPDATE SKIP LOCKED", worker)
        self.assertIn("lease_expires_at", worker)
        self.assertIn("actionPrivateRequest", worker)
        self.assertIn("AI_RUN_MAX_ATTEMPTS", worker)
        self.assertIn("run.failed", worker)
        self.assertIn("aiMarkCompleted", worker)
        self.assertIn("aiCoachTurnComplete", worker)
        self.assertTrue("cancelled_at_commit" in worker or "cancelled_before_complete" in worker)
        # Model I/O must not be wrapped in a transaction that holds an account lock.
        self.assertNotIn("beginTransaction()\n    $request = aiRunWorkerRequest", worker)

    def test_model_whitelist_excludes_confirmation_capabilities(self):
        registry = self.read("account-server/public/capability-registry.php")
        self.assertIn("schedule.commit_change", registry)
        self.assertIn("action.undo", registry)
        self.assertRegex(registry, r"in_array\(\$name,\['schedule\.commit_change','action\.undo'\],true\)\)continue;")

    def test_card_events_do_not_contain_executable_ui(self):
        runs = self.read("account-server/public/ai-runs.php")
        # Cards travel as JSON data; no HTML/JS or SQL is emitted by the run layer.
        for forbidden in ("<script", "javascript:", "DROP TABLE"):
            self.assertNotIn(forbidden, runs)

    def test_trace_id_reaches_proposals_commands_and_usage(self):
        proposals = self.read("account-server/public/ai-proposals.php")
        commands = self.read("account-server/public/commands.php")
        weekly = self.read("account-server/public/weekly.php")
        index = self.read("account-server/public/index.php")
        self.assertIn("trace_id", proposals)
        self.assertIn("trace_id", commands)
        self.assertIn("trace_id", weekly)
        self.assertIn("HTTP_X_BOJI_TRACE", index)
        self.assertIn("boji_trace_id", proposals)
        self.assertIn("boji_trace_id", commands)
        self.assertIn("boji_trace_id", weekly)

    def test_kill_switch_keeps_manual_paths_available(self):
        config = self.read("account-server/public/app-config.php")
        self.assertIn("'action_system_enabled'", config)
        self.assertIn("'ai_enabled'", config)
        runs = self.read("account-server/public/ai-runs.php")
        self.assertIn("AI 分析暂未开放", runs)
        self.assertIn("流式对话暂未开放", runs)

    def test_python_golden_dataset_and_report(self):
        cases = (ROOT / "tests/golden/golden_cases.jsonl").read_text(encoding="utf-8").splitlines()
        cases = [json.loads(line) for line in cases if line.strip()]
        self.assertGreaterEqual(len(cases), 100)
        ids = [case["id"] for case in cases]
        self.assertEqual(len(ids), len(set(ids)))
        for case in cases:
            self.assertIn(case["intent"], {"query", "draft_create", "change_proposal", "chat"})
            self.assertIn(case["safety"], {"none", "emergency"})
            self.assertTrue(case["forbidden_model_capabilities"])
        report = json.loads((ROOT / "docs/v2/overnight/ai_eval_report.json").read_text(encoding="utf-8"))
        self.assertEqual(report["metrics"]["model_dependent_metrics"], "not_run_no_credentials")


if __name__ == "__main__":
    unittest.main()
