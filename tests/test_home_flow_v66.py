"""The former home contracts follow the sole AI shell and first-plan destination."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOJI = ROOT / "BojiClub"
shell = (BOJI / "ClubAIShell.swift").read_text(encoding="utf-8")
app = (BOJI / "BojiClubApp.swift").read_text(encoding="utf-8")
first_plan = (BOJI / "FirstPlanPreviewView.swift").read_text(encoding="utf-8")
workout = (BOJI / "WorkoutView.swift").read_text(encoding="utf-8")
ai = (BOJI / "AIViews.swift").read_text(encoding="utf-8")


def ordered(text: str, values: list[str]) -> bool:
    position = -1
    for value in values:
        position = text.find(value, position + 1)
        if position < 0:
            return False
    return True


assert "ClubAIShellView()" in app
assert "MainClubView" not in app and "ClubTab" not in app
assert "flags.aiNativeHome" not in app
assert not (BOJI / "HomeView.swift").exists()
assert "AIJobStatusView(id: job.id" in first_plan
assert "ai.job(initialPlanJobID)" in first_plan
assert "store.hasAppliedAIJob($0.id)" in first_plan
assert "initialJobID: job.id, onPlanApplied:" in first_plan
assert 'Button("重试完成加入", action: onPlanApplied)' in first_plan
assert "onReturnToOnboarding" in first_plan
assert "FirstPlanPreviewView(initialPlanJobID: id" in (BOJI / "OnboardingView.swift").read_text()

# Planned rest still offers an explicit extra-workout route instead of
# unexpectedly generating a new plan. These are domain behavior contracts.
rest_branch = workout[workout.index("if isPlannedRestDay {"):workout.index("} else {", workout.index("if isPlannedRestDay {"))]
assert "这一天是计划休息日" in rest_branch
assert "临时加练 · 从动作库选择" in rest_branch
assert "AI 制定训练计划" not in rest_branch
assert "PlanCreationSheet(date: selectedDate)" in workout
assert "安排重复计划或使用 AI" in workout
assert "return !cycle.plannedDates.contains(key)" in workout

assert "ViewThatFits(in: .horizontal)" in ai
assert ordered(ai, ["HStack(spacing: 10)", "shareButton(result", 'analysisActionButton(title: "更新这份分析")'])
print("Sole AI home / first-plan / rest-day flow checks passed")
