#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v61-preview-build.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight \
  -destination 'generic/platform=iOS' -derivedDataPath build-check/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check/v61-testflight-build.log
bash scripts/check-ip-test-on-mac.sh
python3 tests/build_subscription_v61_swift_tests.py build-check/subscription-v61-rules.swift
xcrun swift build-check/subscription-v61-rules.swift 2>&1 | tee build-check/subscription-v61-rules.log
python3 - <<'PY'
from pathlib import Path
import plistlib
p=Path('build-check/DerivedData/Build/Products/TestFlight-iphoneos/BojiClub.app/Info.plist')
s=plistlib.loads(p.read_bytes())
assert s['MinimumOSVersion']=='17.0'
assert s['CFBundleIdentifier']=='com.bojiclub.app.dev'
assert s['RevenueCatMemberEntitlementID']=='薄肌俱乐部_pro'
assert s['RevenueCatMonthlyProductID']=='yuefu'
assert s['RevenueCatAnnualProductID']=='nianfu'
assert s['RevenueCatLifetimeProductID']=='yongjiu'
assert not s.get('RevenueCatPublicSDKKey','').startswith('test_')
print('Compile/configuration checks passed. Signed Archive and actual Apple login/purchases still require testing.')
if not s.get('RevenueCatPublicSDKKey','').startswith('appl_'):
    print('Apple SDK key is missing: screenshot preview is available in Debug; purchases are not ready.')
PY
