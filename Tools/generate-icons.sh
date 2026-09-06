#!/bin/bash
# Regenerates every icon asset from Tools/MakeIcon.swift -- the app icon set
# and the README logo. Run after changing the mark; the PNGs are committed
# so a normal build never needs this.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

BIN="$(mktemp -d)/makeicon"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc -O Tools/MakeIcon.swift -o "$BIN"

ICONSET="EnglishAutocorrect/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"

for spec in 16:1:16 16:2:32 32:1:32 32:2:64 128:1:128 128:2:256 \
            256:1:256 256:2:512 512:1:512 512:2:1024; do
    base="${spec%%:*}"; rest="${spec#*:}"; scale="${rest%%:*}"; px="${rest#*:}"
    if [ "$scale" = "1" ]; then
        name="icon_${base}x${base}.png"
    else
        name="icon_${base}x${base}@2x.png"
    fi
    "$BIN" "$ICONSET/$name" "$px" > /dev/null
done

mkdir -p docs
"$BIN" docs/logo.png 512 > /dev/null

echo "Regenerated 10 app icon sizes and docs/logo.png"
