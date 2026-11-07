#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/test_home_flow_v66.py
python3 tests/test_home_insights_v67.py
mkdir -p build-check
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v67-debug-build.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight \
  -destination 'generic/platform=iOS' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v67-testflight-build.log
echo '0.13.67 compile and home AI Insights checks passed. Continue with simulator layout review.'
