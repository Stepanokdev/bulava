#!/bin/bash
# Ordinary chat commands are answered automatically; dangerous removals get a useful refusal.
#
# Bash permission requests in attended chats are allowed unless a removal's target is dynamic or
# critical. Questions, plans, and other tools still wait for a person. Every automatic decision is
# recorded. Unattended runs retain their own browser policy and decline a missed dialog after its
# deadline. Commands below are sent as JSON to the hook only; none of them is executed.
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

expect_command() {  # $1=label $2=allow|deny $3=command (classified, never executed)
  local label="$1" expected="$2" command="$3" result actual
  result="$(ask PermissionRequest Bash "$(jq -nc --arg command "$command" '{command:$command}')")"
  actual="$(printf '%s' "$result" | jq -r '.hookSpecificOutput.decision.behavior' 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then ok "$label"; else bad "$label (expected $expected, got ${actual:-no decision})"; fi
  if ! tail -1 "$DEC" | jq -e --arg expected "$expected" --arg command "$command" \
    '.event == "PermissionRequest" and .tool == "Bash" and .decision == $expected and .what == ($command | gsub("[\\n\\r]+"; " ") | .[0:240])' >/dev/null; then
    bad "$label: automatic decision was not recorded"
  fi
  if [ "$expected" = deny ] && ! printf '%s' "$result" | jq -e \
    '.hookSpecificOutput.decision.message | test("literal path"; "i")' >/dev/null; then
    bad "$label: refusal did not ask for a literal path"
  fi
}

expect_human() {  # $1=label $2=tool $3=tool_input json
  local label="$1" count result
  count="$(wc -l < "$DEC" | tr -d ' ')"
  result="$(ask PermissionRequest "$2" "$3")"
  if [ -z "$result" ]; then ok "$label"; else bad "$label: hook answered a human prompt"; fi
  if [ "$(wc -l < "$DEC" | tr -d ' ')" != "$count" ]; then
    bad "$label: hook recorded an automatic decision"
  fi
}

echo "===== with a person there, ordinary command requests are allowed and recorded ====="
expect_command "a normal command is allowed" allow 'printf "%s\n" hello'
expect_command "ordinary echo is allowed" allow 'echo hello'
expect_command "numeric arguments do not confuse redirection parsing" allow 'printf 123 hello'
expect_command "a literal build directory may be removed" allow 'rm -rf build'
expect_command "a literal path with spaces may be removed" allow "rm -- 'build cache'"
expect_command "a project child by absolute path may be removed" allow "rm -rf -- '$PROJ/build'"
expect_command "a quoted dollar sign is a literal filename" allow 'rm -- '\''$TARGET'\'''
expect_command "a quoted substitution is a literal filename" allow 'rm -- '\''$(printf build)'\'''
expect_command "a quoted glob is a literal filename" allow "rm -- 'build*'"
expect_command "an escaped glob is a literal filename" allow 'rm -- build\*'
expect_command "a dash filename after -- is a literal target" allow 'rm -- -literal'
expect_command "removal text in printf is not a removal" allow 'printf "%s\n" "rm -rf /"'
expect_command "removal text in echo is not a removal" allow "echo 'rm -rf /'"
expect_command "a comment is not a removal" allow $'printf "%s\\n" hello\n# rm -rf /'
expect_command "an inline comment is not a removal" allow 'printf hello # rm -rf /'

echo "===== dynamic removals ask the model to rewrite with a literal path ====="
expect_command "a variable target is refused" deny 'rm -rf "$TARGET"'
expect_command "an unquoted variable target is refused" deny 'rm -rf $TARGET'
expect_command "a braced variable target is refused" deny 'rm -rf "${TARGET}/build"'
expect_command "a command substitution target is refused" deny 'rm -rf "$(printf build)"'
expect_command "a backtick substitution target is refused" deny 'rm -rf `printf build`'
expect_command "a wildcard target is refused" deny 'rm -rf build*'
expect_command "a question-mark glob target is refused" deny 'rm -rf build?'
expect_command "a bracket glob target is refused" deny 'rm -rf build[ab]'
expect_command "a brace expansion target is refused" deny 'rm -rf build{1,2}'
expect_command "an extended glob target is refused" deny 'rm -rf @(build|cache)'
expect_command "xargs removal targets from a file are refused" deny 'xargs -a targets rm -rf'
expect_command "xargs removal targets with a custom delimiter are refused" deny "xargs -d ':' rm -rf"
expect_command "a dangerous second target is refused" deny 'rm -rf build "$TARGET"'

echo "===== critical paths and their aliases are refused ====="
expect_command "the filesystem root is refused" deny 'rm -rf /'
expect_command "a root child is refused" deny 'rm -rf /tmp'
expect_command "the home directory is refused" deny "rm -rf -- '$HOME'"
expect_command "a tilde home target is refused" deny 'rm -rf ~'
expect_command "the working directory is refused" deny 'rm -rf .'
expect_command "the absolute working directory is refused" deny "rm -rf -- '$PROJ'"
expect_command "the working directory parent is refused" deny 'rm -rf ..'
expect_command "an absolute working directory parent is refused" deny "rm -rf -- '$TMP'"
expect_command "path normalization cannot hide the working directory" deny 'rm -rf build/..'
ln -s "$PROJ" "$TMP/project-link"
expect_command "a symlink to the working directory is refused" deny "rm -rf -- '$TMP/project-link'"
expect_command "rmdir protects the working directory too" deny 'rmdir .'
expect_command "an absolute rm executable still protects root" deny '/bin/rm -rf /'
expect_command "sudo cannot bypass root protection" deny 'sudo rm -rf /'
expect_command "env cannot bypass root protection" deny 'env rm -rf /'
expect_command "command cannot bypass root protection" deny 'command rm -rf /'
expect_command "a busybox removal applet cannot bypass root protection" deny 'busybox rm -rf /'
expect_command "a wrapper working-directory option cannot bypass root protection" deny 'env --chdir=/ rm -rf usr'
expect_command "a Windows drive root is refused on every platform" deny "rm -rf 'C:\\'"
expect_command "a Windows root child is refused" deny "rm -rf 'C:\\Windows'"
expect_command "a backslash-only target is refused" deny "rm -rf '\\'"

echo "===== nested shells and a changed working directory keep the safeguards ====="
expect_command "a nested shell variable removal is refused" deny 'sh -c '\''rm -rf "$TARGET"'\'''
expect_command "a grouped removal is refused" deny '(rm -rf /)'
expect_command "a brace-group removal is refused" deny '{ rm -rf /; }'
expect_command "a process-substitution removal is refused" deny 'cat <(rm -rf /)'
expect_command "an executed substitution removal is refused" deny 'printf "%s\n" "$(rm -rf /)"'
expect_command "parameter expansion cannot hide an executed removal" deny 'echo "${TARGET:-$(rm -rf /)}"'
expect_command "arithmetic expansion cannot hide an executed removal" deny 'echo "$(( $(rm -rf /) ))"'
expect_command "an executed backtick removal is refused" deny 'printf "%s\n" `rm -rf /`'
expect_command "changing directory before removing it is refused" deny 'cd .. && rm -rf .'
expect_command "removing the original working directory from its parent is refused" deny 'cd .. && rm -rf project'
expect_command "an unknown working directory cannot make removal safe" deny 'cd "$TARGET" && rm -rf build'
expect_command "eval cannot hide a critical working-directory change" deny "eval 'cd /'; rm -rf usr"
expect_command "pushd cannot hide a critical working-directory change" deny 'pushd /; rm -rf usr'
mkdir -p "$PROJ/build"
expect_command "a child removal from a known child directory is allowed" allow 'cd build && rm -rf cache'
padding="$(printf '%0250d' 0)"
expect_command "a dangerous target beyond the log preview is still refused" deny "printf '%s' '$padding'; rm -rf /"

echo "===== questions, plans, other tools, and malformed command requests stay human ====="
expect_human "AskUserQuestion stays with the person" AskUserQuestion '{"questions":[]}'
expect_human "ExitPlanMode stays with the person" ExitPlanMode '{}'
expect_human "an MCP interaction stays with the person" mcp__browser__navigate_page '{"url":"https://lawria.ai/app","requiresUserInteraction":true}'
expect_human "other MCP requests stay with the person" mcp__accounts__navigate_page '{"url":"https://lawria.ai/app"}'
expect_human "non-command tools stay with the person" Write '{"file_path":"example.txt","content":"hello"}'
expect_human "a missing Bash command stays human" Bash '{}'
expect_human "an empty Bash command stays human" Bash '{"command":""}'
expect_human "a null Bash command stays human" Bash '{"command":null}'
expect_human "a non-string Bash command stays human" Bash '{"command":["rm","-rf","/"]}'
expect_human "an attached env script option stays human" Bash '{"command":"env --split-string=\"rm -rf /\""}'
expect_human "a short attached env script option stays human" Bash '{"command":"env -S\"rm -rf /\""}'

echo "===== organization-managed ask rules keep their human approval ====="
POLICY_CONFIG="$TMP/policy-config"; mkdir -p "$POLICY_CONFIG"
printf '%s\n' '{"permissions":{"ask":["Bash(deploy *)"]}}' > "$POLICY_CONFIG/remote-settings.json"
CLAUDE_CONFIG_DIR="$POLICY_CONFIG" expect_human "a managed Bash ask keeps command prompts human" Bash '{"command":"printf hello"}'
printf '%s\n' 'not json' > "$POLICY_CONFIG/remote-settings.json"
CLAUDE_CONFIG_DIR="$POLICY_CONFIG" expect_human "an unreadable managed policy cannot auto-approve" Bash '{"command":"printf hello"}'
python3 - "$BIN_DIR/lib/permission-policy.py" "$TMP/policy-sources" <<'PY'
import importlib.util, json, pathlib, plistlib, sys
spec = importlib.util.spec_from_file_location("permission_policy", sys.argv[1])
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
root = pathlib.Path(sys.argv[2]); config = root / "config"; managed = root / "managed"
config.mkdir(parents=True); (managed / "managed-settings.d").mkdir(parents=True)
assert policy.policy_requires_human({"permissions": {"ask": ["Bash(run_in_background:true)"]}})
assert policy.policy_requires_human({"permissions": {"ask": ["B*"]}})
assert policy.policy_requires_human({"policyHelper": "never run this"})
assert not policy.policy_requires_human({"permissions": {"ask": ["Read", "mcp__service"]}})
paths = [config / "remote-settings.json", managed / "managed-settings.json",
         managed / "managed-settings.d" / "team.json"]
for path in paths:
    path.write_text(json.dumps({"permissions": {"ask": ["Bash(deploy *)"]}}))
    assert any(policy.policy_requires_human(p) for p in policy.managed_policies(config, managed, []))
    path.unlink()
mdm = root / "mdm.plist"
mdm.write_bytes(plistlib.dumps({"permissions": {"ask": ["Bash"]}}))
assert any(policy.policy_requires_human(p) for p in policy.managed_policies(config, managed, [mdm]))
PY
policy_rc=$?
check "remote, system, drop-in and MDM sources preserve managed asks" '[ "$policy_rc" = 0 ]'

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

echo "===== the browser finds a Chrome on Linux too ====="
mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/chromium"; chmod +x "$TMP/fakebin/chromium"
check "a Mac is told nothing about which Chrome"  '[ "$(OSTYPE=darwin23 browser_executable_args)" = "[]" ]'
if [ ! -x /opt/google/chrome/chrome ]; then
  lin="$(OSTYPE=linux-gnu PATH="$TMP/fakebin:$PATH" browser_executable_args)"
  check "Linux without Google's Chrome drives the Chromium it has" \
        '[ "$(printf "%s" "$lin" | jq -r ".[1]")" = "$TMP/fakebin/chromium" ]'
  lflags="$(OSTYPE=linux-gnu PATH="$TMP/fakebin:$PATH" SUPERVISOR_UNATTENDED=1 automation_mcp_flags)"
  lcfg="$(printf "%s" "$lflags" | sed -E "s/^--mcp-config '([^']*)' $/\\1/")"
  check "…and an automation's config names it"    'jq -e --arg p "$TMP/fakebin/chromium" ".mcpServers.browser.args | index(\"--executablePath\") and index(\$p)" "$lcfg" >/dev/null'
  check "…keeping the window off and the profile throwaway" \
        'jq -e ".mcpServers.browser.args | index(\"--headless\") and index(\"--isolated\")" "$lcfg" >/dev/null'
fi
case "${OSTYPE:-}" in darwin*)
  check "on a Mac the shipped config is used as it is" 'cmp -s "$cfg" "${SUPERVISOR_AUTOMATION_MCP_CONFIG:-$BIN_DIR/../supervisor/automation-mcp.json}"' ;;
esac

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
