#!/bin/bash
# A task's work in its connected repositories is reviewed as the TASK's work, across attempts.
#
# The factory's first live run (EDCMP-7170, 25.10): an attempt committed in four connected
# repositories and asked a person a question; the answer started a fresh attempt that measured each
# repository from where IT found it, so those commits were part of its starting point. The worker
# then said "done", the gate saw no diff and no usable outcome, and the task ended as debt with four
# commits in its branches that Codex never saw whole.
#
# What is pinned here, through the real dispatch, worker-send, gate and verifier:
#   • a connected repository keeps the base it had when it first appeared in the task
#   • the attempt after an answer reviews what the attempt before the question committed
#   • the receipt names the task's base, not the attempt's
#   • once a review has passed, an attempt that commits nothing there is not reviewed again
#   • an attempt that commits in one repository again is reviewed for that one alone
#   • "nothing to change" over commits no review has seen goes to review, not to debt
#   • a repository with no commits at first keeps the empty tree as its base across attempts
#   • a runspec whose work is all in a connected repository is reviewed, not "all quarantined"
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
( cd "$W" && git init -q -b main && printf '/*/\n' > .gitignore && printf '# Workspace\n' > AGENTS.md \
    && git add -A && gitq commit -qm home )
for r in api web; do
  mkdir -p "$W/$r"
  ( cd "$W/$r" && git init -q -b agent/PRJ-1 && echo "$r" > README.md \
      && printf 'test:\n\t@echo %s-tests-ran\n' "$r" > Makefile && git add -A && gitq commit -qm base )
done
W="$(canon_path "$W")"; API="$W/api"; WEB="$W/web"
API0="$(git -C "$API" rev-parse HEAD)"; WEB0="$(git -C "$WEB" rev-parse HEAD)"
EXTRA="$TMP/extra-dirs.txt"; printf '%s\n%s\n' "$API" "$WEB" > "$EXTRA"; printf '%s\n%s\n' "$API" "$WEB" > "$TMP/writable-directories.txt"
SES="$(session_name "$(slug_for "$W")")"
cleanup() { tmux kill-session -t "$SES" 2>/dev/null; pkill -f "$TMP/wd-stub" 2>/dev/null; tmux_cleanup 2>/dev/null; rm -rf "$SUPERVISOR_STATE_DIR" "$TMP"; }
trap cleanup EXIT

tmux_isolate "$TMP/tmux"
printf '#!/bin/bash\nexec sleep 300\n' > "$TMP/wd-stub"; chmod +x "$TMP/wd-stub"
export SUPERVISOR_PROFILE=server SUPERVISOR_TMUX_SOCKET=tr-test SUPERVISOR_CLAUDE_CMD=cat SUPERVISOR_REQUIRE_HANDSHAKE=0 \
       SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_PROMPT_WAIT=1 SUPERVISOR_WATCHDOG_CMD="$TMP/wd-stub" \
       SUPERVISOR_NO_SKILL_PICK=1 SUPERVISOR_PREFLIGHT_ENABLE=0 SUPERVISOR_EXTRA_DIRS_FILE="$EXTRA"
CLAUDE_CONFIG_DIR="$TMP/cc"; export CLAUDE_CONFIG_DIR; mkdir -p "$CLAUDE_CONFIG_DIR"
tmux() { command tmux -L tr-test "$@"; }
I="$(instance_dir "$(slug_for "$W")")"

FAKE="$TMP/fake"; mkdir -p "$FAKE"; export CODEX_CALLED="$FAKE/called"
printf '%s\n' 'if [ "${1:-}" = login ]; then echo "Logged in"; exit 0; fi' 'echo called >> "$CODEX_CALLED"' \
  'printf "%s\\n" "$@" > "$CODEX_CALLED.prompt"; cat >> "$CODEX_CALLED.prompt"' 'echo "STATE: COMPLETE"; echo "VERDICT: PASS"' > "$FAKE/codex"; chmod +x "$FAKE/codex"
TR="$TMP/tr.jsonl"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"

# The worker of the current attempt declares $1 (with question $2 for needs_input) and stops.
finish() {
  local rid; rid="$(cat "$I/run-id")"
  rm -f "$CODEX_CALLED" "$CODEX_CALLED.prompt"
  jq -nc --arg ts "$(date '+%F %T')" --arg rid "$rid" --arg r "$1" --arg q "${2:-}" \
    '{schema:1, result:$r, summary:"x", ts:$ts, run_id:$rid}
     + (if $q != "" then {question:{id:$q, text:"Який формат?", options:[]}} else {} end)' > "$I/outcome.json"
  mkdir -p "$I/report"; jq -nc --arg r "$1" '{result:$r, review:"pending"}' > "$I/report/receipt.json"
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$W" \
    | ORCHESTRATOR_RUN_ID="$rid" SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true SUPERVISOR_RELEASE_DELAY=0 \
      PATH="$FAKE:$PATH" bash "$ROOT/hooks/review-gate.sh" > "$TMP/gate.out" 2>/dev/null
  for _ in $(seq 1 50); do tmux has-session -t "$SES" 2>/dev/null || break; sleep 0.2; done
}
next() {   # $1=task $2=message id [$3=answers]
  bash "$ROOT/bin/worker-send.sh" --task-id "$1" --relation continue --message-id "$2" --source youtrack --author bob \
    ${3:+--answers "$3"} "$W" - - - "продовжуй" 2>&1 | grep -q '^TIER=dispatched'
}
# A settled attempt's folder is let go at once; what it reported is kept on the task.
receipt_base() { task_get "$2" ".last_receipt.repos[] | select(.path==\"$1\") | .base_sha"; }

echo "===== attempt 1 commits in both repositories, then asks ====="
out="$(bash "$ROOT/bin/dispatch.sh" --task-id PRJ-1 --source youtrack --author bob "$W" "Додай ендпоінт" 2>&1)"
check "the task starts"                                 'printf "%s" "$out" | grep -q "^TIER=dispatched"'
check "each connected repository keeps its first base"  '[ "$(task_get PRJ-1 ".repo_bases[\"$API\"]")" = "$API0" ] && [ "$(task_get PRJ-1 ".repo_bases[\"$WEB\"]")" = "$WEB0" ]'
( cd "$API" && echo "def a(): pass" > a_endpoint.py && git add -A && gitq commit -qm a )
( cd "$WEB" && echo "b" > b_page.js && git add -A && gitq commit -qm b )
finish needs_input q-1
check "the question parks the task without a review"    '[ "$(task_get PRJ-1 .state)" = needs_input ] && [ ! -s "$CODEX_CALLED" ]'

echo "===== attempt 2, after the answer, changes nothing and says it is done ====="
check "the answer starts the next attempt"              'next PRJ-1 m-2 q-1'
check "…measured from the task's base, not from where it found them" '[ "$(cut -d$'"'"'\037'"'"' -f2 "$I/extra-repos" | tr "\n" " ")" = "$API0 $WEB0 " ]'
finish succeeded_changes
check "what attempt 1 committed is reviewed"            '[ -s "$CODEX_CALLED" ] && grep -q a_endpoint.py "$CODEX_CALLED.prompt" && grep -q b_page.js "$CODEX_CALLED.prompt"'
check "…verified in both repositories"                  'grep -q "api: make test" "$CODEX_CALLED.prompt" && grep -q "web: make test" "$CODEX_CALLED.prompt"'
check "the task waits for its merge request"            '[ "$(task_get PRJ-1 .state)" = waiting_review ]'
check "the receipt names the task's base"               '[ "$(receipt_base "$API" PRJ-1)" = "$API0" ] && [ "$(receipt_base "$WEB" PRJ-1)" = "$WEB0" ]'
check "…and the commits the review saw"                 '[ "$(task_get PRJ-1 ".repo_reviewed[\"$API\"]")" = "$(git -C "$API" rev-parse HEAD)" ]'

echo "===== attempt 3, a merge-request comment that needs no code ====="
check "the comment starts an attempt"                   'next PRJ-1 m-3'
finish succeeded_no_change
check "what a passing review saw is not reviewed again" '[ ! -s "$CODEX_CALLED" ]'

echo "===== attempt 4 commits in one repository again ====="
check "another comment starts an attempt"               'next PRJ-1 m-4'
( cd "$WEB" && echo "c" > c_fix.js && git add -A && gitq commit -qm c )
finish succeeded_changes
check "the new commit is reviewed"                      '[ -s "$CODEX_CALLED" ] && grep -q c_fix.js "$CODEX_CALLED.prompt"'
check "…and the repository it did not touch is not shown again" '! grep -q "$API (підключений" "$CODEX_CALLED.prompt"'
check "the base in the receipt has not moved"           '[ "$(receipt_base "$WEB" PRJ-1)" = "$WEB0" ] && [ "$(task_get PRJ-1 .state)" = waiting_review ]'

echo "===== 'nothing to change' over commits no review has seen ====="
API1="$(git -C "$API" rev-parse HEAD)"
out="$(bash "$ROOT/bin/dispatch.sh" --task-id PRJ-2 --source youtrack --author bob "$W" "Інша задача" 2>&1)"
check "a second task starts from where the first left them" 'printf "%s" "$out" | grep -q "^TIER=dispatched" && [ "$(task_get PRJ-2 ".repo_bases[\"$API\"]")" = "$API1" ]'
( cd "$API" && echo "d" > d_job.py && git add -A && gitq commit -qm d )
finish blocked
check "a blocked attempt parks without a review"        '[ "$(task_get PRJ-2 .state)" = blocked ] && [ ! -s "$CODEX_CALLED" ]'
check "the unblock starts an attempt"                   'next PRJ-2 m-5'
finish succeeded_no_change
check "the commit is reviewed, not filed as debt"       '[ -s "$CODEX_CALLED" ] && grep -q d_job.py "$CODEX_CALLED.prompt" && [ "$(task_get PRJ-2 ".attempts[-1].disposition")" = passed ]'

echo "===== a repository with no commits when the task first saw it ====="
NEW="$W/fresh"; mkdir -p "$NEW"; ( cd "$NEW" && git init -q -b agent/PRJ-3 ); NEW="$(canon_path "$NEW")"
EMPTY="$(git hash-object -t tree /dev/null)"
printf '%s\n' "$NEW" >> "$EXTRA"; printf '%s\n' "$NEW" >> "$TMP/writable-directories.txt"
out="$(bash "$ROOT/bin/dispatch.sh" --task-id PRJ-3 --source youtrack --author bob "$W" "Новий сервіс" 2>&1)"
check "it starts from the empty tree"                   'printf "%s" "$out" | grep -q "^TIER=dispatched" && [ "$(task_get PRJ-3 ".repo_bases[\"$NEW\"]")" = "$EMPTY" ]'
( cd "$NEW" && echo "e" > e_first.py && git add -A && gitq commit -qm e )
finish needs_input q-3
check "the next attempt still measures it from there"   'next PRJ-3 m-6 q-3 && [ "$(grep "^$NEW" "$I/extra-repos" | cut -d$'"'"'\037'"'"' -f2)" = "$EMPTY" ]'
finish succeeded_changes
check "…so its first commit is reviewed"                '[ -s "$CODEX_CALLED" ] && grep -q e_first.py "$CODEX_CALLED.prompt" && [ "$(task_get PRJ-3 .state)" = waiting_review ]'
check "after the pass it has nothing new"               'next PRJ-3 m-7 && ! extra_repos_changed "$I" | grep -q "^$NEW"'
finish succeeded_no_change

echo "===== a runspec whose work is all in a connected repository ====="
out="$(bash "$ROOT/bin/dispatch.sh" --task-id PRJ-4 --source youtrack --author bob "$W" "Поправ api" 2>&1)"
jq -n '{mode:"patch", objective:"x", acceptance:["y"], write_paths:["api/**"]}' > "$I/runspec.json"
( cd "$API" && echo "f" > f_scoped.py && git add -A && gitq commit -qm f )
finish succeeded_changes
check "it is reviewed, not reported as all quarantined" '[ -s "$CODEX_CALLED" ] && grep -q f_scoped.py "$CODEX_CALLED.prompt" && [ "$(task_get PRJ-4 ".attempts[-1].disposition")" = passed ]'

printf '\n'
[ "$fails" -eq 0 ] && { echo "✅ server task repos: all checks pass"; exit 0; }
echo "❌ server task repos: $fails failed"; exit 1
