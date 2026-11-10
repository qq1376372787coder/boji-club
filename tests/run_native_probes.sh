#!/usr/bin/env bash
# Focused Swift regressions for FIX-004/005-adjacent decode, FIX-014, FIX-022.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/boji-native-probes.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="$scratch/clang-cache"
export SWIFT_MODULECACHE_PATH="$scratch/swift-cache"
for probe in build_live_activity_decode_test build_manual_plan_import_test build_recovery_gate_test; do
  echo "== $probe"; python3 -I "tests/$probe.py"
done
for phase in 1 2 3; do
  echo "== phase$phase"
  python3 -I "tests/build_phase${phase}_swift_tests.py" "${scratch}/phase${phase}.swift" >/dev/null
  swiftc -o "${scratch}/phase${phase}" "${scratch}/phase${phase}.swift"
  "${scratch}/phase${phase}" | tail -1
done
