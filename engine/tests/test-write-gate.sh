#!/bin/bash
# §11.2 — PreToolUse write-gate. Feed synthetic hook stdin JSON and assert a clean
# allow (exit 0, NO output) or a permissionDecision:"deny" object.
# Covers: fail-open with no runspec; in-scope allow; new nested file whose parent dir
# does not yet exist (regression #3); out-of-scope deny; $IDIR/$SUP_STATE deny (even
# broad); AUDIT-*/REVIEW-DEBT deny vs BLOCKED.md/review.json allow (regression #7);
# audit-mode in-repo deny vs $TMPDIR scratch allow (regression #10); kill-switch;
# NotebookEdit notebook_path honored.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/write-gate.sh"
RID="write-gate-test-run-id"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

PROJ="$(mktemp -d)"; CPROJ="$(canon_path "$PROJ")"
SCRATCH="$(mktemp -d)"                                            # an out-of-repo scratch area
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$CPROJ" > "$IDIR/project"
printf '%s\n' "$RID" > "$IDIR/run-id"
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$PROJ" "$SCRATCH"; }
trap cleanup EXIT

setspec(){ printf '%s' "$1" > "$IDIR/runspec.json"; }
clearspec(){ rm -f "$IDIR/runspec.json"; }

# call the gate: $1=file_path key, $2=file_path value ; extra env from the caller line.
# tool defaults to Edit; override with TOOL=NotebookEdit / KEY=notebook_path.
gate(){
  local key="${KEY:-file_path}" val="$1" tool="${TOOL:-Edit}"
  printf '{"tool_name":"%s","cwd":"%s","tool_input":{"%s":"%s"}}' "$tool" "$CPROJ" "$key" "$val" \
    | ORCHESTRATOR_RUN_ID="$RID" "$GATE" 2>/dev/null
}
is_deny(){ printf '%s' "$1" | grep -q '"deny"'; }
is_allow(){ [ -z "$1" ]; }

echo "== fail-open: no runspec ⇒ broad ⇒ allow (proves backward compat) =="
clearspec
check "in-repo write allowed (no runspec)"  'is_allow "$(gate src/a.txt)"'

echo "== patch mode: in-scope allow, out-of-scope deny =="
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
check "in-scope src/a.txt allowed"          'is_allow "$(gate src/a.txt)"'
check "new nested file, parent dir absent (regression #3) allowed" \
                                            'is_allow "$(gate src/newdir/deep/New.kt)"'
check "out-of-scope other/x.txt denied"     'is_deny "$(gate other/x.txt)"'
# regression [CRITICAL #1]: a file_path is normalized (.. collapsed) BEFORE the glob match,
# so a path that TEXTUALLY starts inside a write_path cannot escape it via '..'.
check "'..' out of write_path (still in repo) denied" 'is_deny "$(gate "src/../secret.txt")"'
check "'..' out of the repo entirely denied"          'is_deny "$(gate "src/../../../../../../../../tmp/EVIL.txt")"'

echo "== branch A: writes into control state denied even in BROAD =="
clearspec
check "write into \$IDIR denied (broad)"     'is_deny "$(gate "$IDIR/runspec.json")"'
check "write into \$SUP_STATE denied (broad)" 'is_deny "$(gate "$SUPERVISOR_STATE_DIR/foo.txt")"'
# The one place in control state the worker MUST be able to write: the report drop the app's own
# directive names ("put everything HERE … reports/<task8>"). It was denied, and a run only delivered
# its report by going around the gate through the shell.
check "report drop reports/<task8> ALLOWED" \
                                            'is_allow "$(gate "$SUPERVISOR_STATE_DIR/reports/f82a2d17/report.json")"'
check "report asset in the drop ALLOWED"    'is_allow "$(gate "$SUPERVISOR_STATE_DIR/reports/f82a2d17/after-1.png")"'
# …and the supervisor's OWN artifacts under the instance dir stay denied, carve-out or not.
check "\$IDIR/reports still denied"          'is_deny "$(gate "$IDIR/reports/review.json")"'

echo "== branch B: the session's own paperwork is refused; product docs are not =="
# The policy changed on the director's word: these files accumulate in a repo, go stale in a
# week, and the NEXT session reads them as current documentation and decides by last month's
# plan. Their home is the run's folder, which dies with the run. A README, docs/ or an ADR
# asked for by the task is still ordinary work.
clearspec
check "AUDIT-*.md denied"                    'is_deny "$(gate AUDIT-20260101-1200.md)"'
check "REVIEW-DEBT.md denied"                'is_deny "$(gate REVIEW-DEBT.md)"'
check "BLOCKED.md denied (session journal)"  'is_deny "$(gate BLOCKED.md)"'
check "REVIEW-DEBT-ARCHIVE.md denied"        'is_deny "$(gate REVIEW-DEBT-ARCHIVE.md)"'
check "PLAN.md denied"                       'is_deny "$(gate PLAN.md)"'
check "MANAGER-PLAN.md denied"               'is_deny "$(gate MANAGER-PLAN.md)"'
check "IMPLEMENTATION-BRIEF.md denied"       'is_deny "$(gate IMPLEMENTATION-BRIEF.md)"'
check "FOREMAN-RESEARCH.md denied"           'is_deny "$(gate FOREMAN-RESEARCH.md)"'
check "README.md still allowed"              'is_allow "$(gate README.md)"'
check "docs/api.md still allowed"            'is_allow "$(gate docs/api.md)"'
check "review.json allowed (common filename)"  'is_allow "$(gate review.json)"'
check "DECISIONS.md allowed by default"      'is_allow "$(gate DECISIONS.md)"'
check "DECISIONS.md denied when SUPERVISOR_BLOCK_DECISIONS=1" \
                                            'is_deny "$(SUPERVISOR_BLOCK_DECISIONS=1 gate DECISIONS.md)"'

echo "== audit mode: in-repo code deny, out-of-repo scratch allow (regression #10) =="
setspec '{"schema":1,"mode":"audit","write_paths":[]}'
check "audit in-repo code write denied"      'is_deny "$(gate src/a.txt)"'
check "audit \$TMPDIR scratch allowed"        'is_allow "$(gate "$SCRATCH/analysis.txt")"'

echo "== patch mode with empty write_paths ⇒ deny every code write =="
setspec '{"schema":1,"mode":"patch","write_paths":[]}'
check "empty write_paths denies src/a.txt"   'is_deny "$(gate src/a.txt)"'

echo "== kill switch: SUPERVISOR_SCOPE_GATE=0 ⇒ allow everything =="
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
check "kill-switch allows out-of-scope"      'is_allow "$(SUPERVISOR_SCOPE_GATE=0 gate other/x.txt)"'
check "kill-switch allows \$IDIR write"       'is_allow "$(SUPERVISOR_SCOPE_GATE=0 gate "$IDIR/runspec.json")"'

echo "== NotebookEdit: notebook_path honored like file_path =="
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
check "out-of-scope notebook_path denied"    'is_deny "$(TOOL=NotebookEdit KEY=notebook_path gate nb/x.ipynb)"'
check "in-scope notebook_path allowed"       'is_allow "$(TOOL=NotebookEdit KEY=notebook_path gate src/x.ipynb)"'

echo "== unsupervised (no matching run-id) ⇒ allow (fail-open) =="
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
# no ORCHESTRATOR_RUN_ID exported ⇒ supervision_scope != instance ⇒ exit 0
check "no run-id env ⇒ out-of-scope allowed" \
  'is_allow "$(printf "{\"tool_name\":\"Edit\",\"cwd\":\"$CPROJ\",\"tool_input\":{\"file_path\":\"other/x.txt\"}}" | "$GATE" 2>/dev/null)"'

echo "== T4a: the ENGINE's own dir is denied in EVERY mode; broad keeps in-repo/temp, fences the rest =="
ENGINE_DIR="$ROOT"
clearspec  # broad / no-runspec
check "broad: write into the engine dir DENIED"        'is_deny "$(gate "$ENGINE_DIR/hooks/review-gate.sh")"'
check "broad: in-repo write still ALLOWED (autonomy)"  'is_allow "$(gate src/keep.txt)"'
check "broad: out-of-repo temp scratch ALLOWED"        'is_allow "$(gate "$SCRATCH/note.txt")"'
check "broad: arbitrary out-of-repo path DENIED"       'is_deny "$(gate "$HOME/ns-writegate-evil.txt")"'
setspec '{"schema":1,"mode":"audit"}'
check "audit: engine dir DENIED"                       'is_deny "$(gate "$ENGINE_DIR/bin/verify.sh")"'
check "audit: arbitrary out-of-repo DENIED"            'is_deny "$(gate "$HOME/ns-writegate-evil2.txt")"'
check "audit: temp scratch still ALLOWED"              'is_allow "$(gate "$SCRATCH/audit-note.txt")"'

echo "== T4b: when the engine IS part of the task repo, it is editable (Bulava's own repository) =="
# Bulava ships the engine as <repo>/engine, so ENGINE_ROOT never equalled PROJ and the fence was
# on for every path under it — no supervised session could maintain the engine inside its own
# product. The fence asks the right question now: does the engine live in the repo this run may
# change?
OWN="$(mktemp -d)"; COWN="$(canon_path "$OWN")"
mkdir -p "$OWN/engine/hooks" "$OWN/engine/bin" "$OWN/src"
cp "$ROOT/hooks/write-gate.sh" "$OWN/engine/hooks/write-gate.sh"
cp "$ROOT/bin/supervisor-lib.sh" "$OWN/engine/bin/supervisor-lib.sh"
OWN_IDIR="$(instance_dir "$(slug_for "$OWN")")"; mkdir -p "$OWN_IDIR"
printf '%s\n' "$COWN" > "$OWN_IDIR/project"
printf '%s\n' "$RID" > "$OWN_IDIR/run-id"
own_gate(){
  printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s"}}' "$COWN" "$1" \
    | ORCHESTRATOR_RUN_ID="$RID" "$OWN/engine/hooks/write-gate.sh" 2>/dev/null
}
check "engine inside the task repo is EDITABLE"  'is_allow "$(own_gate "$COWN/engine/hooks/review-gate.sh")"'
check "engine inside the task repo, bin/ too"    'is_allow "$(own_gate "$COWN/engine/bin/verify.sh")"'
check "ordinary code in that repo still allowed" 'is_allow "$(own_gate "$COWN/src/a.swift")"'
check "out-of-repo path still DENIED there"      'is_deny  "$(own_gate "$HOME/ns-writegate-evil3.txt")"'
check "control state still DENIED there"         'is_deny  "$(own_gate "$OWN_IDIR/runspec.json")"'
# A repository whose path merely STARTS like the task's must not be read as containing it.
# Tested where it is observable: the gate is run FROM the look-alike's engine, so ENGINE_ROOT is
# "$NEAR/engine" while the task repo is still "$COWN". That engine does not belong to this run, so
# writing into it has to be denied — and since $NEAR sits in the temp tree, which broad mode
# otherwise allows as scratch, a deny can only have come from the engine fence.
NEAR="$COWN-neighbour"
mkdir -p "$NEAR/engine/hooks" "$NEAR/engine/bin"
cp "$ROOT/hooks/write-gate.sh" "$NEAR/engine/hooks/write-gate.sh"
cp "$ROOT/bin/supervisor-lib.sh" "$NEAR/engine/bin/supervisor-lib.sh"
near_gate(){
  printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s"}}' "$COWN" "$1" \
    | ORCHESTRATOR_RUN_ID="$RID" "$NEAR/engine/hooks/write-gate.sh" 2>/dev/null
}
check "a look-alike sibling engine is NOT ours ⇒ DENIED" \
                                                 'is_deny  "$(near_gate "$NEAR/engine/hooks/x.sh")"'
check "…and that same path IS allowed by broad when it is not an engine" \
                                                 'is_allow "$(own_gate "$NEAR/notes.txt")"'
rm -rf "$OWN" "$NEAR"

echo "== the product's other folders: writable when the app says so, and only those =="
# 13 Oct: the product's second folder was set to "can change" in the app, and the gate refused an
# edit to the dashboard inside it.
clearspec
# Outside every temp folder: the gate lets scratch writes there through on their own.
# macOS keeps per-user caches in ~/Library/Caches, Linux in ~/.cache.
_CACHES="$HOME/Library/Caches"; [ -d "$_CACHES" ] || { _CACHES="${XDG_CACHE_HOME:-$HOME/.cache}"; mkdir -p "$_CACHES"; }
OUTSIDE="$(mktemp -d "$_CACHES/bulava-write-gate.XXXXXX")"
EXTRA="$(canon_path "$OUTSIDE")/extra"; OTHER="$(canon_path "$OUTSIDE")/other"; mkdir -p "$EXTRA" "$OTHER"; CHATDIR="$(mktemp -d)"
printf '%s\n%s\n' "$EXTRA" "$OTHER" > "$CHATDIR/additional-directories.txt"
check "no list from the app: the extra folder is refused" 'is_deny "$(gate "$EXTRA/dashboard/index.html")"'
printf '%s\n/\n%s\n' "$EXTRA" "$HOME" > "$CHATDIR/writable-directories.txt"
SUPERVISOR_EXTRA_DIRS_FILE="$CHATDIR/additional-directories.txt" record_writable_dirs "$IDIR"
check "a folder the app marked writable is allowed"       'is_allow "$(gate "$EXTRA/dashboard/index.html")"'
check "a folder handed only for reading is still refused" 'is_deny "$(gate "$OTHER/notes.md")"'
check "'/' and the home folder never make it onto the list" '! grep -qx "/" "$IDIR/writable-dirs" && ! grep -qx "$(canon_path "$HOME")" "$IDIR/writable-dirs"'
check "a lookalike sibling name is not inside it"         'is_deny "$(gate "${EXTRA}-evil/x.txt")"'
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
check "a scoped run's write_paths fence still wins"       'is_deny "$(gate "$EXTRA/dashboard/index.html")"'
clearspec
bashgate(){ printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":%s}}' "$CPROJ" "$(jq -Rn --arg c "$1" '$c')" \
  | ORCHESTRATOR_RUN_ID="$RID" "$GATE" 2>/dev/null; }
check "the worker cannot add a folder to the list itself" 'is_deny "$(bashgate "echo /etc >> $IDIR/writable-dirs")"'
SUPERVISOR_EXTRA_DIRS_FILE="" record_writable_dirs "$IDIR"
check "a launch without the app's list clears it"         '[ ! -e "$IDIR/writable-dirs" ]'
# The engine is worked on from its own repository, and its code and tests name the run's control
# files all the time. Naming one is not reaching for it: the gate refused a script that edited a
# TEST, and a grep whose flags spelled `ln`.
denied(){ is_deny "$1"; }
check "a script editing the engine's own test is not a forgery" '! denied "$(bashgate "python3 patch.py tests/test-x.sh  # adds a check on codex-owed.json")"'
check "a read whose flags spell a verb is a read"         '! denied "$(bashgate "grep -rln codex-fallback.json tests | head")"'
check "a word that merely contains a verb is not one"     '! denied "$(bashgate "grep -q add $IDIR/review-pending")"'
check "…but the same name inside the run's folder is"     'denied "$(bashgate "python3 -c x > $IDIR/codex-owed.json")"'
check "and through the variable the worker is given"      'denied "$(bashgate "printf x > \"\$IDIR/codex-fallback.json\"")"'
check "and through the state directory"                   'denied "$(bashgate "cd ~/.claude/supervisor/instances/x && rm review-pending")"'
# A verb is still a verb when it is spelled as a path or escaped past an alias.
check "/bin/rm on the run's state is a write"              'denied "$(bashgate "/bin/rm \\"$IDIR/review-pending\\"")"'
check "/bin/cp over the fallback is a write"               'denied "$(bashgate "/bin/cp /tmp/answer \\"$IDIR/codex-fallback.json\\"")"'
check "\\rm past an alias is a write"                      'denied "$(bashgate "\\rm $IDIR/paused-for-limit.json")"'
check "/usr/bin/tee into the state is a write"             'denied "$(bashgate "echo x | /usr/bin/tee $IDIR/codex-owed.json")"'
check "and grep -rln over the same names is still a read"  '! denied "$(bashgate "grep -rln review-pending $IDIR")"'
# Every spelling of a write the gate has ever refused, against every control file: narrowing the
# verbs to words must not have let one of them through. Measured against the gate before the
# narrowing, 324 of 324 were refused by both.
_leaks=""
for _f in codex-fallback.json codex-decision-answer.json codex-owed.json review-pending paused-for-limit.json \
          ask-user.json resume-refused writable-dirs outcome.json answer.json run-env plain-folder; do
  for _c in "echo x > $IDIR/$_f" "rm -f $IDIR/$_f" "/bin/rm $IDIR/$_f" "\\rm $IDIR/$_f" "cp /tmp/a $IDIR/$_f" \
            "/bin/cp /tmp/a \"$IDIR/$_f\"" "/bin/mv /tmp/a $IDIR/$_f" "/usr/bin/touch $IDIR/$_f" \
            "ln -sf /tmp/a $IDIR/$_f" "echo x | /usr/bin/tee -a $IDIR/$_f" "dd if=/dev/zero of=$IDIR/$_f" \
            "chmod 000 $IDIR/$_f" "install -m 644 /tmp/a $IDIR/$_f" "sed -i '' s/a/b/ $IDIR/$_f" \
            "python3 -c \"open('$IDIR/$_f','w')\"" "truncate -s 0 $IDIR/$_f" "printf x &>$IDIR/$_f" \
            "cd $IDIR && rm $_f" "(rm $IDIR/$_f)" "\`rm $IDIR/$_f\`" "true&&rm $IDIR/$_f" "true;cp /tmp/a $IDIR/$_f"; do
    denied "$(bashgate "$_c")" || _leaks="$_leaks
      $_c"
  done
done
check "no spelling of a write reaches a control file${_leaks:+:$_leaks}" '[ -z "$_leaks" ]'
MEM="$HOME/.claude/projects/$(printf '%s' "$CPROJ" | sed 's/[^A-Za-z0-9]/-/g')/memory"
check "Claude's own memory for this project is writable"  'is_allow "$(gate "$MEM/note.md")"'
check "another project's memory is not"                   'is_deny "$(gate "$HOME/.claude/projects/-elsewhere/memory/note.md")"'
check "nor is anything else under ~/.claude"              'is_deny "$(gate "$HOME/.claude/settings.json")"'
rm -rf "$OUTSIDE" "$CHATDIR"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
