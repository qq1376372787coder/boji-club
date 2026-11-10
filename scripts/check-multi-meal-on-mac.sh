#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_multi_meal_swift_tests.py build-check/multi-meal-rules.swift
xcrun swift build-check/multi-meal-rules.swift 2>&1 | tee build-check/multi-meal-rules.log
