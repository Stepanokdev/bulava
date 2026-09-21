#!/usr/bin/env bash
# Regenerate the app icon set from the logo geometry. Run from the repo root:
#
#     bash tools/icongen/build.sh [icon-dir] [svg-path]
#
# Compiles the app's own BulavaGlyph.swift, so the Dock icon and the in-app mark can never drift.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-Night Shift/Assets.xcassets/AppIcon.appiconset}"
svg="${2:-engine/assets/brand-mark.svg}"
bin="$(mktemp -d)/icongen"
swiftc -O -o "$bin" "Night Shift/Design/BulavaGlyph.swift" tools/icongen/main.swift
"$bin" "$out" "$svg"
