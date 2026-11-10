#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v65-debug-build.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight \
  -destination 'generic/platform=iOS' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v65-testflight-build.log
python3 tests/build_onboarding_v52_swift_tests.py build-check/onboarding-v65.swift
xcrun swift build-check/onboarding-v65.swift 2>&1 | tee build-check/onboarding-v65.log
echo '0.13.65 compile and consent-rule checks passed. Continue with simulator/device visual review.'
