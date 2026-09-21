#!/bin/bash
# Claude's limits come from the endpoint the CLI itself uses, not from a statusline render.
#
# They used to come only from a statusline render, which happens only while an interactive session is
# open. On this machine usage.json was EIGHT DAYS stale while workers ran every night — and the
# watchdog and the review gate consult that file to decide whether there is room to work, so they were
# deciding on week-old numbers. `claude` has no `usage` subcommand, but it does call
# `GET /api/oauth/usage` with the subscription token macOS keeps in the Keychain.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "===== the script exists, and never leaks the token ====="

[ -x "$BIN_DIR/claude-usage.sh" ] && ok "claude-usage.sh is executable" || bad "no claude-usage.sh"
grep -q "Claude Code-credentials" "$BIN_DIR/claude-usage.sh" \
  && ok "reads the token from the Keychain" || bad "does not use the Keychain"
grep -qE 'echo .*token|print\(.*token|log.*token' "$BIN_DIR/claude-usage.sh" \
  && bad "the token appears in output somewhere" || ok "the token is never printed"
grep -q "api/oauth/usage" "$BIN_DIR/claude-usage.sh" \
  && ok "asks the endpoint the CLI asks" || bad "no endpoint in the script"

echo "===== it writes the shape everything already reads ====="

# Run for real: this machine has the credential. Offline or expired, the script is a no-op by design,
# so the suite treats "no file written" as a skip rather than a failure.
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
bash "$BIN_DIR/claude-usage.sh" >/dev/null 2>&1
if [ ! -s "$SUPERVISOR_STATE_DIR/usage.json" ]; then
  echo "  (SKIP: no answer from the endpoint — offline or the token needs a refresh)"
else
  ok "usage.json written"
  for field in ts source five_hour seven_day; do
    jq -e --arg f "$field" 'has($f)' "$SUPERVISOR_STATE_DIR/usage.json" >/dev/null 2>&1 \
      && ok "carries $field" || bad "missing $field"
  done
  [ "$(jq -r '.source' "$SUPERVISOR_STATE_DIR/usage.json")" = oauth ] \
    && ok "marked as coming from the endpoint" || bad "source is not oauth"
  # Percentages, and epoch resets — not ISO strings, because that is what the readers expect.
  jq -e '.five_hour.used_percentage >= 0 and .five_hour.used_percentage <= 100' \
     "$SUPERVISOR_STATE_DIR/usage.json" >/dev/null 2>&1 \
    && ok "the five-hour percentage is a percentage" || bad "five_hour out of range"
  jq -e '(.seven_day.resets_at // 0) > 1700000000' "$SUPERVISOR_STATE_DIR/usage.json" >/dev/null 2>&1 \
    && ok "the weekly reset is an epoch, not an ISO string" || bad "resets_at is not an epoch"
  # And it must be FRESH — the whole point.
  now="$(date +%s)"
  ts="$(jq -r '.ts' "$SUPERVISOR_STATE_DIR/usage.json")"
  [ $(( now - ts )) -lt 120 ] && ok "and it is current, with no session running" \
                              || bad "wrote a stale timestamp"
fi

echo "===== a missing credential is a no-op, not a broken file ====="

rm -f "$SUPERVISOR_STATE_DIR/usage.json"
printf 'not json\n' > "$SUPERVISOR_STATE_DIR/usage.json"
PATH="/usr/bin:/bin" bash "$BIN_DIR/claude-usage.sh" >/dev/null 2>&1 || true
# Whatever happened, it must not have left a half-written file: either valid JSON or the original.
if jq -e . "$SUPERVISOR_STATE_DIR/usage.json" >/dev/null 2>&1 \
   || [ "$(cat "$SUPERVISOR_STATE_DIR/usage.json")" = "not json" ]; then
  ok "never leaves a half-written file behind"
else
  bad "left the file in a broken state"
fi

echo "===== the app calls the engine's scripts by absolute path ====="

# Only `night-shift` is symlinked onto PATH. Calling the others by bare name was a silent no-op
# swallowed by `|| true` — which is why the usage files were hours and days old while the app showed
# them as current.
APP_SRC="$BIN_DIR/../../Night Shift/Engine/SupervisorClient.swift"
if [ -f "$APP_SRC" ]; then
  grep -q 'private func engineScript' "$APP_SRC" \
    && ok "there is one place that resolves an engine script" || bad "no absolute-path helper"
  grep -q 'engineScript("codex-usage.sh"' "$APP_SRC" \
    && ok "codex usage goes through it" || bad "codex usage is still called by bare name"
  grep -q 'engineScript("claude-usage.sh"' "$APP_SRC" \
    && ok "claude usage goes through it" || bad "claude usage is still called by bare name"
else
  echo "  (SKIP: app sources not next to the engine)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
