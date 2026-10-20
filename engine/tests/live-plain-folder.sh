#!/bin/bash
# Live, against the real Claude Code CLI — not part of the suite: it needs `claude` on PATH, a
# signed-in Claude and a minute or two. A job's run in a plain folder, start to end, the way Bulava
# starts one (SUPERVISOR_PLAIN_FOLDER, SUPERVISOR_UNATTENDED, SUPERVISOR_ALLOW_TOOLS):
#   1. it starts in a folder with no git, and makes none;
#   2. the MCP server its automation names answers with nobody there to approve the call — memex,
#      when this Claude has it; the run only LISTS tasks and never adds one;
#   3. it declares how it ended, and the review gate takes that at its word: `done` is `passed`,
#      with no Codex round and no diff.
# Its own tmux server and state folder: nothing here touches a real run. The folder it works in is
# trusted for Claude the way Bulava trusts a job's folder, and forgotten again on the way out.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v claude >/dev/null || { echo "claude is not on PATH"; exit 1; }
CONFIG="$HOME/.claude.json"
T="$(mktemp -d)"
JOB="$(cd "$T" && pwd -P)/meetings-job"; mkdir -p "$JOB"

trust() {   # $1 = add | remove — both spellings Claude may look the folder up by
  python3 - "$CONFIG" "$1" "$JOB" "${JOB#/private}" <<'EOF'
import json, os, sys, tempfile
path, op, *folders = sys.argv[1:]
with open(path) as f: root = json.load(f)
projects = root.setdefault("projects", {})
for folder in folders:
    if op == "add":
        projects.setdefault(folder, {})["hasTrustDialogAccepted"] = True
    else:
        projects.pop(folder, None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f: json.dump(root, f, indent=2)
os.chmod(tmp, 0o600); os.replace(tmp, path)
EOF
}

tmux_isolate "$T/tmux"
# The trust goes last, after Claude has had time to exit: a Claude on its way out writes its config
# once more, and that write put the folder back the first time this ran.
trap 'bash "$ROOT/bin/night-shift.sh" stop "$JOB" >/dev/null 2>&1; tmux_cleanup; sleep 3; trust remove; rm -rf "$T"' EXIT INT TERM
unset SUPERVISOR_CLAUDE_CMD SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_RUN_ENV_FROM_APP
export SUPERVISOR_STATE_DIR="$T/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" bash "$ROOT/install.sh" --worker-settings-only >/dev/null \
  || { echo "could not write the worker settings"; exit 1; }
. "$ROOT/bin/supervisor-lib.sh"
trust add
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TOOLS=""; jq -e '.mcpServers.memex' "$CONFIG" >/dev/null 2>&1 && TOOLS="memex"

# Bulava's signed record that the folder is a job's (`plain_folder_run`), made the way the app makes
# it: a key of its own here, its public half where the engine looks, the folder's slug signed.
openssl ecparam -name prime256v1 -genkey -noout -out "$T/key.pem" 2>/dev/null
openssl ec -in "$T/key.pem" -pubout -out "$(decision_key_file)" 2>/dev/null
printf 'plain-folder|%s' "$(slug_for "$JOB")" > "$T/payload"
openssl dgst -sha256 -sign "$T/key.pem" -out "$T/sig" "$T/payload" 2>/dev/null
mkdir -p "$(dirname "$(plain_folder_file "$(slug_for "$JOB")")")"
jq -nc --arg s "$(base64 < "$T/sig" | tr -d '\n')" '{signature:$s}' > "$(plain_folder_file "$(slug_for "$JOB")")"

echo "===== start: a plain folder, no git ====="
tmux new-session -d -s keepalive "sleep 600"
out="$(SUPERVISOR_PLAIN_FOLDER=1 SUPERVISOR_UNATTENDED=1 SUPERVISOR_ALLOW_TOOLS="$TOOLS" \
       SUPERVISOR_CLAUDE_MODEL=sonnet SUPERVISOR_HANDSHAKE_WAIT=60 \
       bash "$ROOT/bin/night-shift.sh" start "$JOB" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "started" || { bad "start rc=$rc"; printf '%s\n' "$out" | tail -12 | sed 's/^/     /'; exit 1; }
IDIR="$(instance_dir "$(slug_for "$JOB")")"
plain_folder_run "$IDIR" && ok "the gate knows it as a job's run (signed for)" || bad "the signed record is not believed"
[ -e "$JOB/.git" ] && bad "a .git was made" || ok "no .git"

echo "===== the job: ask a service, declare ====="
if [ -n "$TOOLS" ]; then
  ask="Це перевірка автоматизації без git. Виклич інструмент mcp__memex__list_tasks з limit 1 — лише прочитати, нічого не додавай і не змінюй. Потім заяви результат рівно один раз: $IDIR/report-outcome succeeded_no_change \"memex відповів\" — або, якщо інструмент не спрацював, $IDIR/report-outcome failed \"що саме не спрацювало\"."
else
  ask="Це перевірка автоматизації без git. Нічого не роби, лише заяви результат рівно один раз: $IDIR/report-outcome succeeded_no_change \"нічого робити\"."
fi
sent="$(bash "$ROOT/bin/worker-send.sh" "$JOB" - - "$(cat "$IDIR/run-id")" "$ask" 2>&1)"
printf '%s' "$sent" | grep -q "^TIER=live" && ok "the message reached the run" || bad "send: $sent"

waited=0
while [ ! -s "$IDIR/done" ] && [ "$waited" -lt 300 ]; do sleep 3; waited=$((waited + 3)); done
[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ] && ok "the gate took the declared outcome: passed" \
  || bad "done=$(cat "$IDIR/done" 2>/dev/null) outcome=$(cat "$IDIR/outcome.json" 2>/dev/null)"
[ "$(jq -r .result "$IDIR/outcome.json" 2>/dev/null)" = succeeded_no_change ] && ok "declared succeeded_no_change" \
  || bad "outcome: $(cat "$IDIR/outcome.json" 2>/dev/null)"
jq -e '.verdict == "PASS"' "$IDIR/reports/review.json" >/dev/null 2>&1 && ok "with no review round to read a diff that does not exist" \
  || bad "review.json: $(cat "$IDIR/reports/review.json" 2>/dev/null)"
[ -e "$JOB/.git" ] && bad "a .git appeared during the run" || ok "still no .git"

if [ -n "$TOOLS" ]; then
  if grep -q '"tool":"mcp__memex' "$IDIR/permission-decisions.jsonl" 2>/dev/null \
     && grep '"tool":"mcp__memex' "$IDIR/permission-decisions.jsonl" | grep -q '"decision":"deny"'; then
    bad "memex was refused: $(grep mcp__memex "$IDIR/permission-decisions.jsonl" | tail -2)"
  else
    ok "memex was not refused"
  fi
  sid="$(cat "$IDIR/claude-session-id" 2>/dev/null)"
  transcript="$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
  if [ -n "$transcript" ] && grep -q '"name":"mcp__memex__list_tasks"' "$transcript"; then
    ok "the run called mcp__memex__list_tasks"
    jq -c 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | {is_error}' "$transcript" 2>/dev/null \
      | grep -q '"is_error":true' && bad "a tool call came back as an error" || ok "and got its answer"
  else
    bad "no memex call in the transcript ($transcript)"
  fi
else
  echo "  (memex is not set up for this Claude — the service part was not tried)"
fi

echo
[ "$fails" -eq 0 ] && echo "✅ a job's run in a plain folder works end to end" || { echo "❌ live plain folder: $fails problem(s)"; exit 1; }
