#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh tests/run_repair_v76.sh
fixture="$(mktemp -d "${TMPDIR:-/tmp}/boji-v77.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
python3 tests/build_repair_v77_swift_tests.py "$fixture/v77.swift"
xcrun swift -swift-version 5 "$fixture/v77.swift"
