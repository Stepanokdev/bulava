#!/bin/bash
# Which Claude session a run IS — recorded by the session itself.
#
# The app shows the director what a worker did while he was away, and to do that it has to read the
# worker's transcript, which is named after the session id. Nothing knew that id: the app guessed it
# from the newest evidence directory, which a run that stalled or blocked early never writes, and
# then guessed the transcript by timestamp — and could pick the director's own interactive session,
# which overlaps the run because he is working in the same project.
#
# The session knows its own id, and its SessionStart hook already proves which run it belongs to
# (it matches the run nonce before writing handshake-ok). So it writes the id there too.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

PROJECT="$TMP/project"
mkdir -p "$PROJECT"
# The launcher writes the canonical path; on macOS $TMPDIR is a symlink into /private/var and the
# hook canonicalises the session's cwd before matching, so an unresolved path never matches.
PROJECT="$(canon_path "$PROJECT")"
SLUG="$(slug_for "$PROJECT")"
IDIR="$(instance_dir "$SLUG")"
mkdir -p "$IDIR"
printf '%s\n' "$PROJECT" > "$IDIR/project"
: > "$IDIR/started-at"
printf '%s\n' "$$" > "$IDIR/watchdog.pid"     # alive, so the instance counts as active

SID="7f3a1c22-0e5b-4d19-9a77-1b2c3d4e5f60"
fire() {   # fire <run-id-the-session-carries> <run-id-of-the-instance>
  printf '%s\n' "$2" > "$IDIR/run-id"
  rm -f "$IDIR/claude-session-id" "$IDIR/handshake-ok"
  printf '{"cwd":"%s","session_id":"%s"}' "$PROJECT" "$SID" \
    | ORCHESTRATOR_RUN_ID="$1" bash "$HOOK_DIR/safety-check.sh" >/dev/null 2>&1
}

echo "===== the session records its own id for the run it belongs to ====="

fire "run-A" "run-A"
if [ "$(cat "$IDIR/claude-session-id" 2>/dev/null)" = "$SID" ]; then
  ok "claude-session-id written at SessionStart"
else
  bad "no claude-session-id after a matching handshake (got: $(cat "$IDIR/claude-session-id" 2>/dev/null || echo none))"
fi
[ -f "$IDIR/handshake-ok" ] && ok "handshake still confirmed" || bad "handshake-ok lost"

echo "===== a session from a DIFFERENT run never claims this instance ====="

fire "run-B" "run-A"
if [ -e "$IDIR/claude-session-id" ]; then
  bad "a foreign run's session id was recorded"
else
  ok "mismatched run nonce writes nothing"
fi

echo "===== launching a run clears the previous run's handshake ====="
# Otherwise the app reads LAST night's session id and shows last night's work as this run's.

n="$(grep -c 'rm -f "$IDIR/handshake-ok" "$IDIR/claude-session-id"' "$BIN_DIR/night-shift.sh" || true)"
if [ "${n:-0}" -ge 2 ]; then
  ok "both launch paths clear the stale handshake ($n sites)"
else
  bad "only ${n:-0} launch path(s) clear the stale handshake — the other carries it over"
fi

[ "$fails" = 0 ] && echo "✅ session handshake OK" || echo "❌ $fails failure(s)"
exit "$fails"
