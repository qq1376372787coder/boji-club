#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_ui_v47_swift_tests.py build-check/v47-native-rules.swift
swift build-check/v47-native-rules.swift | tee build-check/v47-native-rules.log
