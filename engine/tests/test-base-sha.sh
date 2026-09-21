#!/bin/bash
# The commit a run measures itself against, in the repository shapes that break it.
#
# A run in a brand-new empty folder came back saying it had changed nothing, after five commits and
# forty-four tests. `git rev-parse HEAD` in a repository with no commits does not fail quietly — it
# prints the word HEAD on stdout and exits 128, and `2>/dev/null || true` turned that into the base
# commit. Every guard downstream let it through, because once the worker HAS committed, `HEAD` is a
# perfectly good revision: `git diff HEAD` then compares the tree against the work just committed,
# comes back empty, and the gate parks the run for having done nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/engine/bin/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
commit_in() {
  ( cd "$1" && git add -A >/dev/null 2>&1
    git -c user.email=t@t -c user.name=t commit -qm "$2" >/dev/null 2>&1 )
}

echo "===== a repository with no commits yet ====="
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"; git init -q "$EMPTY"
raw="$(cd "$EMPTY" && git rev-parse HEAD 2>/dev/null || true)"
[ "$raw" = "HEAD" ] \
  && ok "git itself still prints the word HEAD here — this is what the fix is for" \
  || bad "git no longer prints HEAD in an unborn repo (was «${raw}») — revisit this test"

got="$(resolve_base_sha "$EMPTY")"
[ -z "$got" ] && ok "nothing is resolved, so nothing is written down" \
               || bad "resolved «${got}» where there is no commit"

echo
echo "===== a normal repository ====="
NORM="$TMP/normal"; mkdir -p "$NORM"; git init -q "$NORM"
echo one > "$NORM/a.txt"; commit_in "$NORM" first
want="$(cd "$NORM" && git rev-parse HEAD)"
[ "$(resolve_base_sha "$NORM")" = "$want" ] && ok "the real commit is resolved" \
  || bad "wrong commit for a normal repository"

echo
echo "===== reading what an older run left behind ====="
IDIR="$TMP/idir"; mkdir -p "$IDIR"
printf 'HEAD\n' > "$IDIR/base-sha"
[ -z "$(read_base_sha "$IDIR")" ] \
  && ok "the word HEAD on disk is refused — instance folders already hold it" \
  || bad "the word HEAD was accepted as a commit"
printf '%s\n' "$want" > "$IDIR/base-sha"
[ "$(read_base_sha "$IDIR")" = "$want" ] && ok "a real sha is read back" \
  || bad "a real sha was not read back"
printf '  %s  \n' "$want" > "$IDIR/base-sha"
[ "$(read_base_sha "$IDIR")" = "$want" ] && ok "whitespace around it does not matter" \
  || bad "surrounding whitespace broke it"
printf 'refs/heads/main\n' > "$IDIR/base-sha"
[ -z "$(read_base_sha "$IDIR")" ] && ok "a branch name is not a commit either" \
  || bad "a ref name was accepted as a commit"
rm -f "$IDIR/base-sha"
[ -z "$(read_base_sha "$IDIR")" ] && ok "no file, no base" || bad "invented a base from nothing"
[ -z "$(read_base_sha "")" ] && ok "no instance folder, no base" || bad "invented a base with no folder"

echo
echo "===== the whole failure, end to end ====="
# Exactly what happened: an empty folder, work done in it, commits made — and then the question the
# gate asks, «has anything changed since the base?»
REPRO="$TMP/repro"; mkdir -p "$REPRO"; git init -q "$REPRO"
BAD="$(cd "$REPRO" && git rev-parse HEAD 2>/dev/null || true)"     # the old line, verbatim
GOOD="$(resolve_base_sha "$REPRO")"                                 # the new one
echo "work" > "$REPRO/feature.py"; commit_in "$REPRO" "the work"
echo "more" > "$REPRO/second.py"; commit_in "$REPRO" "more work"

seen_bad="$( [ -n "$BAD" ] && git -C "$REPRO" cat-file -e "$BAD" 2>/dev/null \
             && git -C "$REPRO" diff "$BAD" --stat 2>/dev/null )"
[ -z "$seen_bad" ] \
  && ok "with the old line the gate sees an empty diff after two commits — the run parks" \
  || bad "could not reproduce the original failure"

if [ -z "$GOOD" ]; then
  changed="$(git -C "$REPRO" log --oneline 2>/dev/null)"
  [ -n "$changed" ] \
    && ok "with the fix there is no false base, and the commits are there to be seen" \
    || bad "no base and no commits either"
else
  bad "an empty repository must not produce a base commit (got «${GOOD}»)"
fi

echo
echo "===== the same validation on the way back out of an old evidence.json ====="
# report.sh falls back to the base recorded in evidence.json when the instance folder has none.
# That evidence was written by a run whose base-sha was the word HEAD, so it holds the word HEAD —
# and taking it unchecked put the empty diff straight back.
[ -z "$(only_object_id 'HEAD')" ] && ok "the word HEAD is refused there too" \
                                  || bad "the word HEAD came back through evidence.json"
[ -z "$(only_object_id '')" ] && ok "an absent value stays absent" || bad "invented a base from nothing"
[ "$(only_object_id "  $want  ")" = "$want" ] && ok "a real sha still passes" \
                                              || bad "a real sha was refused"

echo
echo "===== starting in an empty folder leaves something to measure against ====="
# The other half of the fix: the start path already tries to make a first commit, and in a folder
# with no files there was nothing to stage, so it made none. The run then had no base at all.
FRESH="$TMP/fresh"; mkdir -p "$FRESH"; git init -q "$FRESH"
if [ -z "$(resolve_base_sha "$FRESH")" ]; then
  ok "an untouched empty folder has no base — which is why the start path has to make one"
else
  bad "an empty folder reported a base commit"
fi
# What night-shift.sh now does when there is nothing to stage.
( cd "$FRESH" && git -c user.email=night-shift@local -c user.name=night-shift \
    commit -q --allow-empty -m "Initial commit (before night shift)" >/dev/null 2>&1 )
BASE="$(resolve_base_sha "$FRESH")"
[ -n "$BASE" ] && ok "after the empty first commit there is a real base" \
                || bad "still no base after the empty first commit"
echo "built" > "$FRESH/app.py"; commit_in "$FRESH" "the work"
seen="$(git -C "$FRESH" diff "$BASE" --stat 2>/dev/null)"
printf '%s' "$seen" | grep -q 'app.py' \
  && ok "and the work done afterwards is visible to the gate" \
  || bad "the gate still cannot see the work (diff was «${seen}»)"

echo
[ "$fails" = 0 ] && { echo "✅ base-sha: a run measures itself against a real commit, or against none"; exit 0; }
echo "❌ base-sha: $fails check(s) failed"; exit 1
