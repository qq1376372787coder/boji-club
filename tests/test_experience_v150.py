from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOJI = ROOT / "BojiClub"


class ExperienceV150Contracts(unittest.TestCase):
    def test_ai_workspace_keeps_body_records_and_contextual_insights(self):
        shell = (BOJI / "ClubAIShell.swift").read_text(encoding="utf-8")
        app = (BOJI / "BojiClubApp.swift").read_text(encoding="utf-8")
        self.assertIn("ClubAIShellView()", app)
        self.assertNotIn("MainClubView", app)
        self.assertNotIn("flags.aiNativeHome", app)
        self.assertIn("ClubRecordsHub(category: $recordsCategory)", shell)
        self.assertIn("BodyWeightView(initialDate:", shell)
        overview = (BOJI / "HealthOverview.swift").read_text(encoding="utf-8")
        self.assertIn("身体概览", overview)
        self.assertIn("restingHeartRate", overview)
        self.assertIn("bodyMass", overview)
        idle = shell[shell.index("struct ClubAIWorkspaceIdleView"):shell.index("private struct ClubActiveWorkoutAccessory")]
        # 2026-10-28 audit: the idle view's insight selection chain was dead code
        # (never rendered, rescanned an 8-day ledger per render) and was removed;
        # contextual insights live in the Club AI hub, which the shell still opens.
        self.assertNotIn("ClubInsightPriorityRules.isActionable", idle)
        self.assertNotIn("ClubHomeInsightStability.select", idle)
        self.assertNotIn("insightCard(insight)", idle)
        self.assertIn("onQuickQuestion", idle)
        self.assertNotIn("HomeWorkoutVideoBackground", idle)

    def test_plan_calendar_first_and_move_sheet(self):
        plan = (BOJI / "PlanHubViews.swift").read_text(encoding="utf-8")
        self.assertIn("enum PlanCalendarRules", plan)
        self.assertIn("PlanCalendarRules.window(centeredOn: centerDate)", plan)
        self.assertIn("BojiMotion.cardExpand", plan)
        self.assertIn("BojiChipRow", (BOJI / "ClubInsightTimelineView.swift").read_text(encoding="utf-8"))
        hub = (BOJI / "ProductArchitecture.swift").read_text(encoding="utf-8")
        hub_block = hub[hub.index("struct ClubPlanHub: View"):hub.index("struct ClubPlanVersionsView")]
        self.assertNotIn("调整日期／顺延", hub_block)
        self.assertNotIn("PlanCoverCard(", hub_block)
        self.assertIn("PlanMoveSheet", hub_block)
        shift = (BOJI / "PlanShiftViews.swift").read_text(encoding="utf-8")
        self.assertIn("struct PlanMoveSheet", shift)
        self.assertIn("func destinations(", shift)

    def test_training_mini_bar_pause_and_live_activity(self):
        training = (BOJI / "TrainingRegistrationViews.swift").read_text(encoding="utf-8")
        self.assertIn("struct MiniWorkoutBar", training)
        self.assertIn("miniWorkoutInset", training)
        shell = (BOJI / "ClubAIShell.swift").read_text(encoding="utf-8")
        self.assertIn("ClubActiveWorkoutAccessory(snapshot:", shell)
        self.assertIn(".clubBottomBar { bottomDock }", shell)
        self.assertNotIn(".miniWorkoutInset(", shell)
        self.assertIn("WorkoutPauseService", (BOJI / "WorkoutView.swift").read_text(encoding="utf-8"))
        self.assertIn("ClubRestStorage", shell)
        self.assertIn("TrainingActivityService.shared.sync", shell)
        workout = (BOJI / "WorkoutView.swift").read_text(encoding="utf-8")
        self.assertIn("store.setWorkoutPaused", workout)
        shared = (ROOT / "BojiClubWidget" / "TrainingShared.swift").read_text(encoding="utf-8")
        self.assertIn("currentExerciseName", shared)
        self.assertIn("isPaused", shared)
        self.assertIn("currentSetNumber", shared)

    def test_club_ai_single_navigation_and_records_scales(self):
        coach = (BOJI / "ClubCoachView.swift").read_text(encoding="utf-8")
        hub = coach[coach.index("struct ClubAIHubView"):coach.index("private struct ClubCoachOpen")]
        self.assertIn("ClubAIHomeView", hub)
        self.assertNotIn('ForEach(["动态", "报告", "对话"]', hub)
        self.assertIn("struct ClubAIHomeView", coach)
        timeline = (BOJI / "ClubInsightTimelineView.swift").read_text(encoding="utf-8")
        self.assertIn("struct ClubEvidenceDisclosure", timeline)
        self.assertIn("BojiChipRow", timeline)
        trend = (BOJI / "TrendAnalysis.swift").read_text(encoding="utf-8")
        self.assertIn("enum ReviewTrendRules", trend)
        self.assertIn("guard let value, value.isFinite else { continue }", trend)
        review = (BOJI / "ReviewDashboardView.swift").read_text(encoding="utf-8")
        self.assertIn('"多尺度趋势"', review)
        self.assertIn("ReviewTrendRules.series", review)

    def test_dark_mode_semantic_colors(self):
        tokens = (BOJI / "DesignTokens.swift").read_text(encoding="utf-8")
        self.assertIn("private static func adaptive(", tokens)
        self.assertIn("userInterfaceStyle == .dark", tokens)
        app = (BOJI / "BojiClubApp.swift").read_text(encoding="utf-8")
        self.assertNotIn(".preferredColorScheme(.light)", app)

    def test_ui_test_target_and_seed(self):
        project = (ROOT / "BojiClub.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
        self.assertIn("com.apple.product-type.bundle.ui-testing", project)
        self.assertIn("BojiClubUITests", project)
        app = (BOJI / "AppStore.swift").read_text(encoding="utf-8")
        self.assertIn("BOJI_UI_TEST_SEED", app)
        account = (BOJI / "AccountService.swift").read_text(encoding="utf-8")
        self.assertIn("BOJI_PREVIEW_ACCOUNT", account)


if __name__ == "__main__":
    unittest.main()
