#!/bin/bash
# Bulava Report (bin/bulava-report.sh, bin/bulava-report-mcp.py, bin/lib/bulava_report.py):
#   • a report gets an id; a retry with the same key — or the same words — gets the same id, no copy
#   • twenty writers at once: twenty reports; ten racing on one key: one report
#   • secrets are scrubbed before anything is written; the store is private (0700 / 0600)
#   • reports are marked read only once the review that read them exists
#   • a pull from another machine brings its reports in once; one that cannot be reached is
#     "NOT CHECKED", an error, never "no reports"
#   • the MCP server speaks the protocol: initialize, tools/list, tools/call, errors, nothing else on stdout
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$ROOT/bin/bulava-report.sh"; MCP="$ROOT/bin/bulava-report-mcp.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/here"
STORE="$SUPERVISOR_STATE_DIR/bulava-reports"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }
count(){ find "$STORE/$1" -name 'br-*.json' 2>/dev/null | wc -l | tr -d ' '; }
perm(){ stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

echo "== an id, and a retry is the same report =="
a="$("$B" submit --title "Gate parked after PASS" --observed "the run parked" --key opp-495 2>/dev/null)"
b="$("$B" submit --title "Gate parked after PASS (retry)" --observed "the run parked" --key opp-495 2>/dev/null)"
check "an id comes back"                       '[[ "$a" =~ ^br-[0-9a-f]{16}$ ]]'
check "same key, same id"                      '[ "$a" = "$b" ]'
c="$("$B" submit --title "Verifier walks .venv" --observed "compileall failed on olefile2.py" 2>/dev/null)"
d="$("$B" submit --title "Verifier walks .venv" --observed "compileall failed on olefile2.py" 2>/dev/null)"
check "no key: the same words are the same report" '[ "$c" = "$d" ] && [ "$c" != "$a" ]'
check "two reports stored"                     '[ "$(count new)" = 2 ]'
check "the store is private"                   '[ "$(perm "$STORE")" = 700 ] && [ "$(perm "$STORE/new/$a.json")" = 600 ]'
check "engine version recorded"                '[ -n "$("$B" show "$a" | jq -r .engine_version)" ]'

echo "== bad input is refused, nothing written =="
check "no title: refused"                      '! "$B" submit --observed x >/dev/null 2>&1'
check "bad severity: refused"                  '! "$B" submit --title x --observed y --severity urgent >/dev/null 2>&1'
check "still two"                              '[ "$(count new)" = 2 ]'

echo "== many writers at once =="
for i in $(seq 1 20); do "$B" submit --title "parallel $i" --observed "o $i" >/dev/null 2>&1 & done; wait
check "twenty distinct reports"                '[ "$(count new)" = 22 ]'
for i in $(seq 1 10); do "$B" submit --title "race" --observed "o" --key same-key >"$TMP/race.$i" 2>/dev/null & done; wait
check "ten racing on one key: one report"      '[ "$(count new)" = 23 ]'
check "…and all ten got its id"                '[ "$(cat "$TMP"/race.* | sort -u | wc -l | tr -d " ")" = 1 ]'
check "no temp files left"                     '[ -z "$(find "$STORE" -name ".tmp*" -o -name "*.tmp-*")" ]'

echo "== secrets are scrubbed before they are written =="
# Assembled at run time, so the file itself carries nothing a secret scanner would stop the export for.
fake_sk="sk""-live-abcdefghijklmnop"; fake_gh="gh""p_ABCDEFGHIJKLMNOPQRSTUVWX12"; fake_bearer="Bear""er abcdefghijklmnopqrstuv"
s="$("$B" submit --title "token leak" --observed "API_KEY=$fake_sk and $fake_gh https://bob:hunter2@gitlab.example.com" --evidence "$fake_bearer" 2>/dev/null)"
check "nothing of the secrets on disk"         '! grep -rqE "sk-live|ghp_ABC|hunter2|abcdefghijklmnopqrstuv" "$STORE"'
check "the redaction marks are there"          '"$B" show "$s" | grep -q REDACTED'

# Field values, whole: JSON, quoted with spaces, nested, lists. The names are assembled at run time
# for the same reason as above.
pw="pass""word"; PW="PASS""WORD"; ak="api""_key"
j="$("$B" submit --title "json leak" --observed "{\"$pw\":\"review_test_value\",\"$ak\":\"review_test_key\",\"auth\":{\"to""ken\":\"nested_value\"},\"to""kens\":[\"l1\",\"l2\"]} and $PW=\"review test value\" and author: bob, tests passed: 5" 2>/dev/null)"
check "JSON field values are hidden"           '! grep -qE "review_test_value|review_test_key|nested_value|\"l1\"" "$STORE/new/$j.json"'
check "a quoted value with spaces goes whole"  '! grep -qE "test value" "$STORE/new/$j.json"'
check "ordinary words survive"                 'grep -q "author: bob, tests passed: 5" "$STORE/new/$j.json"'

echo "== marked read only after the review exists =="
check "no review: refused"                     '! "$B" ack "$a" >/dev/null 2>&1'
check "an empty review: refused"               ': > "$TMP/empty.md"; ! "$B" ack --review "$TMP/empty.md" "$a" >/dev/null 2>&1'
check "still new"                              '[ -f "$STORE/new/$a.json" ]'
echo "огляд тижня" > "$TMP/review.md"
"$B" ack --review "$TMP/review.md" "$a" >/dev/null
check "moved to done, naming the review"       '[ ! -e "$STORE/new/$a.json" ] && [ "$(jq -r .review "$STORE/done/$a.json")" = "$TMP/review.md" ]'
check "a retry after ack is still the same report" '[ "$("$B" submit --title t --observed o --key opp-495 2>/dev/null)" = "$a" ] && [ ! -e "$STORE/new/$a.json" ]'

echo "== a pull from another machine =="
# A fake ssh that runs the remote command against another state folder, as that machine would.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/ssh" <<'EOF'
#!/bin/bash
cmd="${@: -1}"
[ "${FAKE_SSH_DOWN:-0}" = 1 ] && { echo "ssh: connect to host vm port 22: Connection refused" >&2; exit 255; }
SUPERVISOR_STATE_DIR="$FAKE_REMOTE_STATE" HOME="$FAKE_REMOTE_STATE" exec sh -c "$cmd"
EOF
chmod +x "$TMP/fakebin/ssh"
export FAKE_REMOTE_STATE="$TMP/vm"
r1="$(SUPERVISOR_STATE_DIR="$TMP/vm" "$B" submit --title "VM: check voided" --observed "tree moved" --key vm-1 2>/dev/null)"
r2="$(SUPERVISOR_STATE_DIR="$TMP/vm" "$B" submit --title "VM: WIP commit" --observed "override committed" --key vm-2 2>/dev/null)"
before="$(count new)"
out="$(PATH="$TMP/fakebin:$PATH" "$B" pull staging06 -- vm 2>&1)"
check "both VM reports came in"                '[ "$(count new)" = $((before + 2)) ] && [ -f "$STORE/new/$r1.json" ]'
check "and say where from"                     '[ "$(jq -r .pulled_from "$STORE/new/$r1.json")" = staging06 ]'
out="$(PATH="$TMP/fakebin:$PATH" "$B" pull staging06 -- vm 2>&1)"
check "a second pull adds nothing"             '[ "$(count new)" = $((before + 2)) ] && grep -q "0 new here" <<<"$out"'
"$B" ack --review "$TMP/review.md" "$r1" >/dev/null
PATH="$TMP/fakebin:$PATH" "$B" pull staging06 -- vm >/dev/null 2>&1
check "a read report is not pulled again"      '[ ! -e "$STORE/new/$r1.json" ]'
# A report written on a machine by an engine that scrubbed less is scrubbed again when it comes in.
mkdir -p "$TMP/vm/bulava-reports/new"
jq -n --arg o "$PW=\"old engine value\" {\"$pw\":\"old_json_value\"}" \
  '{schema:1, id:"br-00000000000000aa", title:"old", observed:$o, evidence:[], created_at:"2026-11-01T00:00:00+02:00"}' \
  > "$TMP/vm/bulava-reports/new/br-00000000000000aa.json"
PATH="$TMP/fakebin:$PATH" "$B" pull staging06 -- vm >/dev/null 2>&1
check "a pulled report is scrubbed again"      '[ -f "$STORE/new/br-00000000000000aa.json" ] && ! grep -qE "old engine value|old_json_value" "$STORE/new/br-00000000000000aa.json"'
out="$(FAKE_SSH_DOWN=1 PATH="$TMP/fakebin:$PATH" "$B" pull staging03 -- vm 2>&1)"; rc=$?
check "unreachable: an error"                  '[ "$rc" -ne 0 ]'
check "…that says NOT CHECKED"                 'grep -q "NOT CHECKED" <<<"$out"'
FAKE_REMOTE_STATE="$TMP/empty-vm" PATH="$TMP/fakebin:$PATH" "$B" pull fresh-vm -- vm >"$TMP/fresh.out" 2>&1; rc=$?
check "a machine with no store: zero, not an error" '[ "$rc" = 0 ] && grep -q "0 report(s) there" "$TMP/fresh.out"'

echo "== the MCP server speaks the protocol =="
req(){ printf '%s\n' "$@" | (cd "$TMP" && python3 "$MCP" 2>"$TMP/mcp.err"); }
out="$(req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
           '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
           '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
           '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"submit_report","arguments":{"title":"MCP report","observed":"from a chat","severity":"high","evidence":["run-events.jsonl"],"idempotency_key":"mcp-1"}}}' \
           '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"submit_report","arguments":{"title":"MCP report","observed":"from a chat","idempotency_key":"mcp-1"}}}' \
           '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"submit_report","arguments":{"observed":"no title"}}}' \
           '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"delete_reports","arguments":{}}}' \
           '{"jsonrpc":"2.0","id":7,"method":"resources/list"}' \
           'not json' \
           '{"jsonrpc":"2.0","id":8,"method":"ping"}')"
line(){ printf '%s\n' "$out" | jq -c "select(.id == $1)"; }
check "every line on stdout is JSON-RPC"       'printf "%s\n" "$out" | jq -e ".jsonrpc == \"2.0\"" >/dev/null'
check "the notification got no answer"         '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 9 ]'
check "initialize: the asked version"          '[ "$(line 1 | jq -r .result.protocolVersion)" = 2025-06-18 ] && [ "$(line 1 | jq -r .result.serverInfo.name)" = bulava-report ]'
v="$(req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}' | jq -r .result.protocolVersion)"
check "an unknown version gets the newest"     '[ "$v" = 2026-07-28 ]'
check "one tool, submit_report"                '[ "$(line 2 | jq -r "[.result.tools[].name] | join(\",\")")" = submit_report ]'
id3="$(line 3 | jq -r .result.structuredContent.id)"
check "a call stores and returns the id"       '[[ "$id3" =~ ^br-[0-9a-f]{16}$ ]] && [ -f "$STORE/new/$id3.json" ] && [ "$(line 3 | jq -r .result.isError)" = false ]'
check "the retry: same id, already_stored"     '[ "$(line 4 | jq -r .result.structuredContent.id)" = "$id3" ] && [ "$(line 4 | jq -r .result.structuredContent.status)" = already_stored ]'
check "a bad call is a tool error, not a crash" '[ "$(line 5 | jq -r .result.isError)" = true ]'
check "an unknown tool: invalid params"        '[ "$(line 6 | jq -r .error.code)" = -32602 ]'
check "an unknown method: method not found"    '[ "$(line 7 | jq -r .error.code)" = -32601 ]'
check "garbage: parse error, and it goes on"   'printf "%s\n" "$out" | jq -e "select(.error.code == -32700)" >/dev/null && [ "$(line 8 | jq -c .result)" = "{}" ]'
check "the reporter is recorded as mcp"        '[ "$(jq -r .reporter "$STORE/new/$id3.json")" = mcp ]'

echo "== mcp-config for a worker launch =="
cfg="$("$B" mcp-config)"
check "names this engine's server"             '[ "$(jq -r ".mcpServers[\"bulava-report\"].args[0]" <<<"$cfg")" = "$MCP" ]'

echo "== a server worker gets it from the engine; a Mac worker from the user's registration =="
flags(){ bash -c '. "$1/bin/supervisor-lib.sh"; report_mcp_flags "$2"' _ "$ROOT" "$TMP"; }
check "Mac profile: no flag"                   '[ -z "$(SUPERVISOR_PROFILE= flags)" ]'
check "server: --mcp-config to this engine's server" '[ -n "$(SUPERVISOR_PROFILE=server flags)" ] && [ "$(jq -r ".mcpServers[\"bulava-report\"].args[0]" "$TMP/bulava-report-mcp.json")" = "$MCP" ]'
check "server, turned off: no flag"            '[ -z "$(SUPERVISOR_PROFILE=server SUPERVISOR_BULAVA_REPORT=0 flags)" ]'
check "wired into both worker launches"        '[ "$(grep -c "report_mcp_flags \"\$IDIR\"" "$ROOT/bin/night-shift.sh")" = 2 ]'

echo "== the week's chats: messages by their own time, chats joined by id =="
# A chat carried on after the week: Monday's message, the chat touched again on Tuesday 08:00 Kyiv,
# the review at 09:00. Choosing chats by updatedAt inside the week lost Monday.
DATA="$TMP/appdata"; mkdir -p "$DATA"
cat > "$DATA/chats.json" <<'J'
[{"id":"AAAAAAAA-0000-0000-0000-000000000001","productID":"P1","title":"Tenders","updatedAt":"2026-11-10T06:00:00Z"},
 {"id":"BBBBBBBB-0000-0000-0000-000000000002","productID":"P1","title":"Old","updatedAt":"2026-11-05T10:00:00Z"}]
J
cat > "$DATA/products.json" <<'J'
[{"id":"P1","name":"Tenders automation"}]
J
cat > "$DATA/conversations.json" <<'J'
[{"chatID":"AAAAAAAA-0000-0000-0000-000000000001","productID":"P1","kind":"user","text":"понеділкове повідомлення","at":"2026-11-09T09:00:00Z"},
 {"chatID":"AAAAAAAA-0000-0000-0000-000000000001","productID":"P1","kind":"user","text":"вівторок, уже після тижня","at":"2026-11-10T06:00:00Z"},
 {"chatID":"BBBBBBBB-0000-0000-0000-000000000002","productID":"P1","kind":"user","text":"до тижня","at":"2026-11-01T12:00:00Z"}]
J
OUT="$TMP/week"
"$B" chats --out "$OUT" --data-dir "$DATA" --from 2026-11-03T00:00:00+02:00 --to 2026-11-10T00:00:00+02:00 >/dev/null
check "the Monday message of a chat updated after the week is there" 'grep -q "понеділкове повідомлення" "$OUT"/*__AAAAAAAA.md'
check "a message after the week is not"        '! grep -rq "уже після тижня" "$OUT"'
check "a chat with nothing in the week has no file" '[ ! -e "$OUT/Tenders_automation__BBBBBBBB.md" ] && [ "$(jq ".chats | length" "$OUT/index.json")" = 1 ]'
win="$(python3 -c 'import sys,datetime as d; sys.path.insert(0,sys.argv[1]); import chat_export as c
s,e=c.default_window(d.datetime(2026,11,10,9,0,tzinfo=c.KYIV)); print(s.isoformat(), e.isoformat())' "$ROOT/bin/lib")"
check "on Tuesday 09:00 the default week ends that Tuesday 00:00 Kyiv" '[ "$win" = "2026-11-03T00:00:00+02:00 2026-11-10T00:00:00+02:00" ]'

echo
echo "bulava report: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
