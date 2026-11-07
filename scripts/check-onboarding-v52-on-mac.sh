#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_onboarding_v52_swift_tests.py build-check/v52-onboarding-rules.swift
swiftc build-check/v52-onboarding-rules.swift -o build-check/v52-onboarding-rules
build-check/v52-onboarding-rules | tee build-check/v52-onboarding-rules.log
