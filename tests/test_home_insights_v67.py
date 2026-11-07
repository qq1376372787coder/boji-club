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
# 2026-10-28 audit: the idle view's insight selection chain (selectedInsight /
# insightCandidates / insightCard) was dead code — never rendered, but rescanning
# an 8-day ledger on every render. It was removed; insights live in the Club AI
# hub, so the idle view only refreshes the server insight and keeps the hub entry.
assert "ClubHomeInsightStability.select(current: selectedInsight, candidates: insightCandidates)" not in idle
assert "insightCard" not in idle
assert "enum ClubHomeInsightStability" in insights
assert "ai.refreshHomeInsightIfNeeded()" in idle
assert "if activeWorkout != nil || !today.exercises.isEmpty { trainingCard }" in idle
workspace = shell[shell.index("private var aiWorkspace:"):shell.index("private var bottomDock:")]
assert "onStartTraining:" in workspace
assert "if activeWorkout != nil { openActiveWorkout() }" in workspace
assert "else { selectedDate = Date(); startTrainingFromPlan() }" in workspace
# The hub stays reachable from the idle workspace shell.
assert 'ClubAIHubView(initialSection: route.section)' in shell
quick_actions = idle[idle.index("private var quickActions:"):idle.index("private var trainingCard:")]
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
