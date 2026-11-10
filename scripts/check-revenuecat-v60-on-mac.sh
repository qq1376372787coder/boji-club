#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build-check
xcodebuild -resolvePackageDependencies -project BojiClub.xcodeproj -scheme BojiClub \
  -clonedSourcePackagesDirPath build-check/SourcePackages 2>&1 | tee build-check/revenuecat-resolve.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-check/DerivedData \
  -clonedSourcePackagesDirPath build-check/SourcePackages CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee build-check/revenuecat-debug-build.log
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build-check/DerivedData \
  -clonedSourcePackagesDirPath build-check/SourcePackages CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee build-check/revenuecat-release-build.log
python3 - <<'PY'
import plistlib
from pathlib import Path
debug=plistlib.loads(Path('build-check/DerivedData/Build/Products/Debug-iphonesimulator/BojiClub.app/Info.plist').read_bytes())
release=plistlib.loads(Path('build-check/DerivedData/Build/Products/Release-iphoneos/BojiClub.app/Info.plist').read_bytes())
assert debug['RevenueCatMemberEntitlementID']=='薄肌俱乐部_pro'
assert debug['RevenueCatPublicSDKKey'].startswith(('test_','appl_'))
assert not release.get('RevenueCatPublicSDKKey','').startswith('test_'), 'Never upload a Test Store key to TestFlight/App Store'
assert release['MinimumOSVersion']=='17.0'
print('Build and entitlement configuration passed. Empty Release key still needs the real appl_ key before paid testing.')
PY
echo 'Next: run success/cancel/failure/restore/account-switch purchases in the app; compiler success is not payment acceptance.'
