#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tests/build_storage_v59_swift_tests.py
swift build-check/storage-v59-wire.swift | tee build-check/storage-v59-wire.log
