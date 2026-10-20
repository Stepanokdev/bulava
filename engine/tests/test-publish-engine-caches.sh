#!/bin/bash
# The export after the suite has run.
#
# Running the suite leaves Python bytecode caches in the checkout — test-permission-gate.sh imports
# bin/lib/permission-policy.py and Python writes bin/lib/__pycache__ beside it. A .pyc carries the
# absolute path it was compiled from, so the folder's name went into the export with it, and the
# audit refused: test-clean-install.sh passed on a fresh checkout and failed on one the suite had
# already run in. Caches are dropped from what ships; the audit still reads everything that does.
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A machine that has worked in a client's folder: the audit refuses its name anywhere in an export.
# Put together here rather than written out, because this file ships too and the audit reads it.
NAME="$(printf '%s-%s-%s' Ledger Client Copy)"
STATE="$TMP/state"; mkdir -p "$STATE/instances/one"
echo "/work/$NAME" > "$STATE/instances/one/project"

publish() {  # $1 = engine, $2 = out
  SUPERVISOR_STATE_DIR="$STATE" bash "$1/bin/publish-engine.sh" "$2" >"$TMP/publish.log" 2>&1
}
pyc() {  # $1 = file: what Python writes there — a header, then the source's absolute path among bytes
  mkdir -p "$(dirname "$1")"
  printf '\x6f\x0d\x0d\x0a\x00\x00\x00\x00/work/%s/engine/bin/lib/permission-policy.py\x00' "$NAME" > "$1"
}

echo "===== caches the suite left in the checkout ====="
cp -R "$ENGINE" "$TMP/cached"
pyc "$TMP/cached/bin/lib/__pycache__/permission-policy.cpython-314.pyc"
pyc "$TMP/cached/hooks/stray.pyc"
if publish "$TMP/cached" "$TMP/out"; then
  ok "the engine still exports"
else
  bad "the export was refused over a cache: $(grep -m2 '❌' "$TMP/publish.log" | tr '\n' ' ')"
fi
left="$( [ -d "$TMP/out" ] && find "$TMP/out" \( -name '__pycache__' -o -name '*.pyc' \) | head -3)"
[ -d "$TMP/out" ] && [ -z "$left" ] \
  && ok "and carries no bytecode, nested or not" \
  || bad "bytecode in the export: ${left:-no export at all}"

echo
echo "===== the same name in a file that ships ====="
cp -R "$ENGINE" "$TMP/named"
echo "notes from /work/$NAME" > "$TMP/named/bin/lib/notes.txt"
if publish "$TMP/named" "$TMP/out-named"; then
  bad "the audit let a folder's name ship — it is meant to read everything that goes out"
else
  grep -q "$NAME" "$TMP/publish.log" \
    && ok "the audit still refuses it, and names it" \
    || bad "refused, but not for the name: $(tail -3 "$TMP/publish.log" | tr '\n' ' ')"
fi
[ ! -e "$TMP/out-named" ] && ok "and a refused export leaves nothing behind" || bad "a refused export was written"

echo
[ "$fails" = 0 ] && echo "✅ export after a suite run: caches stay home, the audit still reads the rest" \
                 || echo "❌ export after a suite run: $fails problem(s)"
exit "$fails"
