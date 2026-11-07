#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$(mktemp -d "${TMPDIR:-/tmp}/boji-product-consistency.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
python3 tests/build_product_consistency_swift_tests.py "$scratch/product.swift"
xcrun swift -swift-version 5 -module-cache-path "$scratch/module-cache" "$scratch/product.swift"
