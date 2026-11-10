#!/usr/bin/env bash
# 选一个「带 iOS 平台」的 Xcode，并打印诊断信息。
#
# runner 镜像里可能同时装着多个 Xcode，其中新版未必装了 iOS 平台（Apple 从
# Xcode 16 起把 iOS 平台拆成可单独下载的 component）。选错会得到：
#   · "iOS 26.0 is not installed. Please download and install the platform"
#   · "No simulator runtime version from [...] available to use with
#      iphonesimulator SDK version ..."
# 两者都不是代码问题，而是工具链没配齐。
#
# 策略：逐个候选 Xcode 用 `xcodebuild -showsdks` 探测是否带 iphoneos SDK；
# 都没有就下载 iOS platform，再选一次。
set -uo pipefail

log() { echo ">> $*"; }

echo "== 当前 Xcode =="
xcodebuild -version || true
echo "== /Applications 里的 Xcode =="
ls -1 /Applications 2>/dev/null | grep -i '^Xcode' || echo "(none)"

has_ios_platform() {
  DEVELOPER_DIR="$1/Contents/Developer" xcodebuild -showsdks 2>/dev/null | grep -q -- '-sdk iphoneos'
}

select_xcode() {
  local dev
  for dev in /Applications/Xcode*.app; do
    [ -d "$dev/Contents/Developer" ] || continue
    if has_ios_platform "$dev"; then
      log "选用 $dev（含 iOS 平台）"
      sudo xcode-select -s "$dev/Contents/Developer" || true
      return 0
    fi
    log "跳过 $dev（未安装 iOS 平台）"
  done
  return 1
}

if ! select_xcode; then
  log "已装的 Xcode 都没有 iOS 平台，开始下载 iOS platform（数 GB，耗时较长）。"
  xcodebuild -downloadPlatform iOS || log "iOS platform 下载失败"
  select_xcode || log "仍未找到带 iOS 平台的 Xcode"
fi

echo "== 选中的 Xcode =="
xcodebuild -version || true
echo "== 可用 SDK =="
xcodebuild -showsdks || true
echo "== 模拟器运行时 =="
xcrun simctl list runtimes 2>/dev/null || echo "(simctl unavailable)"
echo "== 可用 iPhone 机型 =="
xcrun simctl list devicetypes 2>/dev/null | grep -i iphone | head -8 || echo "(none)"
