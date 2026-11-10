#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
python3 tests/build_experience_v34_swift_tests.py build-check/experience-v34-rules.swift
xcrun swift build-check/experience-v34-rules.swift 2>&1 | tee build-check/experience-v34-rules.log
