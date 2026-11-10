#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_repair_v38_swift_tests.py build-check/v38-native-rules.swift
swift build-check/v38-native-rules.swift | tee build-check/v38-native-rules.log
