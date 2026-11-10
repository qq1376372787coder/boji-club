#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
fixture="$(mktemp -d "${TMPDIR:-/tmp}/boji-v75.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
python3 tests/build_pretestflight_v74_swift_tests.py "$fixture/v74.swift"
xcrun swift -swift-version 5 "$fixture/v74.swift"
python3 tests/build_repair_v75_swift_tests.py "$fixture/v75.swift"
xcrun swift -swift-version 5 "$fixture/v75.swift"
