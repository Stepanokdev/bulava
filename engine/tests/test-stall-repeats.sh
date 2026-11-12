#!/bin/bash
# Progress is judged by what comes back, not by how much (hooks/review-gate.sh):
#   • the reviewer is shown its own list from the last round and asked to mark what returned
#   • a round of different findings — however many — is progress: no stall
#   • the same findings back two rounds running park the run as stuck
#   • one finding of the last round gone is progress, even with the others back
#   • the review is told to weigh a defect by what it costs a person (proportion)
#   • a long project has no wall clock; an ordinary run is still handed back after it
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; PROMPT="$FAKE/prompt"; REVIEW="$FAKE/review"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  printf '%s\n' "${@: -1}" > "$PROMPT"
  echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; cat "$REVIEW"
  exit 0
fi
echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"; export PROMPT REVIEW
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"

REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

mkcase(){
  RID="stall-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/a.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**"],"objective":"ціла гра","acceptance":["гра цілком"]}' > "$IDIR/runspec.json"
}
piece(){ ( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" bash "$ROOT/bin/piece.sh" "$@" ); }
work(){ echo "$1 $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm "$1"; }
declare_done(){ jq -nc --arg r "$RID" --arg n "$RANDOM$RANDOM" '{result:"succeeded_changes", summary:("готово " + $n), run_id:$r, ts:"2026-10-27 12:00"}' > "$IDIR/outcome.json"; }
rungate(){
  rm -f "$PROMPT"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$RID" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
round(){ printf '%s\n' "$@" > "$REVIEW"; work "round $RANDOM"; declare_done; OUT="$(rungate)"; }
stall(){ cut -d' ' -f2 "$SUPERVISOR_STATE_DIR/rounds-meta-$RID" 2>/dev/null; }
log_has(){ grep -q "$1" "$SUPERVISOR_STATE_DIR/supervisor.log" 2>/dev/null; }
open_piece(){ piece plan "Фабрика" "Казино" >/dev/null; piece start -- "ящики їдуть стрічкою" >/dev/null; }

echo "===== new findings every round are progress ====="
mkcase; open_piece
round "1. [acceptance_failure] a.ts — ящик крізь конвеєр" "2. [acceptance_failure] a.ts — черга накладається" "3. [acceptance_failure] a.ts — FPS"
check "round 1: no stall"                          '[ "$(stall)" = 0 ]'
check "round 1: no previous list shown"            '! grep -q "WHAT YOU ASKED FOR LAST ROUND" "$PROMPT"'
check "the review is told about proportion"        'grep -q "^PROPORTION:" "$PROMPT"'
round "1. [acceptance_failure] a.ts — опора в ящику" "2. [acceptance_failure] a.ts — стрічка стоїть" "3. [acceptance_failure] a.ts — e2e"
check "round 2: the last list is shown"            'grep -q "WHAT YOU ASKED FOR LAST ROUND" "$PROMPT" && grep -q "ящик крізь конвеєр" "$PROMPT"'
check "round 2: three new findings, no stall"      '[ "$(stall)" = 0 ]'
round "1. [acceptance_failure] a.ts — a" "2. [acceptance_failure] a.ts — b" "3. [acceptance_failure] a.ts — c" "4. [acceptance_failure] a.ts — d"
check "round 3: more findings, all new: no stall"  '[ "$(stall)" = 0 ]'
check "not parked"                                 '! log_has "stalled at round"'
check "the worker is sent back"                    'echo "$OUT" | grep -q "\"block\""'

echo "===== the same findings back twice park it ====="
mkcase; open_piece
round "1. [acceptance_failure] a.ts — x" "2. [acceptance_failure] a.ts — y"
round "1. [acceptance_failure] [repeat] a.ts — x" "2. [acceptance_failure] [repeat] a.ts — y"
check "both back: stall 1"                         '[ "$(stall)" = 1 ]'
round "1. [acceptance_failure] [repeat] a.ts — x" "2. [acceptance_failure] [repeat] a.ts — y"
check "both back again: stall 2"                   '[ "$(stall)" = 2 ]'
check "parked as stuck"                            'log_has "stalled at round"'

echo "===== one gone is progress ====="
mkcase; open_piece
round "1. [acceptance_failure] a.ts — x" "2. [acceptance_failure] a.ts — y"
round "1. [acceptance_failure] [repeat] a.ts — x" "2. [acceptance_failure] a.ts — z" "3. [acceptance_failure] a.ts — w"
check "one of two fixed: no stall"                 '[ "$(stall)" = 0 ]'

echo "===== wall clock: none for a long project, 8h for the rest ====="
mkcase; open_piece
touch -t 202601010000 "$IDIR/started-at"
round "1. [acceptance_failure] a.ts — x"
check "long project: not parked by the clock"      '! log_has "run age"'
mkcase
touch -t 202601010000 "$IDIR/started-at"
round "1. [acceptance_failure] a.ts — x"
check "ordinary run: parked by the clock"          'log_has "run age"'
check "the default clock is 8h"                    '( unset SUPERVISOR_MAX_RUN_SECONDS; . "$ROOT/supervisor/config.sh"; [ "$SUPERVISOR_MAX_RUN_SECONDS" = 28800 ] )'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
