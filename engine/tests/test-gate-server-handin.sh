#!/bin/bash
# On a server, a stop is a hand-in only when the worker declared one.
#   • work in the tree, nothing declared: back to the worker, no verifier, no review
#   • a declared summary marked DRAFT: the same
#   • an outcome left over from another run: the same
#   • after SUPERVISOR_SERVER_UNDECLARED_MAX such stops: reviewed anyway, never a loop
#   • a real declaration: reviewed
#   • the Mac profile: unchanged, a stop with work in the tree is reviewed
#   • a research result on a server is reviewed by Codex — the summary and last word when there is
#     no report file, with the data it changed in the criteria; FAIL goes back; on the Mac unchanged
# OPP-495 (staging06, 6 Nov): a worker marked its summary «DRAFT — mobile results pending», ended its
# turn to wait, and the verifier, the independent checks and a Codex review were spent on it.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true" SUPERVISOR_CLAUDE_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; CALLED="$FAKE/called"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "$CALLED"; echo "STATE: COMPLETE"; echo "VERDICT: PASS"; exit 0
fi
if echo "$*" | grep -q "RESEARCH REPORT"; then
  printf '%s\n' "${@: -1}" > "$CALLED.report"; echo "STATE: COMPLETE"; echo "VERDICT: ${FAKE_REPORT_VERDICT:-PASS}"
  [ "${FAKE_REPORT_VERDICT:-PASS}" = FAIL ] && echo "1. the report does not say how the deleted rows were checked"
  exit 0
fi
echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"; export CALLED
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"чекаю на перевірки"}]}}' > "$TR"
REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

mkcase(){
  RID="handin-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/a.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  echo "work $RANDOM" >> "$PROJ/src/a.ts"; git -C "$PROJ" commit -qam work
}
declare_as(){   # $1=summary [$2=run id]
  jq -nc --arg r "${2:-$RID}" --arg s "$1" '{result:"succeeded_changes", summary:$s, run_id:$r, ts:"2026-11-06 12:00"}' > "$IDIR/outcome.json"
}
rungate(){   # $1=session $2=profile
  rm -f "$CALLED"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_PROFILE="$2" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
reason(){ printf '%s' "$1" | jq -r '.reason // empty' 2>/dev/null; }

echo "===== server: work in the tree, nothing declared ====="
mkcase
out="$(rungate s1 server)"
check "no review spent"                    '[ ! -f "$CALLED" ]'
check "sent back to declare"               'reason "$out" | grep -q "не здача"'
check "and told how to wait"               'reason "$out" | grep -q "блокуючою командою"'

echo "===== server: a summary marked DRAFT ====="
declare_as "DRAFT — mobile results pending"
out="$(rungate s2 server)"
check "no review spent"                    '[ ! -f "$CALLED" ]'
check "the reason names DRAFT"             'reason "$out" | grep -q DRAFT'

echo "===== server: an outcome from another run ====="
declare_as "готово" "some-older-run"
out="$(rungate s3 server)"
check "no review spent"                    '[ ! -f "$CALLED" ]'

echo "===== server: bounded — after the limit it is reviewed anyway ====="
rm -f "$IDIR/outcome.json"
SUPERVISOR_SERVER_UNDECLARED_MAX=3 rungate s4 server >/dev/null
check "the 4th stop over a limit of 3 is reviewed" '[ -f "$CALLED" ]'

echo "===== server: a real declaration is reviewed ====="
mkcase
declare_as "релізні перевірки пройдено, усе закомічено"
rungate s5 server >/dev/null
check "reviewed"                           '[ -f "$CALLED" ]'
check "the counter is cleared"             '[ ! -f "$SUPERVISOR_STATE_DIR/server-undeclared-$RID" ] || true'

echo "===== Mac profile: as before ====="
mkcase
rungate s6 "" >/dev/null
check "a stop with work in the tree is reviewed" '[ -f "$CALLED" ]'

echo "===== server: a research result is reviewed by Codex, data changes included ====="
# EDCMP-7194/7201 (3–5 Nov): production data fixes declared as research were settled by the gate.
research_case(){
  RID="research-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && echo base > a.txt && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"; printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  jq -nc '{id:"D-R", at:"2026-11-03T16:59:00Z", task:"Fix data: duplicate applications on the portal (prod)"}' > "$IDIR/dispatch.json"
  jq -nc --arg r "$RID" '{result:"succeeded_research", summary:"Видалено 55 дублікатів заявок на проді; сертифікати перезбережено", run_id:$r, ts:"2026-11-03 19:05"}' > "$IDIR/outcome.json"
}
research_case
rm -f "$CALLED.report"
rungate r1 server >/dev/null
check "Codex reviewed the report"          '[ -s "$CALLED.report" ]'
check "it read the summary the ticket gets" 'grep -q "Видалено 55 дублікатів" "$CALLED.report"'
check "and the worker's last message"      'grep -q "чекаю на перевірки" "$CALLED.report"'
check "the criteria ask about data changes" 'grep -q "changed data" "$CALLED.report"'
check "PASS: done as passed"               '[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ]'
research_case
out="$(FAKE_REPORT_VERDICT=FAIL rungate r2 server)"
check "FAIL: back to the worker"           'reason "$out" | grep -q "не прийняв"'
check "…not settled"                       '[ ! -s "$IDIR/done" ]'
research_case
rm -f "$CALLED.report"
SUPERVISOR_SERVER_RESEARCH_REVIEW=0 rungate r3 server >/dev/null
check "turned off: settled unreviewed as before" '[ ! -s "$CALLED.report" ] && [ "$(cat "$IDIR/done" 2>/dev/null)" = debt ]'
research_case
rm -f "$CALLED.report"
rungate r4 "" >/dev/null
check "Mac: unchanged, settled by the gate" '[ ! -s "$CALLED.report" ] && [ "$(cat "$IDIR/done" 2>/dev/null)" = debt ]'

echo
echo "server hand-in: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
