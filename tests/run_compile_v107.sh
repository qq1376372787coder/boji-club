#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bojiCompileFixture="$(mktemp -d "${TMPDIR:-/tmp}/boji-compile-v107.XXXXXX")"
trap 'rm -f "$bojiCompileFixture/compile-v107.swift" "$bojiCompileFixture/compile-v107"; rmdir "$bojiCompileFixture"' EXIT
python3 tests/build_compile_v107_swift_tests.py "$bojiCompileFixture/compile-v107.swift"
swiftc -swift-version 5 "$bojiCompileFixture/compile-v107.swift" -o "$bojiCompileFixture/compile-v107"
"$bojiCompileFixture/compile-v107"
