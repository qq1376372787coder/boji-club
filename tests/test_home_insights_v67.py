"""Insights stay actionable after removing the old dashboard and nested cards."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOJI = ROOT / "BojiClub"
shell = (BOJI / "ClubAIShell.swift").read_text(encoding="utf-8")
ai = (BOJI / "AIViews.swift").read_text(encoding="utf-8")
workout = (BOJI / "WorkoutView.swift").read_text(encoding="utf-8")
sharing = (BOJI / "ReportShareViews.swift").read_text(encoding="utf-8")
project = (ROOT / "BojiClub.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

idle = shell[shell.index("struct ClubAIWorkspaceIdleView"):shell.index("private struct ClubActiveWorkoutAccessory")]
insights = (BOJI / "ClubHomeInsight.swift").read_text(encoding="utf-8")
assert "ClubHomeInsightStability.select(current: selectedInsight, candidates: insightCandidates)" in idle
assert "ClubInsightPriorityRules.isActionable" in idle
assert "ai.refreshHomeInsightIfNeeded()" in idle
# v3 首页把「今日训练焦点」作为无条件主卡：完成度环 + 三格真实数据 + 日报行。
# 不再按当天是否有训练决定卡片是否出现（休息日给占位而不是 0）。
assert "todayFocusCard" in idle
assert "今日训练完成度" in idle
assert "BojiStatStrip(items: [" in idle
assert "enum ClubHomeInsightStability" in insights
# Current AI workspace intentionally keeps today's old discovery card off the
# landing surface; insight history remains in the dedicated Club AI hub.
assert "insightCard(insight)" not in idle
workspace = shell[shell.index("private var aiWorkspace:"):shell.index("private var bottomDock:")]
assert "onStartTraining:" in workspace
assert "if activeWorkout != nil { openActiveWorkout() }" in workspace
assert "else { selectedDate = Date(); startTrainingFromPlan() }" in workspace
assert 'onOpenHub("动态")' in idle
quick_actions = idle[idle.index("private var quickActions:"):idle.index("private var todayFocusCard:")]
assert 'Button(action: onRecordMeal)' in quick_actions
assert 'Text("记录饮食")' in quick_actions
assert 'ClubAIHubView(initialSection: route.section)' in shell

# Report and export capabilities survive the old HomeView file deletion.
assert "var embedded = false" in ai
assert "ReportCardSurface(openReport: openReport, embedded: embedded)" in ai
assert "embedded ? ClubUI.controlRadius : ClubUI.cardRadius" in ai
assert "fill(ClubUI.insetSurface)" in ai
completion = workout[workout.index("private var completionSummary:"):workout.index("private var healthActions:")]
assert 'NavigationLink("本次训练记录") { ClubWorkoutSummaryView' in completion
for name in ["ShareCardView", "ShareCardPagination", "ShareSheet", "ShareDraft", "ShareCardPreview"]:
    assert name in sharing
assert "ReportShareViews.swift" in project and "HomeView.swift" not in project
assert "renderShareImage(card)?.jpegData" in sharing
assert "ownerID == store.editingAccountID" in sharing
print("AI workspace insight / report / share extraction checks passed")
