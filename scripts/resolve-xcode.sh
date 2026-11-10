#!/usr/bin/env bash
# Pick an Xcode that can actually build for iOS, activate it, and export it.
#
# Why this exists: the runner image ships ~14 Xcode versions side by side, and
# the default one is not guaranteed to have the iOS platform installed. Apple
# made platforms separately downloadable components in Xcode 16, so an Xcode can
# list an SDK in `-showsdks` while the platform itself is unusable. Picking the
# wrong one produces either of:
#   "iOS 26.0 is not installed. Please download and install the platform"
#   "No simulator runtime version from [...] available to use with
#    iphonesimulator SDK version ..."
# Neither is a code problem; the toolchain is simply not set up.
#
# Strategy:
#   1. probe every candidate Xcode
#   2. prefer one that can really resolve both an iOS and an iOS Simulator
#      destination (`-showsdks` alone is not trustworthy, see above)
#   3. activate it with xcode-select and run -runFirstLaunch
#   4. if nothing works, download the iOS platform and probe again
#
# NOTE: keep messages ASCII-only. bash resolves "$var" against the following
# byte, so a multi-byte character right after the variable name gets absorbed
# into the identifier ("dev\xef: unbound variable"). Use ${var} if you must.
set -uo pipefail

log() { echo ">> $*"; }

PROJECT="BojiClub.xcodeproj"
SCHEME="BojiClub"

echo "== current xcode =="
xcodebuild -version 2>&1 || true
echo "== xcode-select =="
xcode-select -p 2>&1 || true
echo "== Xcodes under /Applications =="
ls -1 /Applications 2>/dev/null | grep -i '^Xcode' || echo "(none)"
echo "== installed simulator runtimes =="
xcrun simctl list runtimes 2>/dev/null | grep -i 'SimRuntime\.iOS' || echo "(none)"

# /Applications/Xcode_26.5.app -> 26.5 ; /Applications/Xcode.app -> 999
# The unversioned Xcode.app is the image default and points at the newest
# toolchain, so it sorts first instead of being probed last.
xcode_version() {
  local v
  v=$(basename "$1" | sed -E 's/^Xcode_?//; s/\.app$//')
  [ -n "$v" ] || v="999"
  printf '%s' "$v"
}

# Version of the iphoneos SDK this Xcode exposes, empty when it has none.
ios_sdk_version() {
  DEVELOPER_DIR="$1/Contents/Developer" xcodebuild -showsdks 2>/dev/null \
    | grep -o -- '-sdk iphoneos[0-9][0-9.]*' | head -1 | sed 's/-sdk iphoneos//'
}

# Candidates, newest version first.
# Deliberately plain `sort -r` rather than `sort -V`: macOS ships BSD sort,
# which has no -V. The image only ever has single-digit minor versions
# (26.0 ... 26.6), where lexicographic order and version order agree.
sorted_candidates() {
  local app
  for app in /Applications/Xcode*.app; do
    [ -d "${app}/Contents/Developer" ] || continue
    printf '%s|%s\n' "$(xcode_version "$app")" "$app"
  done | sort -t'|' -k1,1 -r | cut -d'|' -f2-
}

# Can this Xcode really resolve a destination? This is the ground truth:
# -showsdks lists SDKs that exist on disk even when the platform is not
# installed, so it produces false positives.
resolves() {  # $1 = developer dir, $2 = destination
  DEVELOPER_DIR="$1" xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$2" -showBuildSettings >/dev/null 2>&1
}

# 2 = both destinations resolve, 1 = simulator only, 0 = neither.
score_xcode() {
  local dev="$1" score=0
  resolves "${dev}/Contents/Developer" 'generic/platform=iOS Simulator' && score=$((score + 1))
  resolves "${dev}/Contents/Developer" 'generic/platform=iOS' && score=$((score + 1))
  echo "$score"
}

# Show why a probe failed, so an all-zero sweep is diagnosable instead of silent.
explain_failure() {
  echo "== why the destination probe fails =="
  DEVELOPER_DIR="$1/Contents/Developer" xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" -destination 'generic/platform=iOS' -showBuildSettings 2>&1 | tail -12
}

activate() {
  local app="$1"
  sudo xcode-select -s "${app}/Contents/Developer" 2>/dev/null || true
  # Accepts the licence and installs the extra components that make a freshly
  # selected Xcode usable. Harmless when they are already present.
  sudo xcodebuild -runFirstLaunch 2>&1 | tail -3 || true
}

probe_all() {  # echoes the best candidate path, or nothing
  local app ver score best="" best_score=0
  for app in $(sorted_candidates); do
    ver=$(ios_sdk_version "$app")
    [ -n "$ver" ] || continue
    score=$(score_xcode "$app")
    log "probed ${app}: iOS SDK ${ver}, score ${score}"
    if [ "$score" -gt "$best_score" ]; then
      best="$app"; best_score="$score"
      [ "$score" -ge 2 ] && break
    fi
  done
  if [ "$best_score" -eq 0 ] && [ -n "$best" ]; then
    explain_failure "$best"
  fi
  printf '%s\n' "$best"
}

chosen=""
if candidate=$(probe_all) && [ -n "$candidate" ]; then
  log "activating ${candidate}"
  activate "$candidate"
  # Re-probe the activated Xcode: -runFirstLaunch can change what is available.
  devdir="$(xcode-select -p 2>/dev/null || true)"
  if [ -n "$devdir" ] \
     && { resolves "$devdir" 'generic/platform=iOS Simulator' || resolves "$devdir" 'generic/platform=iOS'; }; then
    chosen="$candidate"
  else
    log "activated Xcode still cannot resolve a destination"
    explain_failure "$candidate"
  fi
fi

if [ -z "$chosen" ]; then
  log "no usable Xcode found; downloading the iOS platform (several GB, slow)"
  sudo xcodebuild -downloadPlatform iOS 2>&1 | tail -20 || true
  if candidate=$(probe_all) && [ -n "$candidate" ]; then
    activate "$candidate"
    chosen="$candidate"
  fi
fi

devdir="$(xcode-select -p 2>/dev/null || true)"
echo "== selected xcode =="
xcodebuild -version 2>&1 || true
echo "== xcode-select =="
echo "${devdir:-unknown}"
echo "== available SDKs =="
xcodebuild -showsdks 2>&1 || true
echo "== platform layout =="
if [ -n "$devdir" ]; then
  for platform in "$devdir"/Platforms/*.platform; do
    [ -d "$platform" ] || continue
    echo "-- ${platform}"
    ls -1 "$platform/Developer/SDKs" 2>/dev/null || echo "   (no SDKs)"
  done
fi
echo "== sdk paths =="
xcrun --sdk iphoneos --show-sdk-path 2>&1 || true
xcrun --sdk iphonesimulator --show-sdk-path 2>&1 || true
echo "== simulator runtimes =="
xcrun simctl list runtimes 2>/dev/null || echo "(simctl unavailable)"
echo "== iPhone device types =="
xcrun simctl list devicetypes 2>/dev/null | grep -i iphone | head -8 || echo "(none)"

if [ -z "$chosen" ]; then
  echo "!! no Xcode with a usable iOS platform was found"
  exit 1
fi

# Make the selection explicit for every later step in the same job, so a stray
# DEVELOPER_DIR cannot silently point xcodebuild back at the default Xcode.
if [ -n "${GITHUB_ENV:-}" ] && [ -n "$devdir" ]; then
  echo "DEVELOPER_DIR=${devdir}" >> "$GITHUB_ENV"
  echo "BOJI_DEVELOPER_DIR=${devdir}" >> "$GITHUB_ENV"
  log "exported DEVELOPER_DIR=${devdir}"
fi
