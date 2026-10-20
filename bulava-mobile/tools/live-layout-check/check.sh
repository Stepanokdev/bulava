#!/bin/bash
# Proves the Lock Screen Live Activity (LockScreenShift) never overflows the ~160pt the system gives
# it. Two stages, both compiling the REAL view against a layout-only LiveBox double:
#   macOS — real translations load, renders frames at the budget, measures NATURAL (unclamped)
#           heights, and proves teeth (a tall layout is reported OVER budget).
#   iOS simulator — where SwiftUI scales Dynamic Type: a 3-row layout really grows with text size,
#           the header-only fallback fits even at the largest accessibility size (AX5), and a tall
#           layout is over budget. This is the large-text proof macOS cannot give.
# The guarantee: ViewThatFits ends in a header-only (single-line) variant, which fits at any text
# size, so it always has a non-clipping choice.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
view="$here/../../iosApp/BulavaWidgets/LockScreenShift.swift"
strings="$here/../../iosApp/BulavaWidgets"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT

echo "— macOS: translations, frames, teeth —"
swiftc -O "$view" "$here/LiveBoxDouble.swift" "$here/main.swift" -o "$out/mac-harness"
cp -R "$strings/uk.lproj" "$strings/en.lproj" "$out/" 2>/dev/null || true
"$out/mac-harness" "$out" -AppleLanguages "(uk)"

echo "— iOS simulator: Dynamic Type, fallback fits at AX5, teeth —"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
udid="$(xcrun simctl list devices available 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()' | head -1 || true)"
if [ -z "$sdk" ] || [ -z "$udid" ]; then
  echo "  (no iOS simulator available — skipping the Dynamic Type stage; macOS stage + the header-only guarantee stand)"
else
  swiftc -sdk "$sdk" -target arm64-apple-ios17.0-simulator \
    "$view" "$here/LiveBoxDouble.swift" "$here/ios-measure.swift" -o "$out/ios-harness" 2>/dev/null
  xcrun simctl list devices | grep -q "$udid.*Booted" || { xcrun simctl boot "$udid" >/dev/null 2>&1 || true; sleep 8; }
  xcrun simctl spawn "$udid" "$out/ios-harness"
fi
echo "live-activity layout: within budget"
