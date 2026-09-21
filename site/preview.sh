#!/bin/bash
# Build the page and serve it locally, laid out exactly as the server does.
#
#   site/preview.sh <version> <bytes-or-dmg> <min-macos> [port]
#
# Served rather than opened as a file, for two reasons that both used to waste ten minutes: the
# published asset names carry a content hash and exist nowhere on disk until something publishes
# them, and the pages reference them from the site root — which a file:// page resolves against
# the filesystem root and never finds. Over HTTP both pages behave exactly as they will live.
#
# The render happens per request, in site/preview-server.py, because it used to happen once: the
# server outlived the render, every later edit was invisible, and the page in the browser kept
# saying what it had said hours earlier. Now a refresh is the whole workflow — leave this running
# and keep editing.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?usage: preview.sh <version> <bytes-or-dmg> <min-macos> [port]}"
SIZE="${2:?}"
MINOS="${3:?}"
PORT="${4:-8787}"
OUT="${TMPDIR:-/tmp}/bulava-site-preview"

# An old preview server on this port is exactly the thing this script is about: it would keep
# answering with its own frozen copy and nothing here would ever be seen.
if command -v lsof >/dev/null 2>&1; then
  stale="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$stale" ]; then
    echo "порт $PORT уже слухає pid $stale — гашу його, бо він роздавав би свою стару копію"
    kill $stale 2>/dev/null || true
    sleep 0.6
  fi
fi

rm -rf "$OUT"; mkdir -p "$OUT/assets"

echo "http://localhost:$PORT/                (English)"
echo "http://localhost:$PORT/uk/             (Українська)"
echo "http://localhost:$PORT/pipeline/       (how it worked before)"
echo "http://localhost:$PORT/uk/pipeline/"

exec python3 "$HERE/preview-server.py" "$VERSION" "$SIZE" "$MINOS" "$PORT" "$OUT"
