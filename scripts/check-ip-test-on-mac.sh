#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_ip_media_swift_tests.py build-check/ip-media-rules.swift
xcrun swift -D DEBUG build-check/ip-media-rules.swift 2>&1 | tee build-check/ip-media-debug.log
xcrun swift build-check/ip-media-rules.swift 2>&1 | tee build-check/ip-media-release.log

xcrun swift -D BOJI_TESTFLIGHT build-check/ip-media-rules.swift 2>&1 | tee build-check/ip-media-testflight.log
