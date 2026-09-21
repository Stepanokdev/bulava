#!/bin/bash
# Render the page for a given release. The work is in render.py; this keeps the calling
# convention every other script already uses — version, artefact or byte count, output file,
# minimum macOS — and turns it into the output DIRECTORY the renderer wants.
#
# The page names the version in several places, so publishing a release without re-rendering it
# leaves the site offering the previous build while the update feed offers the new one, which is
# the confusing half-published state this exists to make impossible.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?usage: render.sh <version> <path-to-dmg|bytes> [output-file] [min-macos]}"
SIZE_IN="${2:?usage: render.sh <version> <path-to-dmg|bytes> [output-file] [min-macos]}"
OUT="${3:-$HERE/index.html}"
MINOS="${4:-}"

# The third argument names the English page; everything else the render produces — the Ukrainian
# page, the asset manifest — lands beside it.
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
[ "$(basename "$OUT")" = "index.html" ] \
  || { echo "render.sh пише index.html, а не «$(basename "$OUT")»" >&2; exit 1; }

exec python3 "$HERE/render.py" "$VERSION" "$SIZE_IN" "$OUT_DIR" "$MINOS"
