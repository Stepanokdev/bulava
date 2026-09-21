#!/bin/bash
# Run one suite twice — at the base commit and in the working tree — and refuse to call a failure
# pre-existing unless the base shows it too.
#
# Three suites in this repository were already red before this change, and saying so is easy and
# unfalsifiable: "I checked, it failed before." That is a claim, not evidence, and a reviewer is
# right to refuse it. This produces the evidence instead — a checkout of the base in a throwaway
# worktree, the same suite run in both, and the two failure counts compared. It exits non-zero the
# moment the working tree fails something the base did not, which is the only thing "pre-existing"
# is allowed to mean.
#
#   baseline-compare.sh test-limit-recovery.sh
#
# The base is the run's recorded base-sha when there is one, and HEAD otherwise — which is right
# for uncommitted work, where HEAD *is* the tree before the change.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SUITE="${1:?usage: baseline-compare.sh <test-name.sh>}"
[ -f "$HERE/$SUITE" ] || { echo "❌ немає такого набору: $SUITE" >&2; exit 2; }

BASE="${BASELINE_BASE_SHA:-}"
if [ -z "$BASE" ]; then
  BASE="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" || {
    echo "❌ не git-репозиторій — порівняти нема з чим" >&2; exit 2; }
fi

WT="$(mktemp -d)/base"
cleanup() {
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$WT")" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$REPO" worktree add --detach "$WT" "$BASE" >/dev/null 2>&1 || {
  echo "❌ не вдалося зробити worktree на $BASE" >&2; exit 2; }

count_failures() {   # $1=tree → prints the number of ❌ lines the suite produced there
  local tree="$1" out
  [ -f "$tree/engine/tests/$SUITE" ] || { printf 'absent'; return 0; }
  out="$(cd "$tree" && bash "engine/tests/$SUITE" 2>&1)"
  printf '%s' "$out" | grep -c '❌' | tr -d ' '
}

# Side by side, because the point is a comparison and doing it sequentially doubles the wall clock
# for nothing. Each suite builds its own state directory and isolates its own tmux socket, so the
# two runs share nothing but the machine.
OUT="$(mktemp -d)"
trap 'cleanup; rm -rf "$OUT" 2>/dev/null' EXIT
echo "── running $SUITE at the base ($BASE) and in the working tree, side by side"
( count_failures "$WT"   > "$OUT/before" ) &
_b=$!
( count_failures "$REPO" > "$OUT/after" ) &
_a=$!
wait "$_b" "$_a" 2>/dev/null || true
before="$(cat "$OUT/before" 2>/dev/null)"
after="$(cat "$OUT/after" 2>/dev/null)"

echo
echo "base: $before   working tree: $after"

if [ "$before" = absent ]; then
  # A suite this change introduced has no baseline to be compared against; it simply has to pass.
  [ "$after" = 0 ] && { echo "✅ новий набір, і він зелений"; exit 0; }
  echo "❌ новий набір і він червоний ($after)"; exit 1
fi
case "$before$after" in *[!0-9]*) echo "❌ не вдалося порахувати падіння"; exit 2 ;; esac

if [ "$after" -le "$before" ]; then
  echo "✅ ця зміна нічого тут не зламала (було $before, стало $after)"
  exit 0
fi
echo "❌ ця зміна додала падінь: було $before, стало $after"
exit 1
