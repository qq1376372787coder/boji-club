#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_dir=$(mktemp -d "/tmp/boji-v74.XXXXXX")
trap 'rm -f "$temporary_dir/rules.swift"; rmdir "$temporary_dir"' EXIT HUP INT TERM
cd "$project_dir"
python3 tests/build_pretestflight_v74_swift_tests.py "$temporary_dir/rules.swift"
xcrun swift -swift-version 5 "$temporary_dir/rules.swift"
