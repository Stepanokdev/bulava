#!/bin/bash
# A project's own MCP servers are asked about before the start, not discovered by a timeout.
#
# Claude Code stops on «2 new MCP servers found in this project — select any you wish to enable»
# before its session starts, so the SessionStart hook never confirms the run id. In the background
# nobody can answer: twelve seconds later the start was rolled back as a hooks problem, eight times
# in a row for one director. Now the engine sees the question coming (exit 78), the director answers
# it once, and the answer reaches every worker through its settings — nothing written into the
# project.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD SUPERVISOR_MCP_GATE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP
export SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# A `claude` that only writes down how it was launched — the real launch line, flags and all.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/claude-args"
sleep 30
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

NS="$BIN_DIR/night-shift.sh"
. "$BIN_DIR/supervisor-lib.sh"

make_repo() {   # $1=dir — a committed, clean repository that brings two MCP servers
  mkdir -p "$1"
  ( cd "$1" && git init -q -b main && git config user.name D && git config user.email d@example.com
    printf '%s\n' '{"mcpServers":{"oex-platform-index":{"command":"true"},"paragon":{"command":"true"}}}' > .mcp.json
    git add . && git commit -qm base )
}
stop() { bash "$NS" stop "$1" >/dev/null 2>&1 || true; }

echo "===== undecided servers: it asks before launching anything ====="
P="$TMP/ask"; make_repo "$P"; P="$(canon_path "$P")"
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 78 ] && ok "exit 78 — a question" || bad "exit $rc: $out"
case "$out" in *oex-platform-index*paragon*) ok "it names the servers" ;; *) bad "servers not named: $out" ;; esac
case "$out" in *"install.sh"*) bad "it still sends the director to reinstall hooks" ;; *) ok "and says nothing about reinstalling hooks" ;; esac
[ ! -e "$TMP/claude-args" ] && ok "claude was never launched" || bad "claude was launched"
[ ! -d "$SUPERVISOR_STATE_DIR/instances/$(slug_for "$P")" ] && ok "no run left behind" || bad "an instance was created"
[ "$(bash "$NS" mcp-state "$P" | jq -c .pending)" = '["oex-platform-index","paragon"]' ] \
  && ok "mcp-state reports both as waiting" || bad "mcp-state: $(bash "$NS" mcp-state "$P")"

out="$(SUPERVISOR_RUN_ENV_FROM_APP=1 bash "$NS" start "$P" --no-attach 2>&1)"
case "$out" in *"mcp-decide"*) bad "an older app got terminal commands: $out" ;;
  *"старіша за свій рушій"*) ok "an app without MCP buttons is told, in words, that it is out of date" ;; *) bad "$out" ;; esac

echo "===== enable: the run starts, and the worker is told ====="
bash "$NS" mcp-decide "$P" enable >/dev/null 2>&1 || bad "mcp-decide failed"
[ "$(bash "$NS" mcp-state "$P" | jq -c .pending)" = '[]' ] && ok "nothing is waiting any more" || bad "still pending"
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the run started" || bad "exit $rc: $out"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/claude-args" ] && break; sleep 0.5; done
settings="$(grep -A1 -x -- '--settings' "$TMP/claude-args" 2>/dev/null | tail -1)"
[ -n "$settings" ] && [ -f "$settings" ] && ok "claude was launched with a settings file of its own run" || bad "no --settings in: $(cat "$TMP/claude-args" 2>/dev/null)"
[ "$(jq -c '.enabledMcpjsonServers' "$settings" 2>/dev/null)" = '["oex-platform-index","paragon"]' ] \
  && ok "which enables exactly the servers the director enabled" || bad "settings: $(cat "$settings" 2>/dev/null)"
[ -z "$(git -C "$P" status --porcelain --untracked-files=all)" ] && [ ! -e "$P/.claude" ] \
  && ok "nothing was written into the project" || bad "the project changed: $(git -C "$P" status --porcelain)"
stop "$P"; rm -f "$TMP/claude-args"

echo "===== a server added later is asked about on its own; skip keeps it out ====="
( cd "$P" && printf '%s\n' '{"mcpServers":{"oex-platform-index":{"command":"true"},"paragon":{"command":"true"},"figma":{"command":"true"}}}' > .mcp.json && git commit -qam "one more" )
[ "$(bash "$NS" mcp-state "$P" | jq -c .pending)" = '["figma"]' ] && ok "only the new one waits" || bad "pending: $(bash "$NS" mcp-state "$P")"
bash "$NS" mcp-decide "$P" skip >/dev/null 2>&1
bash "$NS" start "$P" --no-attach >/dev/null 2>&1 && ok "the run started" || bad "start failed"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/claude-args" ] && break; sleep 0.5; done
settings="$(grep -A1 -x -- '--settings' "$TMP/claude-args" 2>/dev/null | tail -1)"
[ "$(jq -c '.disabledMcpjsonServers' "$settings" 2>/dev/null)" = '["figma"]' ] \
  && [ "$(jq -c '.enabledMcpjsonServers' "$settings" 2>/dev/null)" = '["oex-platform-index","paragon"]' ] \
  && ok "figma is off, the other two stay on" || bad "settings: $(cat "$settings" 2>/dev/null)"
stop "$P"; rm -f "$TMP/claude-args"

echo "===== answered in Claude itself: no second question ====="
P="$TMP/manual"; make_repo "$P"; P="$(canon_path "$P")"
mkdir -p "$P/.claude"; printf '%s\n' '{"disabledMcpjsonServers":["oex-platform-index","paragon"]}' > "$P/.claude/settings.local.json"
[ "$(bash "$NS" mcp-state "$P" | jq -c .pending)" = '[]' ] && ok "the answer in .claude/settings.local.json counts" || bad "asked again"
P2="$TMP/claudejson"; make_repo "$P2"; P2="$(canon_path "$P2")"
jq -n --arg p "$P2" '{projects: {($p): {enabledMcpjsonServers: ["oex-platform-index"], disabledMcpjsonServers: ["paragon"]}}}' > "$HOME/.claude.json"
[ "$(bash "$NS" mcp-state "$P2" | jq -c .pending)" = '[]' ] && ok "so does the one in ~/.claude.json" || bad "asked again"
P3="$TMP/all"; make_repo "$P3"; P3="$(canon_path "$P3")"
printf '%s\n' '{"enableAllProjectMcpServers":true}' > "$HOME/.claude/settings.json"
[ "$(bash "$NS" mcp-state "$P3" | jq -c .pending)" = '[]' ] && ok "and enableAllProjectMcpServers answers for all" || bad "asked again"
rm -f "$HOME/.claude/settings.json" "$HOME/.claude.json"

echo "===== no .mcp.json: nothing changes ====="
P="$TMP/plain"; mkdir -p "$P"; ( cd "$P" && git init -q -b main && git config user.name D && git config user.email d@e.x && echo x > x && git add x && git commit -qm base )
bash "$NS" start "$P" --no-attach >/dev/null 2>&1 && ok "started" || bad "refused"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/claude-args" ] && break; sleep 0.5; done
settings="$(grep -A1 -x -- '--settings' "$TMP/claude-args" 2>/dev/null | tail -1)"
case "$settings" in "$SUPERVISOR_STATE_DIR/instances/"*) bad "a per-run settings file appeared: $settings" ;;
  *) ok "no per-run settings file is made for nothing" ;; esac
stop "$P"; rm -f "$TMP/claude-args"

echo "===== the screen itself, if it ever gets that far ====="
[ "$(handshake_blocker "  2 new MCP servers found in this project
  Select any you wish to enable." "")" = mcp ] && ok "the several-servers screen reads as mcp" || bad "not recognised"
[ "$(handshake_blocker "  New MCP server found in this project: paragon" "")" = mcp ] && ok "and the one-server screen" || bad "not recognised"
says="$(handshake_blocker_says mcp "" "")"
case "$says" in *"mcp-decide"*) ok "the words point at the answer, not at install.sh" ;; *) bad "$says" ;; esac

echo "===== the night queue: it waits for the director ====="
P="$TMP/queued"; make_repo "$P"; P="$(canon_path "$P")"
Q="$SUPERVISOR_STATE_DIR/queue"; mkdir -p "$Q/pending/001-m"
printf '%s\n' "$P" > "$Q/pending/001-m/project"; echo "do it" > "$Q/pending/001-m/task"
SUPERVISOR_PREFLIGHT_ENABLE=0 bash "$BIN_DIR/queue-runner.sh" >/dev/null 2>&1
held="$(ls -1d "$Q/needs-user/001-m-needs-user-"* 2>/dev/null | head -1)"
[ -n "$held" ] && grep -q paragon "$held/why" 2>/dev/null && ok "held as needs-user, with the servers named" || bad "not held: $(ls -R "$Q")"

echo
[ "$fails" = 0 ] && echo "✅ mcp gate: asked before the start, never by a timeout" || echo "❌ mcp gate: $fails problem(s)"
exit "$fails"
