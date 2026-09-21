#!/bin/bash
# A task is judged by its own contract — and nothing else may overrule it.
#
# The director asked for one button. The targeted review passed it, and then a whole-product
# release-readiness audit vetoed it and ordered the worker to "close every critical gap". It did:
# 33 files, 1225 lines nobody asked for, force-landed on main, followed by a question about App
# Store scope he could not read. The audit was right about the product and had no business judging
# this task.
#
# The signal that caused it: `mode=broad`, which every task from the conversation gets, because it
# means "write_paths unknown" — not "unbounded".
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"

pass=0; fail=0
ok(){ printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \xe2\x9d\x8c %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

IDIR="$SUPERVISOR_STATE_DIR/instances/t"; mkdir -p "$IDIR"
trap 'rm -rf "$SUPERVISOR_STATE_DIR"' EXIT

echo "===== what makes a run bound by its own task ====="

# Exactly the RunSpec the app produced for "move the button".
cat > "$IDIR/runspec.json" <<'JSON'
{"schema":1,"task_id":"f82a2d17","mode":"broad","write_paths":[],
 "objective":"Перенести кнопку «Новий чат» у фіксований хедер",
 "acceptance":["Кнопка у фіксованому хедері праворуч.","Лишається видимою після скролу."]}
JSON
check "broad + objective + acceptance IS task-bound"  'runspec_task_bound "$IDIR"'

# A night run with no contract of its own — nothing to judge it against.
cat > "$IDIR/runspec.json" <<'JSON'
{"schema":1,"mode":"broad","write_paths":[],"objective":"","acceptance":[]}
JSON
check "no objective, no criteria ⇒ NOT task-bound"    '! runspec_task_bound "$IDIR"'

# An objective with nothing to check it against is not a contract either.
cat > "$IDIR/runspec.json" <<'JSON'
{"schema":1,"task_id":"abc","mode":"broad","objective":"Зроби добре","acceptance":[]}
JSON
check "objective with no criteria ⇒ NOT task-bound"   '! runspec_task_bound "$IDIR"'

rm -f "$IDIR/runspec.json"
check "no runspec at all ⇒ NOT task-bound"            '! runspec_task_bound "$IDIR"'

echo
echo "===== the gate reads it that way ====="
GATE="$ROOT/hooks/review-gate.sh"
check "the review is bounded by the task contract"    'grep -q "runspec_task_bound" "$GATE"'
check "how the run was STARTED never picks the machine" \
      '! grep -qE "direct-chat\" \] && BOUNDED=1|BOUNDED=1.*direct-chat" "$GATE"'
# Anchored on CODE, not on a comment: the property is that the advisory-only override happens
# BEFORE the bounded branch, so it applies to every run rather than only to scoped ones. Line
# numbers say that; a comment that happens to sit above it does not, and anchoring there broke the
# moment comments were removed.
check "the class rules are not bounded-only"           \
      '[ "$(grep -n "advisory-only FAIL overridden" "$GATE" | head -1 | cut -d: -f1)" \
         -lt "$(grep -n "if \[ \"\$BOUNDED\" = 1 \]; then" "$GATE" | tail -1 | cut -d: -f1)" ]'
check "recent human turns define chat scope"           'grep -q "RECENT HUMAN TURNS" "$GATE"'
check "product concerns cannot fail a chat task"       'grep -q "release readiness, old backlog and unrelated files are not acceptance criteria" "$GATE"'

echo
echo "===== and nothing audits the whole product behind his back ====="
check "no audit after every stop"                     '! grep -q "deep-audit.sh.*Ранкове підсумкове" "$ROOT/bin/night-shift.sh"'
check "review gate never launches a full audit"       '! grep -q "BIN_DIR/deep-audit.sh" "$GATE"'
check "no self-learning runs when a night ends"        '! grep -q "learn.sh" "$ROOT/bin/night-shift.sh"'
check "the audit tool itself is untouched"            '[ -x "$ROOT/bin/deep-audit.sh" ]'
check "the explicit slash command still exists"       '[ -f "$ROOT/claude-commands/deep-audit.md" ]'

echo
[ "$fail" -eq 0 ] && { echo "RESULT: $pass passed, 0 failed"; exit 0; } || { echo "RESULT: $fail failed"; exit 1; }
