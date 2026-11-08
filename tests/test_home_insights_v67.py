"""Insights stay actionable after removing the old dashboard and nested cards."""
import re
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
# 2026-11-07 妙妙修复（P0 CI 基准）：Build 130+ 重构后 trainingCard/quickActions
# 已并入 heroMissionCard/fuelBalanceCard；行为契约不变——训练入口（heroMissionCard
# 随 activeWorkout 自适应）与餐食入口（onRecordMeal）在 idle 均可达。
assert "private var heroMissionCard" in idle
# 训练入口的标题文案随重做批次调整，这里不锁具体措辞：只锁结构与「无黑话」。
hero_label = re.search(
    r'Label\(activeWorkout == nil \? "([^"]+)" : "([^"]+)", systemImage: "figure\.strengthtraining\.traditional"\)',
    idle,
)
assert hero_label, "训练入口 Label（双分支标题 + 图标）结构丢失"
for title in hero_label.groups():
    assert not any(word in title for word in ("战术", "战备", "简报", "决策", "充能")), f"训练入口标题含黑话：{title}"
workspace = shell[shell.index("private var aiWorkspace:"):shell.index("private var bottomDock:")]
assert "onStartTraining:" in workspace
assert "if activeWorkout != nil { openActiveWorkout() }" in workspace
assert "else { selectedDate = Date(); startTrainingFromPlan() }" in workspace
# The hub stays reachable from the idle workspace shell.
assert 'ClubAIHubView(initialSection: route.section)' in shell
assert 'Button(action: onRecordMeal)' in idle
assert 'Text("记录餐食")' in idle
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
