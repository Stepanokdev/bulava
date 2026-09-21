#!/bin/bash
# The suite has to pass from the tree that actually ships, not only from the working repository.
#
# Four tests located the engine by walking up to the app checkout and back down through `engine/`,
# and one compared a symlinked path against a resolved one. In the repository they were green; in a
# standalone install they reported fifteen failures nobody could act on. This runs the whole suite
# out of a fresh export, which is the only place that distinction shows up.
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This test's whole subject is the difference between the working tree and an export. Run from
# inside an export it would build an export of an export, forever, and prove nothing.
if [ ! -d "$ENGINE/../Night Shift" ] && [ ! -f "$ENGINE/../tools/icongen/build.sh" ]; then
  echo "â already running from an exported tree — nothing further to prove here"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
EXPORT="$TMP/engine"

echo "== building a clean export =="
if ! "$ENGINE/bin/publish-engine.sh" "$EXPORT" > "$TMP/pub.log" 2>&1; then
  echo "❌ export refused:"; tail -12 "$TMP/pub.log" | sed 's/^/   /'
  exit 1
fi
echo "   $EXPORT"

echo
echo "== the exported engine cannot see the app checkout it came from =="
if [ -e "$EXPORT/../tools/icongen" ] || [ -d "$EXPORT/../Night Shift" ]; then
  echo "❌ the export is still sitting next to the app tree — this proves nothing"
  exit 1
fi
echo "   confirmed standalone"

echo
echo "== full suite, from the exported tree =="
# The browser suite is left to the outer run: it drives Chrome and then asserts that no Chrome is
# left running, so two copies of it in flight at once fail each other for reasons that have nothing
# to do with the exported tree. Everything else runs here on the stranger's copy.
( cd "$EXPORT" && SUPERVISOR_TEST_SKIP="test-web-video.sh test-export-suite.sh" bash tests/run-all.sh ) \
  > "$TMP/suite.log" 2>&1
rc=$?
tail -25 "$TMP/suite.log" | sed 's/^/   /'
if [ "$rc" != 0 ]; then
  echo
  echo "❌ the shipped tree does not pass its own suite"
  grep -nE "FAILED|problem\(s\)" "$TMP/suite.log" | head -20 | sed 's/^/   /'
  exit 1
fi

echo
echo "✅ the tree a stranger installs passes the whole suite on its own"
