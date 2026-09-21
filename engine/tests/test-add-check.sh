#!/bin/bash
# Proving a claim a build system cannot express.
#
# `verify.sh` proves things by running the stack's own build and test commands, so a criterion like
# "the button is still visible after scrolling, and tapping it opens a new chat" could never enter
# evidence.json. A run that verified exactly that on a simulator was failed — correctly, under the
# rules the reviewer had — for evidence the harness gave it no way to produce.
#
# The rule this keeps: the run registers a COMMAND, never a verdict. The status is the exit code
# the ENGINE observed, and the command is written down for the reviewer to judge.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"

pass=0; fail=0
ok(){ printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \xe2\x9d\x8c %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

PROJ="$(mktemp -d)"; cd "$PROJ" || exit 1
git init -q; git config user.email t@t; git config user.name t
echo hi > a.txt; git add -A; git commit -qm base
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
trap 'rm -rf "$SUPERVISOR_STATE_DIR" "$PROJ"' EXIT

ADD="$ROOT/bin/add-check.sh"

echo "===== a check is a command, not a claim ====="
out="$(IDIR="$IDIR" bash "$ADD" "AC-004: кнопка видима після скролу" 2>&1)"; rc=$?
check "a criterion with no command is refused"    '[ "$rc" != 0 ]'
out="$(IDIR="$IDIR" bash "$ADD" "AC-004" -- 2>&1)"; rc=$?
check "an empty command is refused"               '[ "$rc" != 0 ]'

IDIR="$IDIR" bash "$ADD" "AC-004: кнопка видима після скролу" -- ./ui-check.sh --after-scroll >/dev/null 2>&1
check "the check is recorded"                     '[ -s "$IDIR/checks.jsonl" ]'
check "argv is kept as a list, not a string"      '[ "$(jq -r ".argv|length" "$IDIR/checks.jsonl")" = 2 ]'
check "the criterion is kept verbatim"            '[ "$(jq -r .criterion "$IDIR/checks.jsonl")" = "AC-004: кнопка видима після скролу" ]'
check "no status field is written by the worker"  '[ "$(jq -r "has(\"status\")" "$IDIR/checks.jsonl")" = false ]'

echo
echo "===== the engine runs it and records what IT saw ====="
cat > "$PROJ/ui-check.sh" <<'SH'
#!/bin/bash
[ "${1:-}" = "--pass" ] && exit 0
exit 3
SH
chmod +x "$PROJ/ui-check.sh"
rm -f "$IDIR/checks.jsonl"
IDIR="$IDIR" bash "$ADD" "AC-004: видима після скролу" -- ./ui-check.sh --pass >/dev/null 2>&1
IDIR="$IDIR" bash "$ADD" "AC-006: тап відкриває чат"   -- ./ui-check.sh --fail >/dev/null 2>&1

SID="add-check-test"
bash "$ROOT/bin/verify.sh" "$PROJ" "$SID" "$IDIR" "$(git -C "$PROJ" rev-parse HEAD)" >/dev/null 2>&1
EV="$IDIR/evidence/$SID/evidence.json"
check "evidence.json written"                     '[ -s "$EV" ]'
check "the passing check is a pass"               '[ "$(jq -r ".criteria[]|select(.criterion|startswith(\"AC-004\"))|.status" "$EV")" = pass ]'
check "the failing check is a fail"               '[ "$(jq -r ".criteria[]|select(.criterion|startswith(\"AC-006\"))|.status" "$EV")" = fail ]'
check "its real exit code is recorded"            '[ "$(jq -r ".criteria[]|select(.criterion|startswith(\"AC-006\"))|.exit_code" "$EV")" = 3 ]'
check "the command is written down for review"    'jq -r ".criteria[]|select(.criterion|startswith(\"AC-004\"))|.command" "$EV" | grep -q "ui-check.sh --pass"'
check "one failing check fails the whole run"     '[ "$(jq -r .overall_status "$EV")" = fail ]'
check "the output is kept"                        '[ -n "$(jq -r ".criteria[]|select(.criterion|startswith(\"AC-006\"))|.artifact" "$EV")" ]'

echo
echo "===== bounded ====="
rm -f "$IDIR/checks.jsonl"
for i in $(seq 1 12); do IDIR="$IDIR" bash "$ADD" "check $i" -- /usr/bin/true >/dev/null 2>&1; done
check "no more than ten checks are accepted"      '[ "$(grep -c . "$IDIR/checks.jsonl")" -le 10 ]'

echo
echo "===== every run is told the channel exists, not just the visual ones ====="
# A CLI job has no RunSpec at all — which is exactly the run that spent twelve hours failing review
# because it did not know it could register a check.
prompt="$(compose_task_prompt "/tmp/no-such-idir" "Полагодь експорт")"
check "a run with NO runspec is told about add-check"  'printf %s "$prompt" | grep -q "add-check"'
check "…and told what it is for"                       'printf %s "$prompt" | grep -q "ДОКАЗ"'
check "…and that it is not a way to declare success"   'printf %s "$prompt" | grep -q "не спосіб оголосити"'

echo
echo "===== the project's own verify.sh becomes real evidence ====="
# The wrapper case that cost a day: no stack at the root (the real projects are nested repos), but an
# executable verify.sh sitting right there. The verifier used to report `stacks: []` and the reviewer
# read that as "nothing proven", six rounds running.
WRAP="$(mktemp -d)"
( cd "$WRAP" && git init -q && git config user.email t@t && git config user.name t \
  && printf '#!/bin/bash\nexit 0\n' > verify.sh && chmod +x verify.sh \
  && echo x > note.md && git add -A && git commit -qm init >/dev/null 2>&1 \
  && mkdir inner && ( cd inner && git init -q && echo "plugins { id 'x' }" > build.gradle ) )
bash "$ROOT/bin/verify.sh" "$WRAP" wrap-pass >/dev/null 2>&1
EVW="$SUPERVISOR_STATE_DIR/evidence/wrap-pass/evidence.json"
check "a wrapper with no stack still produces evidence" '[ "$(jq -r .overall_status "$EVW")" = pass ]'
check "and it is the project's own script that ran"     'jq -r ".criteria[].criterion" "$EVW" | grep -q "project verify.sh"'

printf '#!/bin/bash\nexit 3\n' > "$WRAP/verify.sh"; chmod +x "$WRAP/verify.sh"
bash "$ROOT/bin/verify.sh" "$WRAP" wrap-fail >/dev/null 2>&1
EVF="$SUPERVISOR_STATE_DIR/evidence/wrap-fail/evidence.json"
check "a failing project script fails the evidence"     '[ "$(jq -r .overall_status "$EVF")" = fail ]'
check "with the real exit code recorded"                '[ "$(jq -r ".criteria[]|select(.criterion==\"project verify.sh\")|.exit_code" "$EVF")" = 3 ]'

# A path with a SPACE — the case that nearly shipped a silent false pass. run_step runs through
# `perl -e 'exec @ARGV'`, and a single argument holding "…/Night Shift/verify.sh" is split on
# whitespace: nothing execs, perl returns 0, and the step would be filed as PASS with an empty log.
# Two of this machine's three real projects have a space in their path.
SPW="$(mktemp -d)/wrap space"; mkdir -p "$SPW"
( cd "$SPW" && git init -q && git config user.email t@t && git config user.name t \
  && printf '#!/bin/bash\necho RAN-FOR-REAL\nexit 4\n' > verify.sh && chmod +x verify.sh \
  && echo x > note.md && git add -A && git commit -qm init >/dev/null 2>&1 )
bash "$ROOT/bin/verify.sh" "$SPW" wrap-space >/dev/null 2>&1
EVS="$SUPERVISOR_STATE_DIR/evidence/wrap-space/evidence.json"
check "a path with a space still RUNS the script"  '[ "$(jq -r ".criteria[]|select(.criterion==\"project verify.sh\")|.exit_code" "$EVS")" = 4 ]'
check "…and its output was really captured"        'grep -q RAN-FOR-REAL "$SUPERVISOR_STATE_DIR/evidence/wrap-space/project-verify-sh.log"'
check "…so a failure is a failure, not a pass"     '[ "$(jq -r .overall_status "$EVS")" = fail ]'
rm -rf "$SPW"

rm -rf "$WRAP"

echo
[ "$fail" -eq 0 ] && { echo "RESULT: $pass passed, 0 failed"; exit 0; } || { echo "RESULT: $fail failed"; exit 1; }
