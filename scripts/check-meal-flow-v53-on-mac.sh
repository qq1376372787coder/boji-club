#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p build-check
python3 tests/build_meal_flow_v53_swift_tests.py build-check/meal-flow-v53-rules.swift
xcrun swiftc build-check/meal-flow-v53-rules.swift -o build-check/meal-flow-v53-rules
build-check/meal-flow-v53-rules | tee build-check/meal-flow-v53-rules.log
