#!/bin/bash
# A run must not spend a day failing on the review tooling.
#
# A CLI-started job ran twelve hours across six review rounds, every one of them topped by the same
# `[harness_failure]`: the verifier saw no stack, because the real projects were nested repositories
# inside a wrapper folder. Nothing stopped it. The existing short-circuit needs harness_failure to be
# the ONLY finding, and in broad mode the class taxonomy is not injected, so every other finding comes
# back untagged; and "progress" is judged by whether the NUMBER of findings shrank, which wobbled
# downward forever (7→5→3→5→4→3) while the blocker never moved.
#
# Two things are pinned here: the same wall twice parks for the operator, and a run that is genuinely
# being fixed round after round still gets its rounds.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
# These suites are about the gate's own logic, not about this machine's quota. Left to itself the
# gate asks the real Codex CLI how much window is left, and a developer whose window happens to be
# near the guard would watch every one of these fail for a reason that has nothing to do with them.
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"; RID="harness-loop-test"

pass=0; fail=0
ok(){ printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \xe2\x9d\x8c %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; export FAKE_N="$FAKE/n"
cat > "$FAKE/codex" <<'SH'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  echo "STATE: COMPLETE"; echo "VERDICT: FAIL"
  n=$(cat "$FAKE_N" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_N"
  [ -z "${FAKE_NO_HARNESS:-}" ] && echo "1. [harness_failure] UNPROVEN — verifier detected no stack"
  # Untagged extras whose COUNT wobbles downward, exactly as the real reviewer's did.
  case $n in 1) extra=6;; 2) extra=4;; 3) extra=2;; 4) extra=4;; 5) extra=3;; *) extra=2;; esac
  for i in $(seq 1 $extra); do echo "$((i+1)). evidence does not prove item $i"; done
else
  echo "VERDICT: PASS"
fi
SH
chmod +x "$FAKE/codex"

PROJ="$(mktemp -d)"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
  && echo base > a.txt && git add -A && git commit -qm init >/dev/null )
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "$RID" > "$IDIR/run-id"
printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
trap 'rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$PROJ" "$TR"' EXIT

# One round through the gate. The worker changes something every time, so the diff is never empty.
round(){ # $1 = session id
  echo "worker $RANDOM" >> "$PROJ/a.txt"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
rounds_until_parked(){ # $1 = session id ; echoes the round number it stopped on, or 0
  local i
  for i in $(seq 1 9); do
    round "$1" >/dev/null
    [ -f "$IDIR/done" ] && { echo "$i"; return; }
  done
  echo 0
}

echo "===== the same wall twice stops the run ====="
stopped_at="$(rounds_until_parked s-harness)"
check "parks by the second round, not the eighth" '[ "$stopped_at" = 2 ]'
check "parked for a person, not accepted"         '[ "$(cat "$IDIR/done")" = needs-user ]'
check "and says it was the tooling"               'grep -q "уперлось у САМ ІНСТРУМЕНТ" "$PROJ/BLOCKED.md" 2>/dev/null || grep -q "уперлось у САМ ІНСТРУМЕНТ" "$IDIR/reports/blocked.md" 2>/dev/null'

echo
echo "===== a run that is genuinely being fixed still gets its rounds ====="
rm -f "$IDIR/done" "$FAKE_N" "$SUPERVISOR_STATE_DIR"/harness-* "$SUPERVISOR_STATE_DIR"/rounds-* 2>/dev/null
stopped_at="$(FAKE_NO_HARNESS=1 rounds_until_parked s-normal)"
check "no harness complaint ⇒ the loop keeps its patience" '[ "$stopped_at" = 0 ] || [ "$stopped_at" -ge 4 ]'

echo
echo "===== the counter resets when the wall goes away ====="
rm -f "$IDIR/done" "$FAKE_N" "$SUPERVISOR_STATE_DIR"/harness-* "$SUPERVISOR_STATE_DIR"/rounds-* 2>/dev/null
round s-mixed >/dev/null                                    # round 1: harness present
check "counter recorded after a harness round" '[ -s "$SUPERVISOR_STATE_DIR/harness-$(printf %s "$RID" | tr -c "A-Za-z0-9_.-" "_")" ] || ls "$SUPERVISOR_STATE_DIR"/harness-* >/dev/null 2>&1'
FAKE_NO_HARNESS=1 round s-mixed >/dev/null                  # round 2: tooling fixed itself
check "counter cleared once the tooling stops complaining" '! ls "$SUPERVISOR_STATE_DIR"/harness-* >/dev/null 2>&1'
check "and the run was NOT parked for the operator"        '[ "$(cat "$IDIR/done" 2>/dev/null)" != needs-user ]'

echo "===== the counter does not outlive its run ====="
# RUN_KEY survives a re-dispatch, so a leaked counter would make the NEXT task park on its first
# tooling complaint and lose the honest round it is owed.
rm -f "$IDIR/done" "$FAKE_N" "$SUPERVISOR_STATE_DIR"/harness-* "$SUPERVISOR_STATE_DIR"/rounds-* 2>/dev/null
round s-leak >/dev/null                              # one harness round banked…
check "counter exists mid-run"                'ls "$SUPERVISOR_STATE_DIR"/harness-* >/dev/null 2>&1'
rm -f "$IDIR/done"
FAKE_STATE=BLOCKED round s-leak >/dev/null 2>&1 || true
# …and the run ends some OTHER way. Whatever the disposition, the counter must be gone.
check "counter gone once the run is over"     '! ls "$SUPERVISOR_STATE_DIR"/harness-* >/dev/null 2>&1 || [ ! -f "$IDIR/done" ]'

echo "===== a run that keeps coming back for hours parks itself ====="
# Bounds the LOOP, not the work: this is read at the Stop hook, so a single long build is untouched.
rm -f "$IDIR/done" "$FAKE_N" "$SUPERVISOR_STATE_DIR"/harness-* "$SUPERVISOR_STATE_DIR"/rounds-* 2>/dev/null
: > "$IDIR/started-at"
FAKE_NO_HARNESS=1 SUPERVISOR_MAX_RUN_SECONDS=99999 round s-clock >/dev/null
check "a fresh run is not touched by the ceiling" '[ ! -f "$IDIR/done" ]'

# Age the run past the ceiling without waiting for it.
touch -t 202401010000 "$IDIR/started-at"
FAKE_NO_HARNESS=1 SUPERVISOR_MAX_RUN_SECONDS=3600 round s-clock >/dev/null
check "an old run stops and asks for a person"    '[ "$(cat "$IDIR/done" 2>/dev/null)" = needs-user ]'

rm -f "$IDIR/done"; : > "$IDIR/started-at"
FAKE_NO_HARNESS=1 SUPERVISOR_MAX_RUN_SECONDS=0 round s-clock >/dev/null
check "zero disables it"                          '[ "$(cat "$IDIR/done" 2>/dev/null)" != needs-user ]'

echo
[ "$fail" -eq 0 ] && { echo "RESULT: $pass passed, 0 failed"; exit 0; } || { echo "RESULT: $fail failed"; exit 1; }
