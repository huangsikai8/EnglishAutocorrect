#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

xcodebuild -project EnglishAutocorrect.xcodeproj \
    -scheme EnglishAutocorrect \
    -configuration Debug \
    -derivedDataPath build \
    build

killall EnglishAutocorrect 2>/dev/null || true
rm -rf ~/Library/Input\ Methods/EnglishAutocorrect.app
cp -R build/Build/Products/Debug/EnglishAutocorrect.app ~/Library/Input\ Methods/

echo "Rebuilt and reinstalled. Switch away from and back to the input source to pick up the new build."
