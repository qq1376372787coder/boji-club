#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/check-testflight-v61-on-mac.sh
python3 tests/build_library678_swift_tests.py build-check/library678-rules.swift
xcrun swift build-check/library678-rules.swift 2>&1 | tee build-check/library678-rules.log
