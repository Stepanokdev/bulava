#!/bin/bash
# The factory's layout: no main repository at all.
#
# The bridge starts the engine in `workspace/`, a small git repository of its own (a .gitignore that
# ignores every clone, an AGENTS.md describing the folder), with every repository of the group cloned
# inside it and handed over as a writable extra. The worker decides which of them a task needs.
#
# What is pinned here, through the real start, gate and verifier:
#   • the start is accepted — a home repository whose clones are ignored is not "a folder of projects"
#   • the clones are not seen twice: not as noise in the home repository, not in its stack
#   • a change in one clone is reviewed, verified inside that clone, and named in receipt.repos with
#     its reviewed commit; the untouched home repository and clone keep base == reviewed
#   • an uncommitted clone is noticed although the home repository ignores it
#   • writing into the home repository is fenced off when a runspec names only the clones
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_PROFILE
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
TMP="$(mktemp -d)"
gitq() { git -c user.email=t@t -c user.name=t "$@"; }

W="$TMP/workspace"; mkdir -p "$W"
( cd "$W" && git init -q -b main && printf '/*/\n' > .gitignore && printf '# Workspace\nrepos: api, web\n' > AGENTS.md \
    && git add -A && gitq commit -qm home )
for r in api web; do
  mkdir -p "$W/$r"
  ( cd "$W/$r" && git init -q -b agent/PRJ-1 && echo "$r" > README.md && git add -A && gitq commit -qm base )
done
printf 'test:\n\t@echo api-tests-ran\n' > "$W/api/Makefile"; ( cd "$W/api" && git add -A && gitq commit -qm tests )
W="$(canon_path "$W")"; API="$W/api"; WEB="$W/web"
EXTRA="$TMP/extra-dirs.txt"; printf '%s\n%s\n' "$API" "$WEB" > "$EXTRA"; printf '%s\n%s\n' "$API" "$WEB" > "$TMP/writable-directories.txt"
SES="$(session_name "$(slug_for "$W")")"
cleanup() { tmux kill-session -t "$SES" 2>/dev/null; pkill -f "$TMP/wd-stub" 2>/dev/null; tmux_cleanup 2>/dev/null; rm -rf "$SUPERVISOR_STATE_DIR" "$TMP"; }
trap cleanup EXIT

echo "===== the home repository is a project, not a folder of projects ====="
check "the folder test accepts it"                      '! workspace_container_reason "$W" >/dev/null'
check "its own status does not show the clones"         '[ -z "$(git -C "$W" status --porcelain)" ]'

echo "===== the real start, with every clone as a writable extra ====="
tmux_isolate "$TMP/tmux"
printf '#!/bin/bash\nexec sleep 300\n' > "$TMP/wd-stub"; chmod +x "$TMP/wd-stub"
export SUPERVISOR_PROFILE=server SUPERVISOR_TMUX_SOCKET=ws-test SUPERVISOR_CLAUDE_CMD=cat SUPERVISOR_REQUIRE_HANDSHAKE=0 \
       SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_PROMPT_WAIT=1 SUPERVISOR_WATCHDOG_CMD="$TMP/wd-stub" \
       SUPERVISOR_NO_SKILL_PICK=1 SUPERVISOR_PREFLIGHT_ENABLE=0 SUPERVISOR_EXTRA_DIRS_FILE="$EXTRA"
tmux() { command tmux -L ws-test "$@"; }
out="$(bash "$ROOT/bin/dispatch.sh" --task-id PRJ-1 --source youtrack --author bob "$W" "Додай ендпоінт" 2>&1)"; rc=$?
check "dispatch starts in the workspace"                '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "^TIER=dispatched"'
I="$(instance_dir "$(slug_for "$W")")"
check "every clone is recorded with its base"           '[ "$(cut -d$'"'"'\037'"'"' -f1 "$I/extra-repos" | tr "\n" " ")" = "$API $WEB " ]'
check "every clone is writable"                         'grep -qx "$API" "$I/writable-dirs" && grep -qx "$WEB" "$I/writable-dirs"'

echo "===== a change in one clone is reviewed, verified there, and named ====="
FAKE="$TMP/fake"; mkdir -p "$FAKE"; export CODEX_CALLED="$FAKE/called"
printf '%s\n' 'if [ "${1:-}" = login ]; then echo "Logged in"; exit 0; fi' 'echo called >> "$CODEX_CALLED"' \
  'printf "%s\\n" "$@" > "$CODEX_CALLED.prompt"; cat >> "$CODEX_CALLED.prompt"' 'echo "STATE: COMPLETE"; echo "VERDICT: PASS"' > "$FAKE/codex"; chmod +x "$FAKE/codex"
TR="$TMP/tr.jsonl"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
RID="$(cat "$I/run-id")"
( cd "$API" && echo "def health(): return 200" > health.py && git add health.py && gitq commit -qm health )
jq -nc --arg ts "$(date '+%F %T')" --arg rid "$RID" '{schema:1, result:"succeeded_changes", summary:"x", ts:$ts, run_id:$rid}' > "$I/outcome.json"
mkdir -p "$I/report"; jq -nc '{result:"succeeded_changes", review:"pending"}' > "$I/report/receipt.json"
gate() {   # $1 = where the worker stands
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$1" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true SUPERVISOR_RELEASE_DELAY=600 \
      PATH="$FAKE:$PATH" bash "$ROOT/hooks/review-gate.sh" 2>/dev/null
}
# An uncommitted clone the home repository ignores is still uncommitted work.
echo wip > "$WEB/wip.txt"
out="$(gate "$API")"
check "an uncommitted clone is noticed though the home repository ignores it" 'printf "%s" "$out" | grep -q "закоміть" && printf "%s" "$out" | grep -q "$WEB"'
rm -f "$WEB/wip.txt"
out="$(gate "$API")"
check "the change is reviewed"                          '[ -s "$CODEX_CALLED" ] && [ "$(cat "$I/done" 2>/dev/null)" = passed ]'
check "…and the reviewer is shown the change in the clone" 'grep -q "health.py" "$CODEX_CALLED.prompt"'
check "…once, not again as noise of the home repository"   '[ "$(grep -c "health.py" "$CODEX_CALLED.prompt")" -le 2 ] && ! grep -qE "^ ?api/health.py" "$CODEX_CALLED.prompt"'
ev="$(ls -t "$I"/evidence/*/evidence.json 2>/dev/null | head -1)"
check "it is verified inside the clone that changed"    'jq -r ".criteria[].criterion" "$ev" | grep -q "^api: make test"'
check "…and not inside the untouched one"               '! jq -r ".criteria[].criterion" "$ev" | grep -q "^web:"'
check "nothing claims there was nothing to verify"      '! jq -r ".criteria[].command" "$ev" | grep -q "(none available)"'
R="$I/report/receipt.json"
check "receipt: the clone that changed, with its reviewed commit" '[ "$(jq -r --arg p "$API" ".repos[] | select(.path==\$p) | .reviewed_sha" "$R")" = "$(git -C "$API" rev-parse HEAD)" ] && [ "$(jq -r --arg p "$API" ".repos[] | select(.path==\$p) | (.base_sha != .reviewed_sha)" "$R")" = true ]'
check "receipt: the home repository and the other clone are unchanged" '[ "$(jq -r --arg w "$W" --arg b "$WEB" "[.repos[] | select(.path==\$w or .path==\$b) | (.base_sha == .reviewed_sha)] | all" "$R")" = true ]'
check "the task waits for its merge request"            '[ "$(task_get PRJ-1 .state)" = waiting_review ]'

echo "===== the home repository can be fenced off ====="
wg() { jq -n --arg cwd "$API" --arg f "$1" '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$f}}' \
         | ORCHESTRATOR_RUN_ID="$RID" bash "$ROOT/hooks/write-gate.sh" 2>/dev/null; }
check "without a runspec the whole workspace is the task's" '! wg "$W/AGENTS.md" | grep -q "\"deny\"" && ! wg "$API/x.py" | grep -q "\"deny\""'
jq -n '{mode:"patch", objective:"x", acceptance:["y"], write_paths:["api/**","web/**"]}' > "$I/runspec.json"
check "a runspec naming the clones keeps the home repository out" 'wg "$W/AGENTS.md" | grep -q "\"deny\""'
check "…and the clones in"                              '! wg "$API/x.py" | grep -q "\"deny\""'

printf '\n'
[ "$fails" -eq 0 ] && { echo "✅ server workspace: all checks pass"; exit 0; }
echo "❌ server workspace: $fails failed"; exit 1
