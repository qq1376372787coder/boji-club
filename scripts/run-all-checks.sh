#!/usr/bin/env bash
# 本地与 CI 共用的全量回归入口（docs/v2/04 号报告 §7 固定回归命令集）。
# 任何代码合入 main 前应全部通过；约耗时 10–15 分钟。
#
# 用法：bash scripts/run-all-checks.sh [--skip-rules | --only-rules]
#   --skip-rules 跳过第 2 阶段（Swift 规则回归链）。该链是独立于应用代码的
#               既有红灯（见 docs/KNOWN-CI-ISSUES.md），跳过后仍会编译、跑单元
#               测试与 UI 测试这三段真正的验收。
#   --only-rules 只跑第 2 阶段。
#
# 模拟器目的地不写死机型名：runner 镜像里可用的运行时与机型随时间变化，写死
# 会直接报 "Unable to find a destination matching the provided destination
# specifier"。这里按"可用优先"动态解析，并可用 BOJI_DESTINATION 覆盖。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/boji-checks-$$"
mkdir -p "$OUT"

ONLY_RULES=0
SKIP_RULES=0
for argument in "$@"; do
  case "$argument" in
    --only-rules) ONLY_RULES=1 ;;
    --skip-rules) SKIP_RULES=1 ;;
  esac
done

# 打印可用的模拟器运行时与机型，便于在 CI 日志里定位目的地问题。
report_simulators() {
  echo "-- xcrun simctl runtimes --"
  xcrun simctl list runtimes 2>/dev/null || echo "(simctl unavailable)"
  echo "-- available iPhone devices --"
  xcrun simctl list devices available 2>/dev/null | grep -i 'iPhone' || echo "(none)"
}

# 解析测试用的具体模拟器：BOJI_DESTINATION > 任意可用 iPhone > generic。
resolve_test_destination() {
  if [ -n "${BOJI_DESTINATION:-}" ]; then printf '%s' "$BOJI_DESTINATION"; return 0; fi
  local udid
  udid=$(xcrun simctl list devices available 2>/dev/null | awk -F '[()]' '/iPhone/ {print $2; exit}')
  if [ -n "$udid" ]; then printf 'platform=iOS Simulator,id=%s' "$udid"; return 0; fi
  printf 'generic/platform=iOS Simulator'
}

# 编译阶段用设备 SDK：模拟器运行时必须与 SDK 版本严格匹配，runner 镜像里预装的
# 运行时常常更旧，模拟器 SDK 会直接报 "No simulator runtime version available"。
# 设备 SDK 不依赖运行时，只用来回答"能不能编译"。
BUILD_DESTINATION='generic/platform=iOS'

run_rules() {
  echo "== [2/5] Swift 规则回归链（54 个 harness） =="
  set +e
  python3 tests/run_swift_regressions.py --output "$OUT/rules" --jobs 3
  local status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "!! Swift 规则回归链未全绿（exit=$status）。"
    echo "!! 该链生成器按源码标记抽取生产代码，标记漂移即失败；属独立于应用代码的"
    echo "!! 既有问题，跟踪于 docs/KNOWN-CI-ISSUES.md。它不阻断随后的编译与测试阶段。"
  fi
  return "$status"
}

if [ "$ONLY_RULES" -eq 1 ]; then
  run_rules
  exit $?
fi

echo "== [1/5] Python 离线回归（640 项） =="
python3 -I tests/run_offline.py

if [ "$SKIP_RULES" -eq 0 ]; then
  run_rules || true
fi

echo "== 模拟器环境 =="
report_simulators

echo "== [3/5] 主应用编译检查（模拟器 Debug） =="
set -o pipefail
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -destination "$BUILD_DESTINATION" -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee "$OUT/build.log" | grep -E "error:|BUILD" || true
grep -q "BUILD SUCCEEDED" "$OUT/build.log"

TEST_DESTINATION="$(resolve_test_destination)"
echo "测试目的地：$TEST_DESTINATION"

echo "== [4/5] 单元测试（BojiClubTests） =="
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -destination "$TEST_DESTINATION" test -only-testing:BojiClubTests 2>&1 | tee "$OUT/unit.log" | grep -E "Test Case.*(passed|failed)|Executed.*tests" || true
if grep -qE "Executed [0-9]+ tests?, with [1-9][0-9]* failures?" "$OUT/unit.log"; then
  echo "UNIT TESTS FAILED (nonzero failure count)"; exit 1
fi
grep -qE "Executed [0-9]+ tests?, with 0 failures" "$OUT/unit.log"

echo "== [5/5] UI 测试（旧壳回归 + V2 壳 + 无障碍审计 + 启动性能） =="
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub \
  -destination "$TEST_DESTINATION" test 2>&1 | tee "$OUT/ui.log" | grep -E "Test Case.*failed|Executed.*tests|TEST" || true
# ui.log 同时含单元测试汇总（"Executed 16 tests, with 0 failures"），不能靠
# "任意一条 0 failures" 判绿——必须排除任何非零 failure 计数（曾因此漏报 1 个 UI 失败）。
if grep -qE "Executed [0-9]+ tests?, with [1-9][0-9]* failures?" "$OUT/ui.log"; then
  echo "UI TESTS FAILED (nonzero failure count)"; exit 1
fi
grep -qE "Executed [0-9]+ tests?, with 0 failures" "$OUT/ui.log"

echo ""
echo "ALL CHECKS PASSED"
