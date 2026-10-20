#!/bin/bash
# A report the app asked for ("Create report") gets at most three review rounds, not twelve.
#
# 13 Oct a report on finished work was sent back twice and rewritten for an hour and a half under
# a ceiling of twelve rounds — the owner: "замість роботи всі токени витрачаємо на переписування
# звіту". Code keeps its own ceiling; only the app's report request is capped.
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

FAKE="$(mktemp -d)"
cat > "$FAKE/codex" <<'STUB'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
echo "STATE: COMPLETE"; echo "VERDICT: FAIL"; echo "1. the summary says two runs are resolved; they are not"
STUB
chmod +x "$FAKE/codex"
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
REPOS=()
trap 'rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}' EXIT

mkcase(){  # $1 = run id, $2 = the message the run was given
  RID="$1"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && echo base > app.txt && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  jq -n --arg t "$2" '{id:"DISP-R", task:$t}' > "$IDIR/dispatch.json"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
}
stop(){  # one stop of the worker, with a change in the tree so there is something to review
  echo "edit $RANDOM" >> "$PROJ/app.txt"
  printf '{"session_id":"s-%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$RID" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 SUPERVISOR_STALL_LIMIT=99 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}

echo "===== the app's report request: three rounds, then accepted with notes ====="
mkcase report-run "[BULAVA] The app asks for a report on the work already done in this conversation — only the report"
o1="$(stop)"; o2="$(stop)"
check "the first rounds send it back"            'printf "%s" "$o2" | grep -q "\"block\""'
check "nothing is decided before the ceiling"     '[ ! -e "$IDIR/done" ]'
stop >/dev/null
check "the third round ends it"                   '[ "$(cat "$IDIR/done" 2>/dev/null)" = debt ]'

echo "===== an ordinary task keeps its own ceiling ====="
mkcase code-run "Виправ опечатку в README"
stop >/dev/null; stop >/dev/null; stop >/dev/null
check "three failed rounds do not end it"         '[ ! -e "$IDIR/done" ]'

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
