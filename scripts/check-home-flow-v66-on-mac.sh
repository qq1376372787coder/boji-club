#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/test_home_flow_v66.py
mkdir -p build-check
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v66-debug-build.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight \
  -destination 'generic/platform=iOS' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v66-testflight-build.log
echo '0.13.66 compile and home-flow checks passed. Continue with simulator layout review.'
