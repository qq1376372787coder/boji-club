#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_experience_v44_swift_tests.py build-check/v44-native-rules.swift
swift build-check/v44-native-rules.swift | tee build-check/v44-native-rules.log
