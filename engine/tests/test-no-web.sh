#!/bin/bash
# A run without the web (SUPERVISOR_NO_WEB=1): neither model may reach the internet, and the switch
# has to hold at every call the engine makes, not only at the ones that asked for search.
#
# Pinned: off, nothing changes — research calls keep their search and no other call gains or loses
# anything. On, every `codex exec` carries the search setting under both names and the features that
# reach past the machine switched off (the ChatGPT apps connector, which searches on its own, the
# browsers, computer use, remote plugins); the research calls get the same instead of search; a
# `claude -p` the engine starts is denied WebSearch and WebFetch; the worker's settings deny both and
# turn claude.ai connectors off; the launch line and the environment say so; preflight skips its
# research and design stages even when a pipeline insists; the skill resolver does not run. And no
# script spells out `tools.web_search=true` any more, so a new call site cannot quietly bypass this.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
unset SUPERVISOR_UNATTENDED SUPERVISOR_NO_WEB ENABLE_CLAUDEAI_MCP_SERVERS SUPERVISOR_CODEX_EFFORT SUPERVISOR_CODEX_MODEL

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

PROJ="$TMP/project"; mkdir -p "$PROJ"

echo "===== off: the engine as it always was ====="
(
  fails=0
  . "$BIN_DIR/supervisor-lib.sh"
  flags="$(codex_effort_flags)"
  check "codex calls gain nothing" '! printf "%s" "$flags" | grep -q -e web_search -e "features\."'
  check "research calls keep their search" '[ "$(codex_web_search_flags)" = "-c tools.web_search=true" ]'
  check "claude -p is not restricted" '[ -z "$(claude_no_web_args)" ]'
  check "connectors are not touched" '[ -z "${ENABLE_CLAUDEAI_MCP_SERVERS:-}" ]'
  check "the launch line does not mention it" '! run_env_stamp | grep -q ENABLE_CLAUDEAI_MCP_SERVERS'
  IDIR="$TMP/inst-off"; mkdir -p "$IDIR"
  out="$(worker_settings_for "$IDIR" "$PROJ")"
  check "the worker gets no settings of its own" '[ -z "$out" ] || ! jq -e ".permissions.deny // [] | index(\"WebSearch\")" "$out" >/dev/null 2>&1'
  exit "$fails"
) || fails=$((fails + $?))

echo "===== on: no web anywhere ====="
(
  fails=0
  export SUPERVISOR_NO_WEB=1 SUPERVISOR_CODEX_EFFORT=high
  . "$BIN_DIR/supervisor-lib.sh"
  flags="$(codex_effort_flags)"
  check "effort still passed" 'printf "%s" "$flags" | grep -q -- "-c model_reasoning_effort=high"'
  for f in 'web_search="disabled"' 'tools.web_search=false' 'features.apps=false' 'features.browser_use=false' \
           'features.browser_use_external=false' 'features.computer_use=false' 'features.in_app_browser=false' \
           'features.remote_plugin=false'; do
    check "every codex call carries $f" 'printf "%s" "$flags" | grep -qF -- "-c $f"'
  done
  web="$(codex_web_search_flags)"
  check "research calls lose their search" '! printf "%s" "$web" | grep -q "web_search=true" && printf "%s" "$web" | grep -qF "features.apps=false"'
  check "claude -p denies WebSearch and WebFetch" '[ "$(claude_no_web_args)" = "--disallowedTools WebSearch,WebFetch" ]'
  check "claude.ai connectors are off for everything the engine starts" '[ "${ENABLE_CLAUDEAI_MCP_SERVERS:-}" = false ]'
  stamp="$(run_env_stamp)"
  check "the launch line carries the switch" 'printf "%s" "$stamp" | grep -q "SUPERVISOR_NO_WEB=.1."'
  check "the launch line turns connectors off for the worker" 'printf "%s" "$stamp" | grep -q "ENABLE_CLAUDEAI_MCP_SERVERS=false"'
  IDIR="$TMP/inst-on"; mkdir -p "$IDIR"
  out="$(worker_settings_for "$IDIR" "$PROJ")"
  check "the worker gets settings of its own" '[ -n "$out" ] && [ -s "$out" ]'
  check "the worker is denied WebSearch" 'jq -e ".permissions.deny | index(\"WebSearch\")" "$out" >/dev/null'
  check "the worker is denied WebFetch" 'jq -e ".permissions.deny | index(\"WebFetch\")" "$out" >/dev/null'
  check "the worker has claude.ai connectors off" '[ "$(jq -r .disableClaudeAiConnectors "$out")" = true ]'
  exit "$fails"
) || fails=$((fails + $?))

echo "===== preflight and the skill resolver ====="
check "preflight forces research and design off, whatever it was asked" \
  'grep -qF "if [ \"\${SUPERVISOR_NO_WEB:-}\" = 1 ]; then RESEARCH_MODE=never; DESIGN_MODE=never; fi" "$BIN_DIR/preflight.sh"'
check "preflight's own claude calls pass the restriction" \
  '[ "$(grep -c "claude_no_web_args) --permission-mode plan" "$BIN_DIR/preflight.sh")" -ge 2 ]'
check "the skill resolver does not run without the web" \
  'grep -q "SUPERVISOR_NO_WEB:-}\" = 1 \] && return 0" "$BIN_DIR/night-shift.sh"'

echo "===== no call site spells search on by hand ====="
hits="$(grep -rn "tools.web_search=true" "$ROOT/bin" "$ROOT/hooks" | grep -v "codex_web_search_flags()" \
          | grep -v "printf -- '-c tools.web_search=true'" || true)"
check "only the helper turns search on" '[ -z "$hits" ]'
[ -n "$hits" ] && printf '%s\n' "$hits"

if [ "$fails" -gt 0 ]; then echo "FAILED: $fails"; exit 1; fi
echo "all no-web checks passed"
