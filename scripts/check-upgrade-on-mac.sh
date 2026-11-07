#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh tests/run_repair_v77.sh
sh tests/run_upgrade_v140.sh
sh tests/run_manual_plan.sh
sh tests/run_history.sh
sh tests/run_insight_ledger.sh
sh tests/run_goal_context.sh
sh tests/run_plan_changes.sh
sh tests/run_workout_summary.sh
sh tests/run_automation.sh
sh tests/run_coach.sh
sh tests/run_plan_followup.sh
sh tests/run_adaptive.sh
sh tests/run_retry_v106.sh
sh tests/run_compile_v107.sh
sh tests/run_build109.sh
sh tests/run_experience_v150.sh
bojiDerivedData="${TMPDIR:-/tmp}/boji-upgrade-build107"
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$bojiDerivedData" CODE_SIGNING_ALLOWED=NO build
