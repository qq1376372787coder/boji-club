#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_ai_stability_v50_swift_tests.py build-check/v50-native-rules.swift
swiftc build-check/v50-native-rules.swift -o build-check/v50-native-rules
build-check/v50-native-rules | tee build-check/v50-native-rules.log
