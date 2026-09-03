#!/usr/bin/env bash
# Builds the macOS app and prints only the diagnostics, not xcodebuild's command lines.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
xcodebuild \
    -project App/DBStudio.xcodeproj \
    -scheme DBStudio \
    -configuration "${1:-Debug}" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    -quiet build 2>&1 \
    | grep -E "(error|warning):" \
    | grep -v "^/Applications/Xcode" \
    | sort -u
exit "${PIPESTATUS[0]}"
