#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath "${TMPDIR:-/tmp}/boji-build111" CODE_SIGNING_ALLOWED=NO test
