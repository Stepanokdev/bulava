#!/bin/bash
# What MCP servers exist, what each is for, and — the part that must never slip — what is not said.
#
# «For skills and MCPs I would like to have their description, if that is possible at all, if they
#
# It is possible without starting anything. A server declares its own instructions when it
# connects and Claude Code records that as a structured `mcp_instructions_delta` attachment, so
# the description is already on disk. Starting a server to read a caption would mean running
# third-party code for a line of text.
#
# The list comes from `claude mcp list` because the account's own connectors appear in no local
# file — a list built from `~/.claude.json` would silently omit half of what is connected.
#
# And the hard rule: a server's env holds API keys and `claude mcp get` prints Authorization
# headers. Nothing here may emit either, because this feeds a window that gets screenshotted.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_TRANSCRIPT_ROOT="$TMP/transcripts"
mkdir -p "$SUPERVISOR_TRANSCRIPT_ROOT/proj"

# A stub `claude` that answers `mcp list` the way the real one does — including a remote connector
# whose name carries a dot and a space, which is the shape that broke usage matching.
cat > "$TMP/claude" <<'C'
#!/bin/bash
[ "$1" = "mcp" ] && [ "$2" = "list" ] || exit 1
cat <<'OUT'
Checking MCP server health…

claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ! Needs authentication
claude.ai Atlassian: https://mcp.atlassian.com/v1/mcp - ✔ Connected
imagegen: node /Users/x/imagegen/dist/index.js - ✔ Connected
xcodebuildmcp: npx -y xcodebuildmcp@latest mcp - ✘ Failed to connect — timed out
OUT
C
chmod +x "$TMP/claude"
export SUPERVISOR_CLAUDE_BIN="$TMP/claude"

# Transcripts: one server describing itself, and calls to two servers.
python3 - "$SUPERVISOR_TRANSCRIPT_ROOT/proj/a.jsonl" <<'PY'
import json, sys
rows = [
  {"type": "attachment", "timestamp": "2026-08-01T10:00:00Z",
   "attachment": {"type": "mcp_instructions_delta",
                  "addedNames": ["claude.ai Atlassian", "imagegen"],
                  "addedBlocks": ["## claude.ai Atlassian\nUse the Teamwork Graph for relationships.",
                                  "## imagegen\nGenerates images from text."]}},
  # An older, superseded wording for the same server: the newest must win.
  {"type": "attachment", "timestamp": "2026-07-01T10:00:00Z",
   "attachment": {"type": "mcp_instructions_delta",
                  "addedNames": ["imagegen"],
                  "addedBlocks": ["## imagegen\nOLD WORDING."]}},
  {"type": "assistant", "timestamp": "2026-08-02T10:00:00Z",
   "message": {"content": [{"type": "tool_use", "name": "mcp__imagegen__text-to-image", "input": {}}]}},
  {"type": "assistant", "timestamp": "2026-08-03T10:00:00Z",
   "message": {"content": [{"type": "tool_use", "name": "mcp__imagegen__image-to-image", "input": {}}]}},
  {"type": "assistant", "timestamp": "2026-08-04T10:00:00Z",
   "message": {"content": [{"type": "tool_use", "name": "mcp__claude_ai_Atlassian__search", "input": {}}]}},
]
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY

out="$(bash "$BIN/mcp.sh" list --json 2>/dev/null)"
j() { printf '%s' "$out" | jq -e "$1" >/dev/null 2>&1; }

echo "===== the list is the CLI's, including connectors no file mentions ====="
j '.servers | length == 4' && ok "every server the CLI named is listed" \
  || bad "got $(printf '%s' "$out" | jq -r '.servers | length') servers"
j '[.servers[].name] | index("claude.ai Gmail")' && ok "an account connector is there" \
  || bad "the account connector was dropped"
j '[.servers[] | select(.name == "claude.ai Gmail")][0].scope == "account"' \
  && ok "and is marked as coming from the account" || bad "wrong scope for a connector"
j '[.servers[] | select(.name == "imagegen")][0].scope != "account"' \
  && ok "a locally configured one is not" || bad "a local server was called an account one"

echo "===== health is reported as the CLI sees it ====="
j '[.servers[] | select(.name == "xcodebuildmcp")][0].status == "failed"' \
  && ok "a failing server is failing" || bad "failure not detected"
j '[.servers[] | select(.name == "claude.ai Gmail")][0].status == "needs_auth"' \
  && ok "one that needs signing in says so" || bad "needs-auth not detected"
j '[.servers[] | select(.name == "claude.ai Atlassian")][0].status == "connected"' \
  && ok "and a working one is not dressed as a problem" || bad "connected not detected"
j '[.servers[] | select(.name == "claude.ai Atlassian")][0].transport == "http"' \
  && ok "a URL reads as http transport" || bad "transport wrong"

echo "===== descriptions come from what the server said about itself ====="
j '[.servers[] | select(.name == "imagegen")][0].description == "Generates images from text."' \
  && ok "the server's own words, without the heading" \
  || bad "description is $(printf '%s' "$out" | jq -r '[.servers[]|select(.name=="imagegen")][0].description')"
j '[.servers[] | select(.name == "imagegen")][0].description | test("OLD") | not' \
  && ok "and the newest wording wins over an older one" || bad "a superseded description survived"
j '[.servers[] | select(.name == "xcodebuildmcp")][0].description == ""' \
  && ok "a server that never described itself gets no invented caption" || bad "invented a description"

echo "===== usage is matched even when the name is not the tool prefix ====="
# `claude.ai Atlassian` appears in tool names as `claude_ai_Atlassian`; comparing the display name
# directly meant every account connector reported zero uses while being used daily.
j '[.servers[] | select(.name == "claude.ai Atlassian")][0].uses == 1' \
  && ok "a dotted, spaced name still matches its own calls" \
  || bad "uses = $(printf '%s' "$out" | jq -r '[.servers[]|select(.name=="claude.ai Atlassian")][0].uses')"
j '[.servers[] | select(.name == "imagegen")][0].uses == 2' \
  && ok "and a plain name counts every tool of that server" || bad "wrong count for imagegen"
j '[.servers[] | select(.name == "imagegen")][0].last == "2026-08-03"' \
  && ok "with the day it was last called" || bad "last-used wrong"

echo "===== nothing that could be a credential is ever emitted ====="
for secret in Authorization authorization API_KEY apiKey token password secret env headers; do
  case "$out" in *"$secret"*) bad "the output mentions '$secret'" ;; esac
done
ok "no credential-bearing field appears in the output"
src="$(cat "$BIN/lib/mcp-inventory.py")"
case "$src" in *'"env"'*|*"'env'"*) bad "the script reads a server's env" ;; *) ok "the script never reads env" ;; esac
# Backticks would EXECUTE what they quote — the first version of this line ran `claude mcp get`
# from inside the assertion about not calling it.
case "$src" in
  *'"get"'*) bad "it calls the mcp get command, which prints Authorization headers" ;;
  *)         ok "and never calls the command that prints headers" ;;
esac

echo "===== --fast answers without reading a single transcript ====="
fast="$(bash "$BIN/mcp.sh" list --json --fast 2>/dev/null)"
printf '%s' "$fast" | jq -e '.counted == false and (.servers | length == 4)' >/dev/null 2>&1 \
  && ok "the list is there and says it has not counted" || bad "fast mode is wrong: $fast"
printf '%s' "$fast" | jq -e '[.servers[].uses] | all(. == 0)' >/dev/null 2>&1 \
  && ok "with no counts claimed" || bad "fast mode invented counts"
printf '%s' "$fast" | jq -e '.transcripts == 0' >/dev/null 2>&1 \
  && ok "and no transcripts opened" || bad "fast mode read transcripts"

echo
if [ "$fails" -eq 0 ]; then echo "✅ servers, descriptions and usage — and no secrets"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
