#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/test_testflight_v61.py
python3 tests/test_home_flow_v66.py
python3 tests/test_home_insights_v67.py
mkdir -p build-check
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v68-debug-build.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight \
  -destination 'generic/platform=iOS' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v68-testflight-build.log
echo 'Build checks completed. Verify sandbox purchase and the real RevenueCat webhook next.'
