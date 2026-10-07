#!/bin/bash
# An automation's run never waits on a permission dialog nobody can answer.
#
# His Claude Code settings had collected 605 "always allow" clicks, and a night run that met a
# dialog of its own waited in a pane nobody watched, counted as "waiting" rather than frozen. Pinned
# here: with nobody there the run's own browser is allowed and anything else is declined with the
# reason; with a person there nothing changes; every decision is written down; a dialog that slips
# past the hook is declined after a deadline; and an automation's worker is launched with a browser
# of its own and a Claude that does not update itself mid-run.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
HOOK="$ROOT/hooks/permission-gate.sh"
unset SUPERVISOR_UNATTENDED SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

TMP="$(mktemp -d)"
tmux_isolate "$TMP/tmux"
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

PROJ="$TMP/project"; mkdir -p "$PROJ"; PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SES="$(session_name "$SLUG")"
mkdir -p "$IDIR"; printf '%s\n' "$PROJ" > "$IDIR/project"; : > "$IDIR/started-at"
printf '%s\n' "$$" > "$IDIR/watchdog.pid"     # alive, so the folder counts as an active instance
DEC="$IDIR/permission-decisions.jsonl"

ask() {  # $1=event $2=tool $3=tool_input json → the hook's stdout
  jq -nc --arg ev "$1" --arg tool "$2" --argjson input "${3:-{\}}" --arg cwd "$PROJ" \
    '{hook_event_name:$ev, tool_name:$tool, tool_input:$input, cwd:$cwd, session_id:"s"}' \
    | bash "$HOOK"
}

echo "===== with a person there, the dialog is his ====="
out="$(ask PermissionRequest Bash '{"command":"rm -rf build"}')"
check "the hook says nothing"                    '[ -z "$out" ]'
check "and writes nothing down"                  '[ ! -s "$DEC" ]'

echo "===== with nobody there, the run's own browser is allowed ====="
export SUPERVISOR_UNATTENDED=1
out="$(ask PermissionRequest mcp__browser__navigate_page '{"url":"https://lawria.ai/app"}')"
check "allowed"                                  '[ "$(printf "%s" "$out" | jq -r .hookSpecificOutput.decision.behavior)" = allow ]'
check "as a PermissionRequest decision"          '[ "$(printf "%s" "$out" | jq -r .hookSpecificOutput.hookEventName)" = PermissionRequest ]'
check "and written down with the page"           'tail -1 "$DEC" | jq -e ".decision == \"allow\" and .what == \"https://lawria.ai/app\"" >/dev/null'

echo "===== anything else is declined with the reason, never left waiting ====="
out="$(ask PermissionRequest Bash '{"command":"open -a Safari"}')"
check "declined"                                 '[ "$(printf "%s" "$out" | jq -r .hookSpecificOutput.decision.behavior)" = deny ]'
check "telling the model what to do instead"     'printf "%s" "$out" | jq -r .hookSpecificOutput.decision.message | grep -q "report-outcome blocked"'
check "his own Chrome's tools are not the run's" '[ "$(ask PermissionRequest mcp__chrome-devtools__navigate_page "{}" | jq -r .hookSpecificOutput.decision.behavior)" = deny ]'
check "the command is in the record"             'grep -q "open -a Safari" "$DEC"'

echo "===== what auto mode declined, and a dialog on screen, are written down ====="
ask PermissionDenied Bash '{"command":"curl evil.example"}' >/dev/null
check "an auto-mode refusal is recorded"         'tail -1 "$DEC" | jq -e ".decision == \"auto-denied\"" >/dev/null'
jq -nc --arg cwd "$PROJ" '{hook_event_name:"Notification", notification_type:"permission_prompt", message:"Claude needs your permission to use Bash", cwd:$cwd}' | bash "$HOOK"
check "a dialog on screen leaves its time"       '[ "$(jq -r .message "$IDIR/permission-wait.json")" = "Claude needs your permission to use Bash" ]'
unset SUPERVISOR_UNATTENDED
check "a broken input changes nothing"           '[ -z "$(printf "not json" | bash "$HOOK")" ]'

echo "===== a dialog nobody answers is declined after the deadline — only with nobody there ====="
tmux new-session -d -s "$SES" "cat"
now=$(date +%s)
jq -nc --argjson at $((now - 700)) '{at:$at, message:"Allow Bash?"}' > "$IDIR/permission-wait.json"
check "with a person there it is left for him"   '! permission_wait_check "$IDIR" "$SES" "$now" && [ -f "$IDIR/permission-wait.json" ]'
printf "export SUPERVISOR_UNATTENDED='1'\n" > "$(run_env_file "$IDIR")"
jq -nc --argjson at $((now - 100)) '{at:$at, message:"Allow Bash?"}' > "$IDIR/permission-wait.json"
check "before the deadline it waits"             '! permission_wait_check "$IDIR" "$SES" "$now" && [ -f "$IDIR/permission-wait.json" ]'
jq -nc --argjson at $((now - 700)) '{at:$at, message:"Allow Bash?"}' > "$IDIR/permission-wait.json"
SUPERVISOR_PERMISSION_DECLINE_SETTLE=0 SUPERVISOR_PROMPT_WAIT=1 SUPERVISOR_INJECT_TYPE_TRIES=1 \
  permission_wait_check "$IDIR" "$SES" "$now"; rc=$?
check "after it, it is declined"                 '[ "$rc" = 0 ] && [ ! -f "$IDIR/permission-wait.json" ]'
check "and the decline is on the record"         'tail -1 "$DEC" | jq -e ".decision == \"declined-after-timeout\"" >/dev/null'
# A dialog he answered: the conversation moved on after it appeared.
TX="$TMP/transcript.jsonl"; : > "$TX"
printf 'sid-1' > "$IDIR/claude-session-id"
printf '%s\t%s\n' sid-1 "$TX" > "$IDIR/.transcript-path"
jq -nc --argjson at $((now - 700)) '{at:$at, message:"Allow Bash?"}' > "$IDIR/permission-wait.json"
touch "$TX"
check "an answered dialog is forgotten, not declined" '! permission_wait_check "$IDIR" "$SES" "$now" && [ ! -f "$IDIR/permission-wait.json" ]'
tmux kill-session -t "$SES" 2>/dev/null

echo "===== an automation's worker gets its own browser and keeps its Claude ====="
check "nothing for a chat with a person"         '[ -z "$(automation_mcp_flags)" ]'
flags="$(SUPERVISOR_UNATTENDED=1 automation_mcp_flags)"
check "an automation gets --mcp-config"          'printf "%s" "$flags" | grep -q -- "--mcp-config"'
cfg="$(printf "%s" "$flags" | sed -E "s/^--mcp-config '([^']*)' $/\\1/")"
check "naming a browser with no window and a throwaway profile" \
      'jq -e ".mcpServers.browser.args | index(\"--headless\") and index(\"--isolated\")" "$cfg" >/dev/null'
check "pinned to a version, not @latest"         '! jq -r ".mcpServers.browser.args[]" "$cfg" | grep -q "@latest"'
check "and never his Chrome on port 9222"        '! grep -q "9222" "$cfg"'
check "the run's choices carry it to later processes" 'case " $_RUN_ENV_VARS " in *" SUPERVISOR_UNATTENDED "*) true ;; *) false ;; esac'
check "no worker updates its Claude mid-run"     'run_env_stamp | grep -q "DISABLE_AUTOUPDATER=1"'

echo "===== the settings an automation's worker starts with ====="
printf '{"hooks":{"Stop":[]}}' > "$SUPERVISOR_STATE_DIR/worker-settings.json"
check "a chat with a person uses the shared file" '[ "$(worker_settings_for "$IDIR" "$PROJ")" = "$SUPERVISOR_STATE_DIR/worker-settings.json" ]'
ws="$(SUPERVISOR_UNATTENDED=1 worker_settings_for "$IDIR" "$PROJ")"
check "an automation gets its own copy"          '[ "$ws" = "$IDIR/worker-settings.json" ]'
check "allowing its browser as one server"       'jq -e ".permissions.allow | index(\"mcp__browser\")" "$ws" >/dev/null'
check "and keeping the engine hooks"             'jq -e ".hooks.Stop" "$ws" >/dev/null'

echo "===== an automation cannot reach the browser he works in ====="
# His real setup: chrome-devtools on port 9222 and thirteen of its tools allowed for good, which
# no PermissionRequest ever hears about. The deny has to be in the run's own settings.
FAKEHOME="$TMP/home"; mkdir -p "$FAKEHOME"
jq -n --arg p "$PROJ" '{
  mcpServers: {
    "chrome-devtools": {command:"npx", args:["-y","chrome-devtools-mcp@latest","--wsEndpoint","ws://127.0.0.1:9222/devtools/browser"]},
    "my-chrome":       {command:"npx", args:["chrome-devtools-mcp","--autoConnect"]},
    "pw":              {command:"npx", args:["@playwright/mcp@latest"]},
    "memex":           {type:"http", url:"https://memex.example/mcp"},
    "xcodebuildmcp":   {command:"npx", args:["-y","xcodebuildmcp@latest","mcp"]}
  },
  projects: {($p): {mcpServers: {"proj-chrome": {command:"node", args:["/opt/chrome-devtools-mcp/build/index.js"]}}}}
}' > "$FAKEHOME/.claude.json"
printf '{"mcpServers":{"site-browser":{"command":"npx","args":["chrome-devtools-mcp","--browserUrl","http://127.0.0.1:9333"]},"db":{"command":"psql-mcp"}}}' > "$PROJ/.mcp.json"
ws="$(HOME="$FAKEHOME" SUPERVISOR_UNATTENDED=1 worker_settings_for "$IDIR" "$PROJ")"
deny() { jq -e --arg r "$1" '.permissions.deny | index($r)' "$ws" >/dev/null; }
check "his chrome-devtools is denied"            'deny mcp__chrome-devtools'
check "a bridge to his Chrome under another name" 'deny mcp__my-chrome'
check "one he added for this project"            'deny mcp__proj-chrome'
check "one the project brings in .mcp.json"      'deny mcp__site-browser'
check "another browser MCP"                      'deny mcp__pw'
check "Claude in Chrome, his signed-in browser"  'deny mcp__claude-in-chrome'
check "his other tools stay usable"              '! deny mcp__memex && ! deny mcp__xcodebuildmcp && ! deny mcp__db'
check "and the run keeps its own browser"        '! deny mcp__browser && jq -e ".permissions.allow | index(\"mcp__browser\")" "$ws" >/dev/null'
check "a chat with a person is left as it was"   '[ "$(HOME="$FAKEHOME" worker_settings_for "$IDIR" "$PROJ")" = "$SUPERVISOR_STATE_DIR/worker-settings.json" ]'
emptyhome="$TMP/empty-home"; mkdir -p "$emptyhome"; rm -f "$PROJ/.mcp.json"
ws="$(HOME="$emptyhome" SUPERVISOR_UNATTENDED=1 worker_settings_for "$IDIR" "$PROJ")"
check "with no config at all the usual name is still denied" 'deny mcp__chrome-devtools && deny mcp__claude-in-chrome'

echo "===== the installer registers the gate for every worker ====="
SUPERVISOR_STATE_DIR="$TMP/fresh" bash "$ROOT/install.sh" --worker-settings-only >/dev/null 2>&1
W="$TMP/fresh/worker-settings.json"
for ev in PermissionRequest PermissionDenied Notification; do
  check "$ev → permission-gate.sh" 'jq -r ".hooks.$ev[0].hooks[0].command" "$W" | grep -q "permission-gate.sh"'
done
check "the notification hook listens for permission dialogs only" '[ "$(jq -r .hooks.Notification[0].matcher "$W")" = permission_prompt ]'

echo
[ "$fails" -eq 0 ] && echo "✅ permission gate: all checks pass" || echo "❌ permission gate: $fails failed"
[ "$fails" -eq 0 ]
