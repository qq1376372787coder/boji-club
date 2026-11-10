#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bojiBuildfixData="${TMPDIR:-/tmp}/boji-buildfix-build107"
# Compile the actual app first, so SwiftUI errors are reported directly.
xcodebuild -project BojiClub.xcodeproj -scheme BojiClub-TestFlight -configuration TestFlight -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$bojiBuildfixData" CODE_SIGNING_ALLOWED=NO build
sh tests/run_compile_v107.sh
