#!/usr/bin/env bash
# 本地与 CI 共用的全量回归入口（docs/v2/04 号报告 §7 固定回归命令集）。
# 任何代码合入 main 前应全部通过；约耗时 10–15 分钟。
# 用法：bash scripts/run-all-checks.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION='platform=iOS Simulator,name=iPhone 17'
OUT="${TMPDIR:-/tmp}/boji-checks-$$"
mkdir -p "$OUT"

echo "== [1/5] Python 离线回归（640 项） =="
python3 -I tests/run_offline.py

echo "== [2/5] Swift 规则回归链（52 个 harness） =="
python3 tests/run_swift_regressions.py --output "$OUT/rules" --jobs 3

echo "== [3/5] 主应用编译检查（模拟器 Debug） =="
set -o pipefail
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -destination "$DESTINATION" -configuration Debug build 2>&1 | tee "$OUT/build.log" | grep -E "error:|BUILD" || true
grep -q "BUILD SUCCEEDED" "$OUT/build.log"

echo "== [4/5] 单元测试（BojiClubTests） =="
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -destination "$DESTINATION" test -only-testing:BojiClubTests 2>&1 | tee "$OUT/unit.log" | grep -E "Test Case.*(passed|failed)|Executed.*tests" || true
if grep -qE "Executed [0-9]+ tests?, with [1-9][0-9]* failures?" "$OUT/unit.log"; then
  echo "UNIT TESTS FAILED (nonzero failure count)"; exit 1
fi
grep -qE "Executed [0-9]+ tests?, with 0 failures" "$OUT/unit.log"

echo "== [5/5] UI 测试（旧壳回归 + V2 壳 + 无障碍审计 + 启动性能） =="
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -destination "$DESTINATION" test 2>&1 | tee "$OUT/ui.log" | grep -E "Test Case.*failed|Executed.*tests|TEST" || true
# ui.log 同时含单元测试汇总（"Executed 16 tests, with 0 failures"），不能靠
# "任意一条 0 failures" 判绿——必须排除任何非零 failure 计数（曾因此漏报 1 个 UI 失败）。
if grep -qE "Executed [0-9]+ tests?, with [1-9][0-9]* failures?" "$OUT/ui.log"; then
  echo "UI TESTS FAILED (nonzero failure count)"; exit 1
fi
grep -qE "Executed [0-9]+ tests?, with 0 failures" "$OUT/ui.log"

echo ""
echo "ALL CHECKS PASSED"
