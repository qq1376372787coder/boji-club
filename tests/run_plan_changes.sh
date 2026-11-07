#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch="$(mktemp -d -t boji-plan-changes)"
fixture="$scratch/Tests.swift"
trap 'rm -f "$fixture"; rmdir "$scratch"' EXIT
python3 tests/build_plan_changes_swift_tests.py "$fixture"
xcrun swift -swift-version 5 "$fixture"
