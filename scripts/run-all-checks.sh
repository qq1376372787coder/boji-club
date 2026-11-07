#!/usr/bin/env bash
# 本地与 CI 共用的全量回归入口（docs/v2/04 号报告 §7 固定回归命令集）。
# 任何代码合入 main 前应全部通过；约耗时 10–15 分钟。
# 用法：bash scripts/run-all-checks.sh
# 环境变量：
#   BOJI_DESTINATION  覆盖 xcodebuild 目标（默认 iPhone 17 模拟器，
#                     runner 上没有该机型时自动回退到第一台可用 iPhone 模拟器）
set -euo pipefail
cd "$(dirname "$0")/.."

# --- 目标模拟器解析（CI runner 镜像机型不固定，硬编码会直接失败）---
if [ -n "${BOJI_DESTINATION:-}" ]; then
  DESTINATION="$BOJI_DESTINATION"
elif xcrun simctl list devices available 2>/dev/null | grep -qE '^ *iPhone 17 \('; then
  # 精确匹配 "iPhone 17 ("，避免误匹配 "iPhone 17 Pro"（xcodebuild 要求机型名精确）。
  DESTINATION='platform=iOS Simulator,name=iPhone 17'
else
  fallback=$(xcrun simctl list devices available 2>/dev/null \
    | sed -n 's/^ *\(iPhone [^(]*\) (.*/\1/p' | sed 's/ *$//' | head -1 || true)
  if [ -n "${fallback:-}" ]; then
    echo "NOTE: iPhone 17 模拟器不可用，回退到可用机型: $fallback"
    DESTINATION="platform=iOS Simulator,name=$fallback"
  else
    echo "ERROR: 无可用 iPhone 模拟器（xcodebuild 无法定位目标）。" >&2
    xcrun simctl list devices available >&2 || true
    exit 1
  fi
fi
echo "DESTINATION=$DESTINATION"

OUT="${TMPDIR:-/tmp}/boji-checks-$$"
mkdir -p "$OUT"

if [ "${BOJI_SKIP_OFFLINE:-0}" = "1" ]; then
  # CI 把 Python 离线回归拆成独立任务（python-offline），iOS 车道只跑 2-5 步。
  echo "== [1/5] Python 离线回归（由 python-offline 任务执行，此处跳过） =="
else
  echo "== [1/5] Python 离线回归 =="
  python3 -I tests/run_offline.py
fi

echo "== [2/5] Swift 规则回归链 =="
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
