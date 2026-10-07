#!/bin/bash
# Bulava's browser, from the engine's side: what a run is given when it is on, and when it is not.
#
# Pinned: with Bulava's browser on, every run gets two browsers — a throwaway headless one, and
# Bulava's signed-in one through its door with the run's own token (kept for the whole run, private
# to it) — both allowed, and his own Chrome bridges denied, a chat he is in included; a run without
# him also has his sites closed in its client; with the browser off, switched off, or Bulava gone,
# everything is as before; and `$IDIR/browser` says who has it and lets go of it.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/bin"
unset SUPERVISOR_UNATTENDED
TMP="$(mktemp -d)"
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR/browser"
. "$BIN_DIR/supervisor-lib.sh"
FAKE=""
trap '[ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

SVC="$SUPERVISOR_STATE_DIR/browser/service.json"
on()  { jq -n --argjson pid "${1:-$$}" --argjson enabled "${2:-true}" \
          '{pid:$pid, enabled:$enabled, port:47293, blocked:["bank.example"], sites:[{host:"bank.example",withoutMe:false},{host:"play.google.com",withoutMe:true}]}' > "$SVC"; }
PROJ="$TMP/project"; mkdir -p "$PROJ"
FAKEHOME="$TMP/home"; mkdir -p "$FAKEHOME"
printf '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["chrome-devtools-mcp@latest","--wsEndpoint","ws://127.0.0.1:9222/devtools/browser"]}}}' > "$FAKEHOME/.claude.json"
args_of() { jq -r --arg s "$2" '.mcpServers[$s].args | join(" ")' "$1"; }

echo "===== on: a chat he is in gets both browsers ====="
on
CHAT="$TMP/chat"; mkdir -p "$CHAT"
flags="$(browser_mcp_flags "$CHAT")"
cfg="$CHAT/browser-mcp.json"
check "the run's own config is passed" '[ "$flags" = "--mcp-config $(shq "$cfg") " ]'
check "a throwaway headless browser" '[ "$(args_of "$cfg" browser)" = "-y chrome-devtools-mcp@1.10.1 --headless --isolated" ]'
acc="$(args_of "$cfg" accounts)"
check "and Bulava's, through its door on the loopback" 'printf "%s" "$acc" | grep -q -- "--wsEndpoint ws://127.0.0.1:47293/devtools/browser/bulava"'
token="$(jq -r .token "$CHAT/browser.json")"
check "with this run's own token" '[ "${#token}" -eq 48 ] && printf "%s" "$acc" | grep -q "Bearer $token"'
check "cookies kept out of what the run reads" 'printf "%s" "$acc" | grep -q -- "--redactNetworkHeaders"'
check "a chat he is in has no site closed" '! printf "%s" "$acc" | grep -q blockedUrlPattern'
check "the token is the run's alone (0600)" '[ "$(stat -f %Lp "$CHAT/browser.json")" = 600 ] && [ "$(stat -f %Lp "$cfg")" = 600 ]'
check "and says the run has him" '[ "$(jq -r .unattended "$CHAT/browser.json")" = false ]'
browser_mcp_flags "$CHAT" >/dev/null
check "a resumed run keeps its token" '[ "$(jq -r .token "$CHAT/browser.json")" = "$token" ]'
ws="$(HOME="$FAKEHOME" worker_settings_for "$CHAT" "$PROJ")"
check "both are allowed, nobody is asked" '[ "$(jq -c "[.permissions.allow[] | select(. == \"mcp__browser\" or . == \"mcp__accounts\")] | sort" "$ws")" = "[\"mcp__accounts\",\"mcp__browser\"]" ]'
check "his own Chrome is out of reach, in a chat too" 'jq -e ".permissions.deny | index(\"mcp__chrome-devtools\")" "$ws" >/dev/null'
check "and Bulava's own are not denied" '! jq -e ".permissions.deny | index(\"mcp__accounts\") or index(\"mcp__browser\")" "$ws" >/dev/null'

echo "===== on: a run without him has his sites closed ====="
NIGHT="$TMP/night"; mkdir -p "$NIGHT"
SUPERVISOR_UNATTENDED=1 browser_mcp_flags "$NIGHT" >/dev/null
acc="$(args_of "$NIGHT/browser-mcp.json" accounts)"
check "the bank is closed to it" 'printf "%s" "$acc" | grep -qF -- "--blockedUrlPattern *://{*.}?bank.example/*"'
check "a site he opened to such runs is not" '! printf "%s" "$acc" | grep -q "play.google.com"'
check "Bulava is told it works without him" '[ "$(jq -r .unattended "$NIGHT/browser.json")" = true ]'
check "a different token from the chat" '[ "$(jq -r .token "$NIGHT/browser.json")" != "$token" ]'

echo "===== off: as before ====="
on $$ false
OFF="$TMP/off"; mkdir -p "$OFF"
check "switched off: a chat gets nothing new" '[ -z "$(browser_mcp_flags "$OFF")" ] && [ ! -e "$OFF/browser.json" ]'
check "an automation keeps its throwaway browser" 'SUPERVISOR_UNATTENDED=1 browser_mcp_flags "$OFF" | grep -q automation-mcp.json'
check "and a chat keeps the shared settings" '[ "$(HOME="$FAKEHOME" worker_settings_for "$OFF" "$PROJ")" = "$SUPERVISOR_STATE_DIR/worker-settings.json" ] || [ -z "$(HOME="$FAKEHOME" worker_settings_for "$OFF" "$PROJ")" ]'
on 999999 true
check "Bulava gone: the same" '[ -z "$(browser_mcp_flags "$OFF")" ]'
rm -f "$SVC"
check "never installed: the same" '[ -z "$(browser_mcp_flags "$OFF")" ]'

echo "===== \$IDIR/browser ====="
on
REQ="$SUPERVISOR_STATE_DIR/browser-requests"; mkdir -p "$REQ"
ln -s "$BIN_DIR/worker-browser.sh" "$CHAT/browser"
fake_bulava() {
  ( while :; do
      for f in "$REQ"/*.json; do
        [ -e "$f" ] || continue
        id="$(basename "$f" .json)"; [ -e "$REQ/$id.done" ] && continue
        cp "$f" "$TMP/last-request.json"
        printf '%s' "$1" > "$REQ/$id.done"
      done
      sleep 0.05
    done ) &
  FAKE=$!
}
fake_bulava '{"ok":true,"state":"busy","holder":"Nightly","since":1791300000,"sites":[{"host":"bank.example","withoutMe":false}]}'
out="$("$CHAT/browser" status 2>&1)"; rc=$?
check "busy: who has it" '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "^busy: Nightly has it since"'
check "and the sites, with the ones kept for him" 'printf "%s" "$out" | grep -q "bank.example (only with him)"'
check "the request carries the run's token" '[ "$(jq -r .token "$TMP/last-request.json")" = "$token" ] && [ "$(jq -r .op "$TMP/last-request.json")" = status ]'
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""
fake_bulava '{"ok":true,"released":true}'
check "release" '[ "$("$CHAT/browser" release)" = released ]'
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""
fake_bulava '{"ok":true,"asked":true}'
out="$("$CHAT/browser" sign-in "https://search.google.com/search-console" 2>&1)"; rc=$?
check "sign-in: he is asked, in a window nobody drives" '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "^asked: .*search.google.com"'
check "the request names the page" '[ "$(jq -r .op "$TMP/last-request.json")" = signIn ] && [ "$(jq -r .url "$TMP/last-request.json")" = "https://search.google.com/search-console" ]'
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""
fake_bulava '{"ok":true,"asked":false,"reason":"He is signing in to a site in Bulava'"'"'s browser right now."}'
out="$("$CHAT/browser" sign-in "https://search.google.com/search-console" 2>&1)"; rc=$?
check "not asked while he is already signing in: said so, and not a success" '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "not asked — He is signing in" && ! printf "%s" "$out" | grep -q "^asked"'
kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; FAKE=""
"$CHAT/browser" sign-in "search console" >/dev/null 2>&1; rc=$?
check "sign-in without an address is refused before Bulava is asked" '[ "$rc" = 2 ]'
mkdir -p "$TMP/bare"; ln -s "$BIN_DIR/worker-browser.sh" "$TMP/bare/browser"
"$TMP/bare/browser" status >/dev/null 2>&1; rc=$?
check "a run with no token is told so" '[ "$rc" = 1 ]'

echo
[ "$fails" -eq 0 ] && echo "✅ account-browser: all checks pass" || echo "❌ account-browser: $fails failed"
[ "$fails" -eq 0 ]
