#!/bin/bash
# §11.5 — findings channel + quality routing.
#   report-finding.sh: records one JSON line to $IDIR/findings.jsonl inside a supervised
#   run; outside one it prints the "not recorded" notice and exits 0. Invoking it via the
#   dropped $IDIR/report-finding handle records the finding even with ~/.local/bin off PATH
#   (regression #8 — the mechanism is the absolute handle, not a PATH lookup).
#   compose_task_prompt: the humanizer instruction line appears ONLY when
#   surface.user_facing_copy=true; with no runspec it emits exactly TASK_PREFIX_BROAD + task
#   (no runspec refs, no [QUALITY]/[BUDGET] lines) — regression #9.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
RF="$ROOT/bin/report-finding.sh"
RID="report-finding-test-run-id"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

PROJ="$(mktemp -d)"; CPROJ="$(canon_path "$PROJ")"
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$CPROJ" > "$IDIR/project"
printf '%s\n' "$RID" > "$IDIR/run-id"
FIND="$IDIR/findings.jsonl"
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

nlines(){ [ -f "$FIND" ] && grep -c . "$FIND" || echo 0; }

echo "== report-finding.sh records inside a supervised run =="
( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" "$RF" related_improvement "extract shared header" ) >/dev/null 2>&1
check "one finding recorded"            '[ "$(nlines)" = 1 ]'
check "class captured"                  '[ "$(tail -1 "$FIND" | jq -r .class)" = related_improvement ]'
check "text captured"                   'tail -1 "$FIND" | jq -r .text | grep -q "shared header"'

echo "== outside a supervised run: notice, exit 0, nothing recorded =="
before="$(nlines)"
( cd "$PROJ" && "$RF" pre_existing "should not record" ) >/dev/null 2>&1; rc=$?
check "exit 0 (never hard-fails)"       '[ "$rc" = 0 ]'
check "no new finding recorded"         '[ "$(nlines)" = "$before" ]'

echo "== #8: \$IDIR/report-finding handle works with ~/.local/bin off PATH =="
ln -sf "$RF" "$IDIR/report-finding"
NOLOCAL="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/.local/bin' | paste -sd: -)"
( cd "$PROJ" && PATH="$NOLOCAL" ORCHESTRATOR_RUN_ID="$RID" "$IDIR/report-finding" needs_scope "path X — why" ) >/dev/null 2>&1
check "handle recorded a finding"       '[ "$(nlines)" = 2 ]'
check "handle finding class captured"   '[ "$(tail -1 "$FIND" | jq -r .class)" = needs_scope ]'

echo "== compose_task_prompt: humanizer line gated by surface.user_facing_copy =="
CID="$SUPERVISOR_STATE_DIR/compose-idir"; mkdir -p "$CID"

printf '%s' '{"schema":1,"mode":"patch","surface":{"user_facing_copy":false,"visual":false},"verification_profile":"local_visual","write_paths":["x"]}' > "$CID/runspec.json"
P_FALSE="$(compose_task_prompt "$CID" "restyle header")"
# The fenced preamble names write_paths (a real fence) and explains acceptance as the CHECK — it no
# longer tells the worker its task is bounded by the acceptance list.
check "scoped: fences by write_paths"        'printf "%s" "$P_FALSE" | grep -q "write_paths"'
check "scoped: acceptance is the check"      'printf "%s" "$P_FALSE" | grep -q "acceptance"'
check "scoped false: NO humanizer line"      '! printf "%s" "$P_FALSE" | grep -q "через humanizer"'
check "scoped: [BUDGET] line present"        'printf "%s" "$P_FALSE" | grep -q "\[BUDGET\]"'

printf '%s' '{"schema":1,"mode":"patch","surface":{"user_facing_copy":true,"visual":false},"verification_profile":"standard","write_paths":["x"]}' > "$CID/runspec.json"
P_TRUE="$(compose_task_prompt "$CID" "reword the onboarding copy")"
check "scoped true: humanizer line present"  'printf "%s" "$P_TRUE" | grep -q "через humanizer"'

echo "== compose_task_prompt: no runspec ⇒ broad prefix only (regression #9) =="
NORUN="$SUPERVISOR_STATE_DIR/norun-idir"; mkdir -p "$NORUN"          # dir, no runspec.json
P_BROAD="$(compose_task_prompt "$NORUN" "do the thing")"
check "broad: starts with broad prefix"      'printf "%s" "$P_BROAD" | grep -q "Працюй за стандартами якості"'
check "broad: task text preserved"           'printf "%s" "$P_BROAD" | grep -q "do the thing"'
check "broad: NO humanizer instruction line" '! printf "%s" "$P_BROAD" | grep -q "через humanizer"'
check "broad: NO [QUALITY] line"             '! printf "%s" "$P_BROAD" | grep -q "\[QUALITY\]"'
check "broad: NO [BUDGET] line"              '! printf "%s" "$P_BROAD" | grep -q "\[BUDGET\]"'
check "broad: NO scoped RunSpec reference"   '! printf "%s" "$P_BROAD" | grep -q "в межах наданого RunSpec"'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
