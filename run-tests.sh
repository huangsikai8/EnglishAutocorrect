#!/bin/bash
# Compiles and runs the pure-logic tests. These cover CorrectionRules,
# which has no AppKit/IMKit/Bundle dependency and so needs no app host --
# the project has a single application target and no XCTest bundle.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
    EnglishAutocorrect/CorrectionRules.swift \
    Tests/*.swift \
    -o "$OUT/tests"

"$OUT/tests"
