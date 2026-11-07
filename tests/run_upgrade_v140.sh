#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d -t boji-insights)"
fixture="$scratch/Tests.swift"
trap 'rm -f "$fixture"; rmdir "$scratch"' EXIT
python3 tests/build_upgrade_v140_swift_tests.py "$fixture"
xcrun swift -swift-version 5 "$fixture"
