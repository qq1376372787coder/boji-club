#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_plan_insights_v49_swift_tests.py build-check/v49-native-rules.swift
swift build-check/v49-native-rules.swift | tee build-check/v49-native-rules.log
