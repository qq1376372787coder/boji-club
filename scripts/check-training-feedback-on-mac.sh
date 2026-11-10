#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/check-library678-on-mac.sh
python3 tests/build_training_feedback_v63_swift_tests.py build-check/training-feedback-v63.swift
xcrun swift build-check/training-feedback-v63.swift 2>&1 | tee build-check/training-feedback-v63.log
