#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p build-check
xcodebuild -version
xcodebuild -project BojiClub.xcodeproj -list
xcodebuild -project BojiClub.xcodeproj \
  -scheme BojiClub \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/debug-build.log
xcodebuild -project BojiClub.xcodeproj \
  -scheme BojiClub \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/release-build.log
# Compile and link against the iPhone SDK as well; this is an unsigned build.
xcodebuild -project BojiClub.xcodeproj \
  -scheme BojiClub \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/iphone-release-build.log
for product in BojiClub.app BojiClubWidget.appex; do
  plist="build-check/DerivedData/Build/Products/Release-iphoneos/$product/Info.plist"
  minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$plist")"
  if [[ "$minimum_os" != "17.0" ]]; then
    echo "$product has unexpected MinimumOSVersion: $minimum_os" >&2
    exit 1
  fi
  echo "$product MinimumOSVersion=$minimum_os"
done | tee build-check/minimum-os.log
bash scripts/check-voice-meal-on-mac.sh
bash scripts/check-multi-meal-on-mac.sh
bash scripts/check-ip-test-on-mac.sh
bash scripts/check-repair-v38-on-mac.sh
bash scripts/check-screenshot-brand-on-mac.sh
bash scripts/check-repair-v46-on-mac.sh
bash scripts/check-ui-v47-on-mac.sh
bash scripts/check-repair-v48-on-mac.sh
bash scripts/check-plan-insights-v49-on-mac.sh
bash scripts/check-ai-stability-v50-on-mac.sh
bash scripts/check-onboarding-v52-on-mac.sh
bash scripts/check-meal-flow-v53-on-mac.sh
bash scripts/check-storage-v59-on-mac.sh
echo 'Build checks passed. iOS 17 and a newer iOS still require device testing.'
