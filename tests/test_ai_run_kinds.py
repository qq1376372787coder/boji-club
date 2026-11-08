"""Static contract guards for the durable Run path extended to report/weekly.

These assert the wiring that is easy to break during refactors: the flag
defaults, the gate order, the shared Python job identity, the worker kind
branch, the client reducer and the polling fallback. They do not execute PHP;
the executable suite is tests/test_ai_runs_kinds.php (needs PHP+MySQL).
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AIRunKindsContractTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    @staticmethod
    def function_body(source: str, signature: str) -> str:
        start = source.index(signature)
        rest = source[start:]
        # The next top-level function/const declaration ends this body.
        tail = rest[len(signature):]
        for marker in ("\nfunction ", "\nconst "):
            index = tail.find(marker)
            if index != -1:
                tail = tail[:index] if tail == rest[len(signature):] else tail
                break
        return rest

    def test_run_v2_flags_default_off(self):
        cfg = self.read("account-server/public/app-config.php")
        self.assertRegex(cfg, r"'ai_run_v2_enabled'\s*=>\s*\['type'\s*=>\s*'bool'\s*,\s*'default'\s*=>\s*false\]")
        self.assertRegex(cfg, r"'ai_run_v2_kinds'\s*=>\s*\['type'\s*=>\s*'string'\s*,\s*'default'\s*=>\s*''\]")
        self.assertIn("function aiRunV2Enabled(", cfg)
        self.assertIn("function aiRunV2KindAllowed(", cfg)

    def test_create_for_kind_is_gated_and_scoped(self):
        runs = self.read("account-server/public/ai-runs.php")
        self.assertIn("const AI_RUN_KINDS = ['report', 'weekly_review']", runs)
        self.assertIn("function aiRunCreateForKind(", runs)
        # Distinct error codes so the client can tell the cases apart.
        self.assertIn("'run_v2_disabled'", runs)
        self.assertIn("'run_v2_kind_disabled'", runs)
        # Gate order: run-v2 switch before ai_enabled (mirrors coach_enabled).
        body = runs[runs.index("function aiRunCreateForKind("):]
        body = body[:body.index("\nfunction ")]
        self.assertLess(body.index("aiRunV2Enabled"), body.index("appFeatureEnabled"))
        # Same Python job identity as the polling path, so fallback is idempotent.
        self.assertIn("aiJobID($user, $clientId, $config)", body)
        # Durable job row first, request_hash for idempotent replay.
        self.assertIn("INSERT INTO ai_user_jobs", body)
        self.assertIn("request_hash", body)

    def test_route_is_registered(self):
        index = self.read("account-server/public/index.php")
        self.assertIn("'/me/ai/jobs/runs'", index)
        self.assertIn("aiRunCreateForKind(", index)

    def test_worker_is_kind_aware(self):
        worker = self.read("account-server/process-ai-runs.php")
        self.assertIn("array_merge(['coach'], AI_RUN_KINDS)", worker)
        self.assertIn("function aiRunWorkerCompleteKind(", worker)
        self.assertIn("'result.snapshot'", worker)
        self.assertIn("aiMarkCompleted(", worker)

    def test_client_is_kind_aware(self):
        # The non-coach runner lives in AIRunStream.swift: the Xcode project uses
        # an explicit file list, so a new file would need a pbxproj change.
        kind = self.read("BojiClub/AIRunStream.swift")
        self.assertIn("enum AIRunKindRunner", kind)
        self.assertIn("result.snapshot", kind)
        self.assertIn("run_v2_disabled", kind)
        self.assertIn("run_v2_kind_disabled", kind)
        self.assertIn("after_seq", kind)
        account = self.read("BojiClub/AccountService.swift")
        self.assertIn("ai_run_v2_enabled", account)
        self.assertIn("ai_run_v2_kinds", account)
        self.assertIn("Last-Event-ID", account)
        shell = self.read("BojiClub/ClubAIShell.swift")
        self.assertIn("runV2Enabled", shell)
        self.assertIn("runV2Kinds", shell)

    def test_fallback_is_wired(self):
        ai = self.read("BojiClub/AIService.swift")
        self.assertIn("runKindPath", ai)
        self.assertIn("case .uncertain", ai)
        self.assertIn("case .disabled", ai)
        weekly = self.read("BojiClub/WeeklyReview.swift")
        self.assertIn("runKindPath", weekly)
        self.assertIn("case .uncertain", weekly)
        self.assertIn("case .disabled", weekly)

    def test_no_admin_ui_wiring_by_design(self):
        """coach_enabled has no admin checkbox either: both flags are published
        through app_config by operations, so the client stays server-authoritative
        and the fixed 12-flag admin assertion is not disturbed."""
        view = self.read("account-server/admin/config-view.php")
        self.assertNotIn("ai_run_v2_enabled", view)


if __name__ == "__main__":
    unittest.main()
