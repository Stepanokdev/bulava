#!/bin/bash
# The same flow, against the REAL Claude and the REAL Codex — cheaply.
#
# Everything else in tests/ stubs the engines, which proves the orchestration and nothing about the
# models. This proves the parts only a real call can: that two independent readings of one prompt
# actually come back different, that a follow-up costs a fraction of opening a task, and that a
# consultation answers the question it was asked.
#
# It is NOT named test-*.sh on purpose: `run-all.sh` must never spend a director's window. Run it
# by hand, and only when the collaboration flow itself has changed.
#
#     NS_LIVE_SMOKE=1 bash engine/tests/smoke-live-peer.sh
#
# Minimum depth, short ceilings, a throwaway repository of four small files. A full pass is a
# handful of low-effort calls — single-digit minutes and a sliver of either window.
set -u
[ "${NS_LIVE_SMOKE:-0}" = 1 ] || {
  cat <<'WHY'
This one calls the real models. It is skipped unless you ask for it:

    NS_LIVE_SMOKE=1 bash engine/tests/smoke-live-peer.sh

Skipping is a SKIP, not a pass: run it with NS_LIVE_SMOKE=1 to get a verdict.
WHY
  exit 0
}
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
note(){ printf '  \xc2\xb7 %s\n' "$1"; }

export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
# The cheapest depth either CLI offers, and ceilings low enough that a hung call fails the smoke
# rather than eating the evening.
export SUPERVISOR_CLAUDE_EFFORT="${NS_SMOKE_CLAUDE_EFFORT:-low}"
export SUPERVISOR_CODEX_EFFORT="${NS_SMOKE_CODEX_EFFORT:-low}"
export SUPERVISOR_PLAN_TIMEOUT="${NS_SMOKE_CALL_TIMEOUT:-240}"
export SUPERVISOR_RESEARCH_TIMEOUT="${NS_SMOKE_CALL_TIMEOUT:-240}"
export SUPERVISOR_DESIGN_TIMEOUT="${NS_SMOKE_CALL_TIMEOUT:-240}"
export SUPERVISOR_CONSULT_TIMEOUT="${NS_SMOKE_CALL_TIMEOUT:-240}"
export SUPERVISOR_PREFLIGHT_TOTAL_TIMEOUT=900
export SUPERVISOR_FOLLOWUP_TOTAL_TIMEOUT=300
export SUPERVISOR_DESIGN_RESEARCH=0
. "$BIN/supervisor-lib.sh"

# Asked for explicitly, so a missing CLI is a FAILED check and not a quiet pass. A verification
# that reports success because it could not run is worse than no verification: it puts a green
# tick next to a claim nothing tested.
for cli in claude codex jq git; do
  command -v "$cli" >/dev/null 2>&1 \
    || { echo "❌ немає $cli у PATH — цю перевірку неможливо виконати, і вона НЕ вважається пройденою"; exit 1; }
done

# A repository small enough to read in seconds and real enough to have an opinion about.
PROJ="$TMP/project"; mkdir -p "$PROJ/src"
cat > "$PROJ/README.md" <<'EOF'
# Ledger

A tiny command-line ledger. `add` records an entry, `total` prints the sum.
EOF
cat > "$PROJ/src/ledger.py" <<'EOF'
import json, sys, pathlib

STORE = pathlib.Path("ledger.json")

def load():
    if STORE.exists():
        return json.loads(STORE.read_text())
    return []

def add(amount, note):
    rows = load()
    rows.append({"amount": float(amount), "note": note})
    STORE.write_text(json.dumps(rows))

def total():
    return sum(r["amount"] for r in load())

if __name__ == "__main__":
    if sys.argv[1] == "add":
        add(sys.argv[2], sys.argv[3])
    else:
        print(total())
EOF
printf 'ledger.json\n' > "$PROJ/.gitignore"
git -C "$PROJ" init -q
git -C "$PROJ" add -A
git -C "$PROJ" -c user.email=smoke@test -c user.name=smoke commit -qm "initial ledger" >/dev/null

SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "$(session_name "$SLUG")" > "$IDIR/session"
printf '%s\n' "SMOKE-RUN" > "$IDIR/run-id"
printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
: > "$IDIR/direct-chat"
ln -sf "$BIN/consult-codex.sh" "$IDIR/consult-codex"

OPEN_TASK="Додай команду report, яка показує підсумок за нотатками, і покрий її тестом."
FOLLOW_UP="закоміть це і постав тег v0.2"

run_stage() {   # $1=art  $2=stage  [$3=engine]  — echoes the seconds it took
  local art="$1" stage="$2" engine="${3:-}" s e
  s="$(date +%s)"
  if [ -n "$engine" ]; then
    bash "$BIN/preflight.sh" --art "$art" --stage "$stage" --engine "$engine" "$PROJ" "$4" >/dev/null 2>&1
  else
    bash "$BIN/preflight.sh" --art "$art" --stage "$stage" "$PROJ" "$4" >/dev/null 2>&1
  fi
  e="$(date +%s)"; printf '%s' "$((e - s))"
}

echo "===== opening a task: two engineers, one prompt, two readings ====="
A="$IDIR/messages/open"; mkdir -p "$A"
t0="$(date +%s)"
PIPE_RELATION=new run_stage "$A" context "" "$OPEN_TASK" >/dev/null
[ -s "$A/peer-prompt.txt" ] && ok "a prompt was prepared for both" || bad "no peer prompt was written"
run_stage "$A" peer claude "$OPEN_TASK" >/dev/null &
p1=$!
run_stage "$A" peer codex "$OPEN_TASK" >/dev/null &
p2=$!
wait "$p1" 2>/dev/null; wait "$p2" 2>/dev/null
open_secs=$(( $(date +%s) - t0 ))

[ -s "$A/peer-claude.md" ] && ok "Claude produced a position ($(wc -c < "$A/peer-claude.md" | tr -d ' ') bytes)" \
  || bad "Claude produced nothing — see $A/logs/peer-claude.log"
[ -s "$A/peer-codex.md" ] && ok "Codex produced a position ($(wc -c < "$A/peer-codex.md" | tr -d ' ') bytes)" \
  || bad "Codex produced nothing — see $A/logs/peer-codex.log"
if [ -s "$A/peer-claude.md" ] && [ -s "$A/peer-codex.md" ]; then
  cmp -s "$A/peer-claude.md" "$A/peer-codex.md" \
    && bad "the two positions are byte-identical — they are not independent readings" \
    || ok "and the two readings differ, which is the entire point of asking twice"
  # A position that names nothing in the repository is a position about no repository.
  grep -qE 'ledger|README|report|total' "$A/peer-claude.md" && grep -qE 'ledger|README|report|total' "$A/peer-codex.md" \
    && ok "both actually read this repository" \
    || bad "at least one position never mentions anything in the project"
fi
run_stage "$A" align "" "$OPEN_TASK" >/dev/null
[ -s "$A/peer-alignment.md" ] && ok "the comparison produced material deltas" \
  || note "alignment unavailable — degraded, which is allowed"
[ -s "$A/plan.md" ] && ok "and the working brief was settled" || bad "no working brief"
note "opening the task took ${open_secs}s"

echo "===== the follow-up: same conversation, a fraction of the cost ====="
thread_bind "$IDIR" "$OPEN_TASK" "smoke-1" "00000001" new >/dev/null
cp -f "$A/peer-alignment.md" "$IDIR/peer-alignment.md" 2>/dev/null || true
thread_bind "$IDIR" "$FOLLOW_UP" "smoke-2" "00000002" >/dev/null
B="$IDIR/messages/follow"; mkdir -p "$B"
t0="$(date +%s)"
PIPE_RELATION=continue run_stage "$B" context "" "$FOLLOW_UP" >/dev/null
[ "$(tr -d '[:space:]' < "$B/.scale")" = followup ] && ok "it is prepared as a follow-up" \
  || bad "the follow-up ran the opening stage"
run_stage "$B" peer claude "$FOLLOW_UP" >/dev/null &
p1=$!
run_stage "$B" peer codex "$FOLLOW_UP" >/dev/null &
p2=$!
wait "$p1" 2>/dev/null; wait "$p2" 2>/dev/null
follow_secs=$(( $(date +%s) - t0 ))

[ -s "$B/peer-claude.md" ] && [ -s "$B/peer-codex.md" ] \
  && ok "both engines still read it — participation is not what got cheaper" \
  || bad "the follow-up lost a reading"
# The shape of the answer is what says the models understood the framing: a follow-up position is
# a READING of a request, not a fresh plan for the whole task.
if [ -s "$B/peer-codex.md" ]; then
  grep -qiE 'READING|RISK' "$B/peer-codex.md" \
    && ok "Codex answered in the follow-up shape rather than re-planning the task" \
    || bad "Codex re-planned the whole task: $(head -c 160 "$B/peer-codex.md")"
fi
if [ -s "$B/peer-claude.md" ]; then
  grep -qiE 'READING|RISK' "$B/peer-claude.md" \
    && ok "and so did Claude" \
    || bad "Claude re-planned the whole task: $(head -c 160 "$B/peer-claude.md")"
fi
# The release word is the one a follow-up must not shrug at.
grep -qiE 'тег|tag|незворотн|irrevers|v0\.2' "$B/peer-codex.md" "$B/peer-claude.md" 2>/dev/null \
  && ok "the irreversible step in the request was noticed" \
  || note "neither position mentioned the tag — worth reading $B/peer-*.md by hand"
note "the follow-up took ${follow_secs}s against ${open_secs}s to open the task"
[ "$follow_secs" -lt "$open_secs" ] \
  && ok "a follow-up is cheaper than opening a task, which was the complaint" \
  || bad "the follow-up cost as much as the opening — nothing was saved"

echo "===== a consultation answers the question it was asked ====="
jq -nc --arg t "$OPEN_TASK" '{id:"SMOKE-DISPATCH", task:$t}' > "$IDIR/dispatch.json"
q="У src/ledger.py стан тримається у ledger.json поруч із робочою текою. Чи є конкретний випадок, у якому додавання команди report зламає наявні дані, і який мінімальний тест його ловить?"
t0="$(date +%s)"
ANSWER="$( cd "$PROJ" && ORCHESTRATOR_RUN_ID=SMOKE-RUN bash "$BIN/consult-codex.sh" "$q" 2>&1 )"
rc=$?
consult_secs=$(( $(date +%s) - t0 ))
if [ "$rc" = 0 ]; then
  case "$ANSWER" in *RECOMMENDATION*) ok "the consultation came back in the agreed shape" ;;
    *) bad "the answer has no RECOMMENDATION section: $(printf '%s' "$ANSWER" | head -c 200)" ;; esac
  case "$ANSWER" in *ledger*|*Ledger*) ok "and it is about THIS repository" ;;
    *) bad "the answer never mentions the code it was asked about" ;; esac
  note "the consultation took ${consult_secs}s"
elif [ "$rc" = 75 ]; then
  note "Codex declined (no window left) — and said so in seconds rather than waiting hours:"
  note "$(printf '%s' "$ANSWER" | head -c 200)"
  ok "an unavailable Codex degrades instead of freezing the implementer"
else
  bad "the consultation failed (exit $rc): $(printf '%s' "$ANSWER" | head -c 200)"
fi

echo
echo "  artefacts kept at: $A and $B"
echo "  (the temp tree is removed on exit — copy anything you want to read)"
cp -r "$IDIR/messages" "${NS_SMOKE_KEEP:-$TMP}/kept" 2>/dev/null || true
[ -n "${NS_SMOKE_KEEP:-}" ] && echo "  copied to ${NS_SMOKE_KEEP}/kept"
echo
[ "$fails" = 0 ] && { echo "✅ live peer smoke: all $pass passed"; exit 0; }
echo "❌ live peer smoke: $fails failure(s)"; exit 1
