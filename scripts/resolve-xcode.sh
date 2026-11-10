#!/usr/bin/env bash
# Pick an Xcode that actually has the iOS platform installed, and print diagnostics.
#
# The runner image ships many Xcode versions side by side. The one xcode-select
# points at by default may not have the iOS platform installed (Apple made the
# platforms separately downloadable components in Xcode 16). Picking the wrong
# one produces either of:
#   "iOS 26.0 is not installed. Please download and install the platform"
#   "No simulator runtime version from [...] available to use with
#    iphonesimulator SDK version ..."
# Neither is a code problem; the toolchain is simply not set up.
#
# Strategy: probe every candidate Xcode with `xcodebuild -showsdks` and pick one
# that exposes the iphoneos SDK. If none does, download the iOS platform and
# try again.
#
# NOTE: keep messages ASCII-only. bash resolves "$var" against the following
# byte, so a multi-byte character right after the variable name gets absorbed
# into the identifier ("dev\xef: unbound variable"). Use ${var} if you must.
set -uo pipefail

log() { echo ">> $*"; }

echo "== current xcode =="
xcodebuild -version || true
echo "== Xcodes under /Applications =="
ls -1 /Applications 2>/dev/null | grep -i '^Xcode' || echo "(none)"

has_ios_platform() {
  DEVELOPER_DIR="$1/Contents/Developer" xcodebuild -showsdks 2>/dev/null | grep -q -- '-sdk iphoneos'
}

select_xcode() {
  local dev
  for dev in /Applications/Xcode*.app; do
    [ -d "${dev}/Contents/Developer" ] || continue
    if has_ios_platform "${dev}"; then
      log "using ${dev} (has iOS platform)"
      sudo xcode-select -s "${dev}/Contents/Developer" || true
      return 0
    fi
    log "skipping ${dev} (no iOS platform)"
  done
  return 1
}

if ! select_xcode; then
  log "no installed Xcode exposes the iOS platform; downloading it (several GB, slow)"
  xcodebuild -downloadPlatform iOS || log "iOS platform download failed"
  select_xcode || log "still no Xcode with the iOS platform"
fi

echo "== selected xcode =="
xcodebuild -version || true
echo "== available SDKs =="
xcodebuild -showsdks || true
echo "== simulator runtimes =="
xcrun simctl list runtimes 2>/dev/null || echo "(simctl unavailable)"
echo "== iPhone device types =="
xcrun simctl list devicetypes 2>/dev/null | grep -i iphone | head -8 || echo "(none)"
