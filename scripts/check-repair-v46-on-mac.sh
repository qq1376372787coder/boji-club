#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_repair_v46_swift_tests.py build-check/v46-native-rules.swift
swift build-check/v46-native-rules.swift | tee build-check/v46-native-rules.log
