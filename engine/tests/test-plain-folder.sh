#!/bin/bash
# A job, not a change to code: an automation that reads files and uses a service works in a plain
# folder of its own (SUPERVISOR_PLAIN_FOLDER=1).
#
# Before this, every automation ran in a git copy, and a folder with no git was a wall: the start
# asked whether to create a repository (exit 76), and nobody was there to answer. A run that only
# turns meeting notes into tasks has no code to roll back and no diff to review.
#
# Pinned:
#   1. The start in a plain folder skips everything git-shaped: no question, no `.git`, no branch,
#      no checkpoint. Without the flag the same folder still gets the question.
#   2. The choice is part of the run's environment, so a resume keeps it.
#   3. What the gate believes is Bulava's signed record for the folder, never a file the run could
#      write: a record signed for this folder counts; none, one signed by another key, or one made
#      for another folder does not — and a shell write to the run's state is refused besides.
#   4. With the record, the gate takes a declared success at its word (passed, no Codex) — unless a
#      fresh blocker says otherwise — honours a declared failure as before (needs-user), asks a run
#      that declared nothing twice and then parks it, never waits on a Codex window, and gives a new
#      verdict after he answered a parked run (a plain folder's tree never looks changed).
#   5. The MCP servers an automation names are allowed for its run, nothing else is, and a deny
#      (his own Chrome) still wins over a name.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"; mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_COMMIT_MESSAGE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP SUPERVISOR_PLAIN_FOLDER SUPERVISOR_ALLOW_TOOLS SUPERVISOR_UNATTENDED
export SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
NS="$BIN_DIR/night-shift.sh"
APP=(env SUPERVISOR_RUN_ENV_FROM_APP=1 "SUPERVISOR_APP_ANSWERS=dirty mcp git heavy")

. "$BIN_DIR/supervisor-lib.sh"

# The app's signing key, for real: the gate verifies with openssl against the public half.
KEYDIR="$TMP/keys"; mkdir -p "$KEYDIR"
openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/priv.pem" 2>/dev/null
openssl ec -in "$KEYDIR/priv.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/other.pem" 2>/dev/null
sign_with() {   # $1 = private key  $2 = payload → base64 signature
  printf '%s' "$2" > "$KEYDIR/payload"
  openssl dgst -sha256 -sign "$1" -out "$KEYDIR/sig" "$KEYDIR/payload" 2>/dev/null
  base64 < "$KEYDIR/sig" | tr -d '\n'
}
record_plain() {   # $1 = the folder  [$2 = private key]  [$3 = the slug the payload names]
  local slug; slug="$(slug_for "$(canon_path "$1")")"
  mkdir -p "$SUPERVISOR_STATE_DIR/plain-folders"
  jq -nc --arg s "$(sign_with "${2:-$KEYDIR/priv.pem}" "plain-folder|${3:-$slug}")" '{signature:$s}' \
    > "$(plain_folder_file "$slug")"
}

echo "===== 1. a plain folder starts without anything git-shaped ====="
P="$TMP/meetings-to-tasks"; mkdir -p "$P"; echo "notes" > "$P/scratch.txt"
out="$("${APP[@]}" SUPERVISOR_PLAIN_FOLDER=1 SUPERVISOR_UNATTENDED=1 bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "started (exit 0)" || bad "exit $rc: $out"
[ -e "$P/.git" ] && bad "a .git was made in the plain folder" || ok "no .git made"
IDIR="$(instance_dir "$(slug_for "$(canon_path "$P")")")"
[ -e "$IDIR/branch" ] && bad "a branch was recorded: $(cat "$IDIR/branch")" || ok "no branch"
[ -s "$IDIR/base-sha" ] && bad "a base commit was recorded" || ok "no base commit"
grep -qx "export SUPERVISOR_PLAIN_FOLDER='1'" "$(run_env_file "$IDIR")" 2>/dev/null \
  && ok "the choice is in the run's environment (a resume keeps it)" || bad "SUPERVISOR_PLAIN_FOLDER is not in the run env"
case " $_RUN_ENV_VARS " in *" SUPERVISOR_PLAIN_FOLDER "*) ok "and in the list every later process reads" ;; *) bad "not in _RUN_ENV_VARS" ;; esac
case "$out" in *"git"*"Створити"*) bad "it still asked about git: $out" ;; *) ok "nothing asked about git" ;; esac
plain_folder_run "$IDIR" && bad "the start alone made the gate believe it" || ok "the start alone does not make it a plain run for the gate"
bash "$NS" stop "$P" >/dev/null 2>&1

echo "===== a commit-less .git folder starts plain too (the first message gets through, no exit 77) ====="
# The folder a chat lands in with a leftover, abandoned `git init` — Bulava runs it plain, so the
# first message reaches the worker instead of stopping at "the first commit is yours" (exit 77).
CL="$TMP/commitless"; mkdir -p "$CL"; ( cd "$CL" && git init -q ); echo notes > "$CL/n.txt"
out="$("${APP[@]}" SUPERVISOR_PLAIN_FOLDER=1 SUPERVISOR_UNATTENDED=1 bash "$NS" start "$CL" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "a commit-less repo starts plain (exit 0, not 77)" || bad "exit $rc: $out"
( cd "$CL" && git rev-parse --verify --quiet HEAD >/dev/null 2>&1 ) && bad "a commit was made in his folder" || ok "no commit was made in his folder"
case "$out" in *"Створити тут git"*) bad "it still asked about git" ;; *) ok "nothing asked about git" ;; esac
bash "$NS" stop "$CL" >/dev/null 2>&1

echo "===== without the flag the same folder still gets the question ====="
Q="$TMP/documents"; mkdir -p "$Q"; echo x > "$Q/a.txt"
"${APP[@]}" bash "$NS" start "$Q" --no-attach >/dev/null 2>&1; rc=$?
[ "$rc" = 76 ] && ok "asked whether to create git (76)" || bad "exit $rc"
[ -e "$Q/.git" ] && bad ".git created without consent" || ok "and created nothing"

echo "===== 2. a resume of a plain run stays one ====="
R="$TMP/resumed"; mkdir -p "$R"; record_plain "$R"
out="$(SUPERVISOR_ENABLE_RESUME=1 SUPERVISOR_PLAIN_FOLDER=1 bash "$NS" resume "$R" "00000000-0000-4000-8000-000000000001" - --no-attach 2>&1)"; rc=$?
RIDIR="$(instance_dir "$(slug_for "$(canon_path "$R")")")"
[ "$rc" = 0 ] && ok "resumed (exit 0)" || bad "resume exit $rc: $out"
plain_folder_run "$RIDIR" && ok "the resumed run in a fresh instance folder is still a plain one" || bad "the resume lost it"
[ -e "$R/.git" ] && bad "resume made a .git" || ok "and no .git"
bash "$NS" stop "$R" >/dev/null 2>&1

echo "===== 3. only Bulava's signature makes a folder a job's ====="
G="$TMP/gate-folder"; mkdir -p "$G"
GIDIR="$(instance_dir "$(slug_for "$(canon_path "$G")")")"; mkdir -p "$GIDIR"
printf '%s\n' "$(canon_path "$G")" > "$GIDIR/project"; printf 'plain-run-1\n' > "$GIDIR/run-id"
plain_folder_run "$GIDIR" && bad "a folder with no record was taken for a job's" || ok "no record: not a job's"
record_plain "$G" "$KEYDIR/other.pem"
plain_folder_run "$GIDIR" && bad "a record signed by another key was believed" || ok "signed by another key: not believed"
OTHER="$TMP/elsewhere"; mkdir -p "$OTHER"
record_plain "$G" "$KEYDIR/priv.pem" "$(slug_for "$(canon_path "$OTHER")")"
plain_folder_run "$GIDIR" && bad "a signature made for another folder was believed" || ok "a signature for another folder: not believed"
record_plain "$G"
plain_folder_run "$GIDIR" && ok "signed for this folder: a job's" || bad "the genuine record was not believed"
# A run of code moving its instance folder under a job's name keeps its own project in it.
CODE="$TMP/code-copy"; mkdir -p "$CODE"
( cd "$CODE" && git init -q && git config user.email t@t && git config user.name t && echo a > a && git add -A && git commit -qm init )
printf '%s\n' "$(canon_path "$CODE")" > "$GIDIR/project"
plain_folder_run "$GIDIR" && bad "an instance under a job's name with another project was believed" \
  || ok "an instance folder renamed after a job's, with another project in it, is not that job"
printf '%s\n' "$(canon_path "$G")" > "$GIDIR/project"
# A key swapped under the engine: the control guard marks the run, and its word is not taken.
jq -nc '{run_id:"plain-run-1", what:"the decision key changed"}' > "$(control_tamper_file "$GIDIR")"
plain_folder_run "$GIDIR" && bad "believed while the run is marked as tampered with" \
  || ok "while the run is marked for a swapped key, the record proves nothing"
rm -f "$(control_tamper_file "$GIDIR")"
plain_folder_run "$GIDIR" && ok "(and believed again once the mark is gone)" || bad "not believed after the mark went"
# A folder signed as plain that later becomes a git repository: the record is stale. Trust is bound to
# the folder still being plain, so a run there no longer skips review — even though the signature is
# genuine and for this very folder.
( cd "$G" && git init -q && git config user.email t@t && git config user.name t && echo m > m && git add -A && git commit -qm init )
plain_folder_run "$GIDIR" && bad "a plain record was still believed after the folder became a repository" \
  || ok "once the folder holds git history, its plain record no longer licenses skipping review"
# An unborn orphan branch over that history must not reopen the hole.
( cd "$G" && git checkout -q --orphan fresh )
plain_folder_run "$GIDIR" && bad "an orphan branch over existing history was taken for plain" \
  || ok "history behind an unborn orphan branch still counts — not a plain run"
rm -rf "$G/.git" "$G/m"
plain_folder_run "$GIDIR" && ok "(and believed again once the folder is plain)" || bad "not believed after the repo was removed"
GATE_W="$ROOT/hooks/write-gate.sh"
bashcall() {  # $1 = the command the worker would run in the plain folder
  jq -n --arg c "$1" --arg cwd "$G" '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}' \
    | ORCHESTRATOR_RUN_ID="plain-run-1" bash "$GATE_W" 2>/dev/null
}
denied() { printf '%s' "$1" | grep -q '"deny"'; }
denied "$(bashcall "echo \"export SUPERVISOR_PLAIN_FOLDER='1'\" >> $GIDIR/run-env")" \
  && ok "writing the run's saved environment from a shell is refused" || bad "run-env write was let through"
denied "$(bashcall "echo note > $G/plain-folder-notes.md")" && bad "the folder's own file with a like name was refused" \
  || ok "a file of the job's own with a like name is not ours"

echo "===== 4. the gate ====="
GATE="$ROOT/hooks/review-gate.sh"
FAKE="$TMP/fake"; mkdir -p "$FAKE"; CODEX_CALLED="$FAKE/called"; export CODEX_CALLED
cat > "$FAKE/codex" <<'EOF'
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
echo called >> "$CODEX_CALLED"
echo "STATE: COMPLETE"; echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"
TR="$TMP/transcript.jsonl"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
RID="plain-run-1"
mkcase() {
  rm -rf "$G"; mkdir -p "$G"
  rm -rf "$GIDIR"; mkdir -p "$GIDIR"
  printf '%s\n' "$(canon_path "$G")" > "$GIDIR/project"
  printf '%s\n' "$RID" > "$GIDIR/run-id"
  record_plain "$G"
  rm -f "$SUPERVISOR_STATE_DIR"/outcome-nudge-* "$SUPERVISOR_STATE_DIR"/rounds-* 2>/dev/null || true
}
declare_outcome() {   # $1 = result
  jq -nc --arg r "$1" --arg rid "$RID" --arg ts "$(date '+%F %T')" \
    '{schema:1, result:$r, summary:"Додав 2 задачі", ts:$ts, run_id:$rid}' > "$GIDIR/outcome.json"
}
rungate() {
  rm -f "$CODEX_CALLED"
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$G" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
      PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
done_is() { [ "$(cat "$GIDIR/done" 2>/dev/null)" = "$1" ]; }

for result in succeeded_changes succeeded_no_change succeeded_research; do
  mkcase; declare_outcome "$result"
  out="$(rungate)"
  done_is passed && ok "$result → passed" || bad "$result → done=$(cat "$GIDIR/done" 2>/dev/null) out=$out"
  [ -s "$CODEX_CALLED" ] && bad "$result: Codex was asked to review a plain folder" || ok "$result: no Codex round"
done

mkcase; declare_outcome failed; rungate >/dev/null
done_is needs-user && ok "failed → needs-user, as for every run" || bad "failed → $(cat "$GIDIR/done" 2>/dev/null)"

mkcase; RID_SAVED="$RID"; RID="an-older-run"; declare_outcome succeeded_changes; RID="$RID_SAVED"
out="$(rungate)"
done_is passed && bad "an outcome from another run was taken for this one" || ok "an outcome from another run is not this run's"

mkcase; declare_outcome succeeded_changes
jq -nc --arg rid "$RID" --arg ts "$(date '+%F %T')" '{class:"blocker", text:"memex відмовив: 401", run_id:$rid, ts:$ts}' \
  > "$GIDIR/findings.jsonl"
rungate >/dev/null
done_is needs-user && ok "a success beside a fresh blocker is not taken: parked for the director" \
  || bad "success with a fresh blocker → $(cat "$GIDIR/done" 2>/dev/null)"

mkcase
out1="$(rungate)"
printf '%s' "$out1" | grep -q '"decision": "block"' && ok "nothing declared: asked (1)" || bad "first stop not asked: $out1"
printf '%s' "$out1" | grep -q 'succeeded_changes — зробив те, що просили' \
  && ok "in a plain folder's words — no code, no diff" || bad "the ask talks about code: $out1"
[ -f "$GIDIR/done" ] && bad "parked after one ask" || ok "not parked yet"
rungate >/dev/null
out3="$(rungate)"
done_is needs-user && ok "nothing after two asks: parked for the director" || bad "third stop: done=$(cat "$GIDIR/done" 2>/dev/null) out=$out3"
[ -s "$CODEX_CALLED" ] && bad "Codex was asked" || ok "Codex never asked"

echo "===== he answers a parked run, and it finishes ====="
# Still parked (`done` = needs-user, its digest beside it): a plain folder's tree never looks changed,
# so the verdict must not be kept on that ground.
[ -s "$GIDIR/done-digest" ] && ok "(the parked verdict has its digest)" || bad "no done-digest written"
declare_outcome succeeded_changes
rungate >/dev/null
done_is passed && ok "the run that went on after his answer ends with its own verdict: passed" \
  || bad "kept the old verdict: $(cat "$GIDIR/done" 2>/dev/null)"

echo "===== a spent Codex window does not hold a plain run ====="
mkcase
CODEXUSE="$TMP/codex-usage"; printf '#!/bin/bash\nexit 0\n' > "$CODEXUSE"; chmod +x "$CODEXUSE"
now="$(date +%s)"
jq -n --argjson ts "$now" --argjson r "$(( now + 432000 ))" \
  '{ts:$ts, observed_at:$ts, source:"cli",
    five_hour:{used_percentage:4,  resets_at:($ts + 900),  window_minutes:300},
    seven_day:{used_percentage:100, resets_at:$r, window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/codex-usage.json"
[ "$(provider_state codex | cut -d' ' -f1)" = exhausted ] && ok "(Codex's week really reads as spent)" || bad "the fake did not make Codex read as spent"
out="$(printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$G" \
  | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 SUPERVISOR_CODEX_USAGE_CMD="$CODEXUSE" \
    PATH="$FAKE:$PATH" "$GATE" 2>/dev/null)"
printf '%s' "$out" | grep -q '"decision": "block"' && ok "nothing declared: asked to declare, not parked on Codex" \
  || bad "out=$out"
[ -f "$GIDIR/paused-for-limit.json" ] && bad "parked on a Codex window" || ok "no Codex pause recorded"
rm -f "$SUPERVISOR_STATE_DIR/codex-usage.json"

echo "===== without the record the same folder is not trusted ====="
mkcase; rm -f "$(plain_folder_file "$(basename "$GIDIR")")"; declare_outcome succeeded_changes
rungate >/dev/null
[ -s "$CODEX_CALLED" ] && ok "a success with no record is not taken at its word: it goes to the reviewer" \
  || bad "taken without Bulava's record and without a review: done=$(cat "$GIDIR/done" 2>/dev/null)"

echo "===== an ordinary run with no outcome is unchanged ====="
O="$TMP/ordinary"; mkdir -p "$O"
( cd "$O" && git init -q && git config user.email t@t && git config user.name t && echo a > a && git add -A && git commit -qm init )
OIDIR="$(instance_dir "$(slug_for "$(canon_path "$O")")")"; mkdir -p "$OIDIR"
printf '%s\n' "$(canon_path "$O")" > "$OIDIR/project"; printf '%s\n' "$RID" > "$OIDIR/run-id"
printf '%s\n' "$(git -C "$O" rev-parse HEAD)" > "$OIDIR/base-sha"
rm -f "$SUPERVISOR_STATE_DIR"/outcome-nudge-* 2>/dev/null
out="$(printf '{"session_id":"s2","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$O" \
  | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
    PATH="$FAKE:$PATH" "$GATE" 2>/dev/null)"
printf '%s' "$out" | grep -q 'ні змін коду, ні задекларованого результату' && ok "still asked in its own words" || bad "out=$out"

echo "===== 5. the servers an automation names ====="
W="$TMP/ws"; mkdir -p "$W/idir" "$W/proj"
rules="$(SUPERVISOR_ALLOW_TOOLS="memex, stepanok-deploy bad/name ;rm -rf,claude_ai_Atlassian" allowed_tool_rules)"
[ "$rules" = '["mcp__claude_ai_Atlassian","mcp__memex","mcp__stepanok-deploy"]' ] \
  && ok "names become rules; anything else is dropped" || bad "rules=$rules"
[ "$(SUPERVISOR_ALLOW_TOOLS="" allowed_tool_rules)" = '[]' ] && ok "none named: no rules" || bad "empty list gave rules"
ws="$(SUPERVISOR_UNATTENDED=1 SUPERVISOR_ALLOW_TOOLS="memex,chrome-devtools" worker_settings_for "$W/idir" "$W/proj")"
[ -f "$ws" ] || bad "no settings file: $ws"
jq -e '.permissions.allow | index("mcp__memex")' "$ws" >/dev/null && ok "memex allowed for the run" || bad "memex not allowed: $(cat "$ws")"
jq -e '.permissions.allow | index("mcp__browser")' "$ws" >/dev/null && ok "its own browser still allowed" || bad "browser lost"
jq -e '.permissions.deny | index("mcp__chrome-devtools")' "$ws" >/dev/null && ok "his Chrome still denied, named or not" || bad "chrome-devtools not denied"
ws2="$(SUPERVISOR_ALLOW_TOOLS="memex" worker_settings_for "$W/idir" "$W/proj")"
jq -e '.permissions.allow | index("mcp__memex")' "$ws2" >/dev/null && ok "named outside an unattended run too" || bad "not written: $ws2"
ws3="$(SUPERVISOR_ALLOW_TOOLS="" worker_settings_for "$W/idir" "$W/proj")"
case "$ws3" in "$W/idir/"*) jq -e '.permissions.allow // [] | index("mcp__memex") | not' "$ws3" >/dev/null \
  && ok "nothing named: nothing extra allowed" || bad "memex allowed without being named" ;;
  *) ok "nothing named: the shared settings, as before" ;; esac

echo
[ "$fails" = 0 ] && echo "✅ plain-folder runs are verified" || { echo "❌ plain-folder runs: $fails problem(s)"; exit 1; }
