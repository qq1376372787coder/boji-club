#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build-check
{
  sed '/struct TrainingSet/,$d' BojiClub/Models.swift
  sed -n '/struct MealDescriptionHint/,$p' BojiClub/MealSpeechInput.swift
  cat tests/voice-meal-rules.swift
} > build-check/voice-meal-rules.swift
xcrun swift build-check/voice-meal-rules.swift 2>&1 | tee build-check/voice-meal-rules.log
