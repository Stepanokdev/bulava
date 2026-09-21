#!/bin/bash
# A criterion that was wrong when the work started must be correctable — by the REVIEWER, on evidence,
# and never by the run itself.
#
# The failure this comes from: a plan written before anyone had read the code demanded "verified on
# iOS with the demo account" for a button the app renders only when NOT in demo mode. Unsatisfiable by
# construction. The run could report it unmet forever and nothing else — which is exactly what the
# director read, in every summary, after the work had actually been done and verified.
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ENGINE/bin"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
IDIR="$SUPERVISOR_STATE_DIR/instances/x"; mkdir -p "$IDIR"
echo "RUN-1" > "$IDIR/run-id"
jq -nc '{schema:1, task_id:"t", mode:"broad", objective:"Відкриття повідомлення в Telegram",
         acceptance:["Кнопка відкриває потрібне повідомлення.","Індикатор зникає.",
                     "Сценарій перевірено на iOS із демоакаунтом.","Без витоків памʼяті.",
                     "Помилка показується користувачу."],
         non_goals:[], surface:{}, write_paths:[], verification_profile:"standard"}' > "$IDIR/runspec.json"
. "$BIN_DIR/supervisor-lib.sh"

echo "===== criteria have stable ids, and the cap follows their number ====="
ids="$(runspec_acceptance "$IDIR" | cut -f1 | tr '\n' ' ')"
[ "$ids" = "AC-001 AC-002 AC-003 AC-004 AC-005 " ] && ok "ids are positional and stable" || bad "unexpected ids: $ids"
[ "$(runspec_acceptance_count "$IDIR")" = 5 ] && ok "counted five" || bad "miscounted"
[ "$(criteria_amendment_cap "$IDIR")" = 1 ] && ok "five criteria ⇒ at most one amendment" || bad "cap is $(criteria_amendment_cap "$IDIR")"
big="$TMP/big"; mkdir -p "$big"; jq -nc '{schema:1, mode:"broad", acceptance:[range(20)|tostring], write_paths:[]}' > "$big/runspec.json"
[ "$(criteria_amendment_cap "$big")" = 4 ] && ok "twenty criteria ⇒ at most four" || bad "cap scales wrong"

echo
echo "===== the run may propose, and only against a criterion that exists ====="
out="$(cd "$TMP" && IDIR="$IDIR" bash "$BIN_DIR/challenge-criterion.sh" AC-003 impossible_precondition \
  "Перевірено з авторизованим акаунтом" "MapScreen.swift:120 — кнопка лише під if !isDemo на базовому коміті" 2>&1)"
case "$out" in *"recorded challenge to AC-003"*) ok "a grounded challenge is recorded" ;; *) bad "challenge refused: $out" ;; esac
case "$out" in *"критерій лишається чинним"*) ok "and it says the criterion still stands until ruled on" ;;
  *) bad "the run is not told the criterion still holds" ;; esac

out="$(cd "$TMP" && IDIR="$IDIR" bash "$BIN_DIR/challenge-criterion.sh" AC-999 wrong_mode "x" "y" 2>&1)"
case "$out" in *"немає критерію 'AC-999'"*) ok "a challenge to something nobody agreed to is refused" ;;
  *) bad "an invented criterion was accepted" ;; esac

out="$(cd "$TMP" && IDIR="$IDIR" bash "$BIN_DIR/challenge-criterion.sh" AC-002 wrong_mode "x" 2>&1)"
case "$out" in *"без доказу"*) ok "a challenge with no evidence is refused" ;; *) bad "evidence is optional: $out" ;; esac

out="$(cd "$TMP" && IDIR="$IDIR" bash "$BIN_DIR/challenge-criterion.sh" AC-002 because_i_say_so "x" "y" 2>&1)"
case "$out" in *"невідома причина"*) ok "an invented reason code is refused" ;; *) bad "any reason goes: $out" ;; esac

echo
echo "===== the proposal is a proposal: nothing in the run's own files decides it ====="
if [ -f "$SUPERVISOR_STATE_DIR/runs/RUN-1/criteria-decisions.jsonl" ]; then
  bad "a decision appeared without any review"
else
  ok "no decision exists until the gate rules"
fi
# And the run cannot smuggle one in: the gate rewrites this file from the reviewer's own words every
# round, so anything planted here is replaced. Pinned as a boundary we intend to keep.
mkdir -p "$SUPERVISOR_STATE_DIR/runs/RUN-1"
echo '{"criterion":"AC-003","decision":"superseded","adjudicator":"worker"}' > "$SUPERVISOR_STATE_DIR/runs/RUN-1/criteria-decisions.jsonl"
if grep -q 'mv -f "$_rundir/criteria-decisions.jsonl.tmp"' "$ENGINE/hooks/review-gate.sh"; then
  ok "the gate replaces the decision file wholesale each round"
else
  bad "the gate appends to a file the run can write — a planted decision would survive"
fi

echo
echo "===== the gate judges against the contract, not against a plan file that is usually absent ====="
if grep -q 'CONTRACT_TEXT' "$ENGINE/hooks/review-gate.sh" \
   && grep -q 'ACCEPTANCE CRITERIA (the agreed contract' "$ENGINE/hooks/review-gate.sh"; then
  ok "the reviewer is handed the RunSpec's criteria"
else
  bad "the reviewer still judges against plan.md alone"
fi
if grep -q 'at the BASE commit' "$ENGINE/hooks/review-gate.sh"; then
  ok "and is told to verify a challenge at the base commit, not in the worker's tree"
else
  bad "nothing stops a worker breaking a feature to prove its criterion impossible"
fi

echo
[ "$fails" = 0 ] && echo "✅ criteria: correctable by the reviewer, on evidence, within a cap" \
                 || echo "❌ criteria: $fails problem(s)"
exit "$fails"
