#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d -t boji-retry106)"
trap 'rm -f "$scratch/Tests.swift"; rmdir "$scratch"' EXIT
python3 tests/build_retry_v106_swift_tests.py "$scratch/Tests.swift"
xcrun swift -swift-version 5 "$scratch/Tests.swift"
