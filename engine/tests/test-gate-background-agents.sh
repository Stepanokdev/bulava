#!/bin/bash
# A server worker that ends its turn to wait for its own background subagents.
#
# What happened (6 Nov, OPP-495 on staging06): the worker gave the phone checks to two background
# subagents and ended its turn with "waiting on the device agents". The gate took the stop for a
# hand-in; the independent check ran while a subagent was still changing the Android repository,
# voided its own result, and the run was parked for a person.
#
# `background_agents_live` reads the transcript the Stop hook is given and names the subagents that
# are still at work. Asserted:
#   - a launched subagent with no terminal task-notification is live
#   - a notification that is only queued (`queue-operation`) settles it, as does a delivered one
#   - a subagent whose own transcript has been still past the idle limit is taken as gone
#   - background shells and the tool descriptions in the system prompt are not subagents
#   - nothing in the transcript at all: nothing live, and no error
set -u
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/review-gate.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fn="$T/fn.sh"
sed -n '/^background_agents_live() {/,/^}/p' "$GATE" > "$fn"
[ -s "$fn" ] || { echo "background_agents_live not found in $GATE"; exit 1; }
# shellcheck disable=SC1090
. "$fn"

A1=a3641e6b359cd2c73; A2=a74783cf3e3a553e5
tx="$T/sess.jsonl"; mkdir -p "$T/sess/subagents"
python3 - "$tx" "$A1" "$A2" <<'PY'
import json, sys
tx, a1, a2 = sys.argv[1:4]
rows = [
  {"type": "api-request-shape", "x": "<task-notification> arrives when the workflow completes. agentId: a0000000000000000"},
  {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
     "content": [{"type": "text", "text": "Async agent launched successfully.\nagentId: %s (internal ID)" % a1}]}]}},
  {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t2",
     "content": [{"type": "text", "text": "Async agent launched successfully.\nagentId: %s (internal ID)" % a2}]}]}},
  {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t3",
     "content": "Command running in background with ID: b0zjqh7f5."}]}},
  {"type": "assistant", "message": {"content": [{"type": "text", "text": "Waiting on the device agents."}]}},
]
open(tx, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
touch "$T/sess/subagents/agent-$A1.jsonl" "$T/sess/subagents/agent-$A2.jsonl"

live="$(background_agents_live "$tx" | tr '\n' ' ')"
[ "$live" = "$A1 $A2 " ] && ok "two launched subagents with no notification are live" || bad "expected both live, got '$live'"

python3 - "$tx" "$A2" <<'PY'
import json, sys
tx, a = sys.argv[1:3]
row = {"type": "queue-operation", "operation": "enqueue",
       "content": "<task-notification>\n<task-id>%s</task-id>\n<status>completed</status>\n</task-notification>" % a}
open(tx, "a").write(json.dumps(row) + "\n")
PY
live="$(background_agents_live "$tx" | tr '\n' ' ')"
[ "$live" = "$A1 " ] && ok "a queued completion settles a subagent before it is delivered" || bad "expected only $A1, got '$live'"

touch -t 202001010000 "$T/sess/subagents/agent-$A1.jsonl"
live="$(SUPERVISOR_BG_IDLE_SECONDS=600 background_agents_live "$tx")"
[ -z "$live" ] && ok "a subagent whose transcript is long still is taken as gone" || bad "idle subagent still live: '$live'"
touch "$T/sess/subagents/agent-$A1.jsonl"

python3 - "$tx" "$A1" <<'PY'
import json, sys
tx, a = sys.argv[1:3]
row = {"type": "user", "message": {"content": "<task-notification>\n<task-id>%s</task-id>\n<status>killed</status>" % a}}
open(tx, "a").write(json.dumps(row) + "\n")
PY
live="$(background_agents_live "$tx")"
[ -z "$live" ] && ok "a delivered notification with a terminal status settles the last one" || bad "still live: '$live'"

live="$(background_agents_live "$T/none.jsonl"; echo "rc=$?")"
[ "$live" = "rc=0" ] && ok "no transcript: nothing live, no error" || bad "missing transcript gave '$live'"

grep -q 'Subagents still at work' "$GATE" && grep -q 'SUPERVISOR_PROFILE:-}" = server' "$GATE" \
  && ok "the wait is wired into the gate, server profile only" || bad "the gate does not call the wait"

echo
[ "$fails" -eq 0 ] && echo "background agents: all passed" || echo "background agents: $fails failed"
exit "$fails"
