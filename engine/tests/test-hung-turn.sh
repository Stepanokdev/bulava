#!/bin/bash
# A worker that takes its task and freezes.
#
# What happened, from the transcript: the prepared task was typed, Enter was pressed, and Claude Code
# wrote the task into its transcript — then produced nothing for four hours, with a status that never
# said busy and a screen that never changed. `inject_task` read the screen, decided the task had not
# gone in, pressed Escape and handed it back; the watchdog typed it again three times into the frozen
# pane, marked the run stalled, and four hours later deleted it. Nothing ever restarted the process.
#
# A real tmux pane runs a stand-in for Claude Code that behaves exactly that way: it records what
# is submitted into a transcript file and, depending on its mode, answers or stops drawing for good.
# Asserted:
#   - a task the transcript recorded is DELIVERED: no second copy, no Escape after it
#   - a frozen turn is restarted in place and nudged, and the dying worker's own `stop` tail does
#     not take the instance down with it
#   - the attempt budget holds however many new entries the retries write, and ends visibly
#   - the director's Stop, an interruption, a tool still out and a usage limit are never "hangs"
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

TMP="$(mktemp -d -t hung-turn)" || exit 1
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM

export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME/.claude/sessions"
export SUPERVISOR_CLAUDE_USAGE_CMD=/usr/bin/true SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true
export SUPERVISOR_CLAUDE_REACHABLE_CMD=/usr/bin/true
export SUPERVISOR_TURN_PROBE_GAP=0.2 SUPERVISOR_INJECT_SETTLE=1 SUPERVISOR_INJECT_CALM=1
export SUPERVISOR_ENTER_CONFIRM_WAIT=2 SUPERVISOR_INJECT_ENTER_TRIES=3 SUPERVISOR_PROMPT_WAIT=20
export SUPERVISOR_RELAUNCH_HANDSHAKE_WAIT=15 SUPERVISOR_HUNG_NUDGE_RETRY=0
. "$BIN_DIR/supervisor-lib.sh"

PROJ="$TMP/project"; mkdir -p "$PROJ"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"
SID="11111111-2222-3333-4444-555555555555"
TX="$TMP/transcript.jsonl"

# ------------------------------------------------------------------ the stand-in for Claude Code
#
# Raw tty, like the real one. Carriage return submits (tmux's Enter); a line feed inside a paste is
# content. A submitted prompt is appended to the transcript as Claude Code writes it. Modes:
#   freeze  record the prompt, then never draw or answer again — the night's failure
#   answer  record the prompt, then an assistant reply, and keep going
# Every byte received is logged, so an Escape sent after the fact is visible.
cat > "$TMP/fake-claude.py" <<'PY'
import json, os, sys, tty, uuid
mode, transcript, log, idir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
if len(sys.argv) > 5:
    open(os.path.join(idir, "handshake-ok"), "w").close()   # what the SessionStart hook does
tty.setraw(0)
def draw(s):
    os.write(1, s.encode())
def entry(kind, text):
    import datetime
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    rec = {"type": kind, "uuid": str(uuid.uuid4()), "timestamp": stamp,
           "message": {"role": kind, "content": text if kind == "user" else [{"type": "text", "text": text}]}}
    if kind == "assistant":
        rec["message"]["model"] = "claude-test"
    with open(transcript, "a") as t:
        t.write(json.dumps(rec, ensure_ascii=False) + "\n")
draw("\r\n❯ ")
buf, frozen = b"", False
with open(log, "ab") as lg:
    while True:
        chunk = os.read(0, 4096)
        if not chunk:
            break
        lg.write(chunk); lg.flush()
        for b in chunk:
            if b == 13:
                text = buf.decode("utf-8", "replace")
                buf = b""
                if not text or frozen:
                    continue
                entry("user", text)
                if mode == "freeze":
                    frozen = True
                else:
                    entry("assistant", "Готово.")
                    draw("\r\n● Готово.\r\n❯ ")
            elif b == 27 or b == 21:
                buf = b""
            else:
                buf += bytes([b])
                if not frozen:
                    draw(bytes([b]).decode("latin-1") if b < 128 else "·")
PY

new_instance() {
  rm -rf "$IDIR"; mkdir -p "$IDIR"
  printf '%s\n' "$PROJ" > "$IDIR/project"
  printf '%s\n' "$SESSION" > "$IDIR/session"
  printf 'RUN-1\n' > "$IDIR/run-id"
  printf '%s' "$SID" > "$IDIR/claude-session-id"
  printf '%s\t%s\n' "$SID" "$TX" > "$IDIR/.transcript-path"
  : > "$TX"; rm -f "$TMP/bytes.log"
}

start_worker() {   # $1=mode — the launch line's shape: the worker, then its own stop tail
  local gen; gen="$(new_worker_generation "$IDIR")"
  tmux kill-session -t "$SESSION" 2>/dev/null
  tmux new-session -d -s "$SESSION" -x 160 -y 40 -c "$PROJ" \
    "python3 '$TMP/fake-claude.py' $1 '$TX' '$TMP/bytes.log' '$IDIR'; '$BIN_DIR/night-shift.sh' stop --generation '$gen' '$PROJ'" \
    || { echo "SKIP: cannot start tmux"; exit 0; }
  sleep 1
}

prompts() { jq -s '[.[] | select(.type == "user")] | length' "$TX" 2>/dev/null || echo 0; }
make_still() {   # the pane and the transcript have not changed for a long time
  touch -t 202601010000 "$TX" "$IDIR/last-activity" 2>/dev/null || true
}

echo "===== a task the transcript recorded is delivered, once ====="
new_instance; start_worker freeze
TASK="Працюй за стандартами. Задача: додай нові моделі в меню."
INJECT_IDIR="$IDIR" inject_task "$SESSION" "$TASK"; rc=$?
[ "$rc" = 0 ] && ok "inject_task reports it delivered (rc 0), not 'never started'" \
  || bad "inject_task returned $rc for a task the worker had recorded"
[ "$(prompts)" = 1 ] && ok "exactly one copy of the task is in the transcript" \
  || bad "the transcript holds $(prompts) copies"
if python3 - "$TMP/bytes.log" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
cr = data.find(b"\r")
sys.exit(0 if cr >= 0 and b"\x1b" not in data[cr:] and b"\x15" not in data[cr:] else 1)
PY
then ok "no Escape and no line-kill after the task went in"
else bad "the composer was 'cleared' at a worker that already had the task"
fi

echo "===== nothing is typed at a worker that owes an answer ====="
worker_owes_answer "$SESSION" "$IDIR" && ok "the frozen worker is seen to owe an answer" \
  || bad "a recorded, unanswered task was not seen as owed"
SUPERVISOR_PROMPT_WAIT=3 INJECT_IDIR="$IDIR" inject_task "$SESSION" "друге повідомлення"; rc=$?
[ "$rc" != 0 ] && [ "$(prompts)" = 1 ] && ok "a second message waits instead of going into the frozen pane" \
  || bad "a message was typed into a worker still owing an answer (rc $rc, prompts $(prompts))"

echo "===== a frozen turn is restarted in place and nudged ====="
old_gen="$(cat "$IDIR/worker-generation")"
old_pid="$(pgrep -f "fake-claude.py freeze" | head -1)"
save_relaunch_template "$IDIR" "python3 '$TMP/fake-claude.py' answer '$TX' '$TMP/bytes.log' '$IDIR' handshake; '$BIN_DIR/night-shift.sh' stop --generation @GENERATION@ '$PROJ'"
make_still
SUPERVISOR_HUNG_TURN_SECS=5 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1; rc=$?
sleep 2
[ "$rc" = 0 ] && ok "the watchdog acted on the frozen turn" || bad "the frozen turn was left alone"
[ -d "$IDIR" ] && ok "the dying worker's own stop tail did not take the instance down" \
  || bad "the instance was deleted by the replaced worker's stop"
[ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null && ok "the frozen process is gone" \
  || bad "the frozen process survived the restart ($old_pid)"
[ "$(cat "$IDIR/worker-generation" 2>/dev/null)" != "$old_gen" ] && ok "the replacement runs under a new generation" \
  || bad "the generation did not change"
jq -e 'select(.type == "user") | .message.content | contains("Сесію Claude Code перезапущено")' "$TX" >/dev/null 2>&1 \
  && ok "the restarted worker was nudged to carry on" || bad "no nudge reached the restarted worker"
[ "$(jq -r '.attempts' "$(hung_file "$IDIR")" 2>/dev/null)" = 1 ] && [ "$(jq -r '.nudge_owed' "$(hung_file "$IDIR")")" = false ] \
  && ok "one attempt charged, nothing left owed" || bad "episode record: $(cat "$(hung_file "$IDIR")" 2>/dev/null)"
grep -q "a replaced worker exited" "$SUPERVISOR_STATE_DIR/supervisor.log" 2>/dev/null \
  && ok "the old tail's stop was seen and ignored" || bad "the old tail never ran its stop, or ran it for real"

echo "===== the episode closes when the worker produces again ====="
hung_turn_check "$IDIR" "$SESSION" 0 RUN-1
[ ! -e "$(hung_file "$IDIR")" ] && ok "a real reply closed the episode" || bad "the episode stayed open after a reply"

echo "===== a message waiting for a frozen worker reaches the one that replaces it ====="
new_instance; start_worker freeze
INJECT_IDIR="$IDIR" inject_task "$SESSION" "Працюй за стандартами. Задача номер один." >/dev/null
park_undelivered "$IDIR" "Директор: і ще додай тест." "MSG-2" >/dev/null 2>&1
save_relaunch_template "$IDIR" "python3 '$TMP/fake-claude.py' answer '$TX' '$TMP/bytes.log' '$IDIR' handshake; '$BIN_DIR/night-shift.sh' stop --generation @GENERATION@ '$PROJ'"
sleep 1; make_still
SUPERVISOR_HUNG_TURN_SECS=5 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1 >/dev/null
sleep 2
jq -e 'select(.type == "user") | .message.content | contains("Сесію Claude Code перезапущено")' "$TX" >/dev/null 2>&1 \
  && bad "a generic nudge was typed although the director's own message was waiting" \
  || ok "no generic nudge in front of the director's waiting message"
worker_owes_answer "$SESSION" "$IDIR" && bad "the restarted worker is still held to the frozen question" \
  || ok "the restarted worker owes nothing to a question asked of its predecessor"
flush_undelivered "$SESSION" "$IDIR"; rc=$?
[ "$rc" = 0 ] && jq -e 'select(.type == "user") | .message.content | contains("і ще додай тест")' "$TX" >/dev/null 2>&1 \
  && ok "the waiting message is delivered to the restarted worker" \
  || bad "the waiting message never reached the restarted worker (rc $rc)"
hung_turn_check "$IDIR" "$SESSION" 0 RUN-1
[ ! -e "$(hung_file "$IDIR")" ] && ok "and its answer closes the episode" || bad "the episode outlived the answer"

echo "===== a composer somebody else holds costs nothing ====="
new_instance; start_worker freeze
INJECT_IDIR="$IDIR" inject_task "$SESSION" "Працюй за стандартами. Задача під чужим замком." >/dev/null
save_relaunch_template "$IDIR" "python3 '$TMP/fake-claude.py' answer '$TX' '$TMP/bytes.log' '$IDIR' handshake; '$BIN_DIR/night-shift.sh' stop --generation @GENERATION@ '$PROJ'"
frozen_pid="$(pgrep -f "fake-claude.py freeze" | head -1)"
mkdir -p "$IDIR/delivery.lock"; sleep 300 & holder=$!; printf '%s\n' "$holder" > "$IDIR/delivery.lock/pid"
make_still
for i in 1 2 3 4 5; do SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1; done
[ "$(jq -r '.attempts // 0' "$(hung_file "$IDIR")" 2>/dev/null || echo 0)" = 0 ] \
  && ok "five looks under somebody else's claim charged nothing" \
  || bad "the budget was spent while another process held the composer: $(cat "$(hung_file "$IDIR")" 2>/dev/null)"
kill -0 "$frozen_pid" 2>/dev/null && ok "and restarted nothing" || bad "the worker was restarted without the claim"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
make_still
SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1
[ "$(jq -r '.attempts // 0' "$(hung_file "$IDIR")" 2>/dev/null)" = 1 ] && ! kill -0 "$frozen_pid" 2>/dev/null \
  && ok "once the composer is free, the one attempt is made and charged" \
  || bad "after the claim was released: $(cat "$(hung_file "$IDIR")" 2>/dev/null)"

echo "===== the budget holds, and ends visibly ====="
new_instance; start_worker answer
entry_err() {
  printf '{"type":"assistant","uuid":"%s","isApiErrorMessage":true,"apiErrorStatus":529,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error: overloaded"}]}}\n' \
    "$(uuidgen)" >> "$TX"
}
printf '{"type":"user","uuid":"u-1","message":{"role":"user","content":"зроби це"}}\n' >> "$TX"
entry_err
acted=0
for i in 1 2 3 4 5 6; do
  make_still
  SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1 && acted=$((acted + 1))
  # Each nudge is answered by another API error with a brand-new uuid — the case that used to
  # reset a per-entry budget for ever. Drop the stand-in's own reply so no progress is seen.
  python3 - "$TX" <<'PY'
import json, sys
rows = [l for l in open(sys.argv[1]) if l.strip()]
keep = [l for l in rows if not ('"type": "assistant"' in l and '"claude-test"' in l)]
open(sys.argv[1], "w").write("".join(keep))
PY
  entry_err
done
[ "$acted" = 3 ] && ok "three recoveries, however many new errors they produced" \
  || bad "the budget allowed $acted recoveries"
[ "$(jq -r '.recovery // empty' "$IDIR/stalled.json" 2>/dev/null)" = hung ] \
  && ok "exhaustion is written where the app and the queue look, with its reason" \
  || bad "no visible verdict after the budget ran out"
hung_recovery_open "$IDIR" && bad "an exhausted episode still counts as in progress" \
  || ok "an exhausted episode no longer holds the stall watch back"

echo "===== a parked worker gets one more restart when the director writes ====="
park_undelivered "$IDIR" "директор пише знову" "MSG-9" >/dev/null 2>&1
SUPERVISOR_HUNG_TURN_SECS=600 hung_turn_check "$IDIR" "$SESSION" 0 RUN-1 \
  && ok "his message is the 'try again' — acted at once, without waiting out the stillness" \
  || bad "a parked worker stayed parked with the director's message waiting"
[ ! -e "$IDIR/stalled.json" ] && ok "the parked verdict is lifted while it tries" \
  || bad "stalled.json stayed up during the retry"
rm -f "$(undelivered_file "$IDIR")"

echo "===== a restart that always fails, and the same message waiting: it stays parked ====="
# The extra restart a message buys is bought once. Here the restart can never succeed — there is no
# launch line to start the worker again with — and the director's message sits undelivered. Read the
# queue as often as the watchdog likes: one extra attempt, then parked and visible, until he writes
# something genuinely new.
new_instance; start_worker freeze
INJECT_IDIR="$IDIR" inject_task "$SESSION" "Працюй за стандартами. Задача без виходу." >/dev/null
rm -f "$IDIR/relaunch-template"
jq -nc --argjson m "$(_transcript_size "$TX")" '{kind:"unanswered", entry:"x", mark:$m, attempts:3, exhausted:true}' \
  > "$(hung_file "$IDIR")"
jq -nc '{reason:"the worker froze", recovery:"hung"}' > "$IDIR/stalled.json"
WDLOG="$SUPERVISOR_STATE_DIR/watchdog.log"; : > "$WDLOG"
park_undelivered "$IDIR" "Продовжуй" "MSG-A" >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8; do
  make_still
  SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1 >/dev/null
done
[ "$(grep -c 'one more restart' "$WDLOG")" = 1 ] \
  && ok "eight looks at the same undelivered message bought exactly one extra restart" \
  || bad "the same message bought $(grep -c 'one more restart' "$WDLOG") extra restarts"
[ "$(jq -r '.exhausted' "$(hung_file "$IDIR")" 2>/dev/null)" = true ] \
  && [ "$(jq -r '.recovery // empty' "$IDIR/stalled.json" 2>/dev/null)" = hung ] \
  && ok "and the run is parked again, with the reason where the app shows it" \
  || bad "not parked after the extra attempt failed: $(cat "$(hung_file "$IDIR")" 2>/dev/null)"
# A watchdog that starts over reads the same files: nothing in memory to lose, nothing to reset.
make_still; SUPERVISOR_HUNG_TURN_SECS=1 bash -c '. "$1/supervisor-lib.sh"; hung_turn_check "$2" "$3" 99999 RUN-1' _ \
  "$BIN_DIR" "$IDIR" "$SESSION" >/dev/null
[ "$(grep -c 'one more restart' "$WDLOG")" = 1 ] && ok "a fresh process reading the same queue buys nothing either" \
  || bad "a restarted watchdog renewed the budget from the same message"
park_undelivered "$IDIR" "Ні, спробуй ще раз" "MSG-B" >/dev/null 2>&1
make_still; SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1 >/dev/null
[ "$(grep -c 'one more restart' "$WDLOG")" = 2 ] && ok "a genuinely new message gets its own extra restart" \
  || bad "a new message from the director was ignored by a parked run"
rm -f "$(undelivered_file "$IDIR")"

echo "===== through the real watchdog: parked, past the idle deadline, then 'continue' ====="
# The night's ending, replayed against watchdog.sh itself rather than against the function: the
# restarts have run out, the idle deadline passes — and the instance, with its task, must still be
# there when the director writes again. His message then gets one more restart and reaches the new
# worker; only once the worker is producing again may an idle pane be tidied away as before.
new_instance; start_worker freeze
INJECT_IDIR="$IDIR" inject_task "$SESSION" "Працюй за стандартами. Нічна задача." >/dev/null
save_relaunch_template "$IDIR" "python3 '$TMP/fake-claude.py' answer '$TX' '$TMP/bytes.log' '$IDIR' handshake; '$BIN_DIR/night-shift.sh' stop --generation @GENERATION@ '$PROJ'"
jq -nc --argjson m "$(_transcript_size "$TX")" '{kind:"unanswered", entry:"night", mark:$m, attempts:3, exhausted:true}' \
  > "$(hung_file "$IDIR")"
jq -nc '{reason:"the worker froze", recovery:"hung"}' > "$IDIR/stalled.json"
printf 'objective survives\n' > "$IDIR/objective-marker"
WDLOG="$SUPERVISOR_STATE_DIR/watchdog.log"; : > "$WDLOG"
SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_IDLE_KILL_SECS=3 SUPERVISOR_STALL_PARK_SECS=0 \
  SUPERVISOR_HUNG_TURN_SECS=1 bash "$BIN_DIR/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 9
[ -f "$IDIR/objective-marker" ] && tmux has-session -t "$SESSION" 2>/dev/null \
  && ok "past the idle deadline the parked instance and its session are still there" \
  || bad "the idle teardown deleted a parked frozen run and its task"
grep -q "full teardown" "$WDLOG" && bad "the watchdog logged a teardown of a parked run" \
  || ok "and the watchdog did not try to tear it down"
park_undelivered "$IDIR" "Продовжуй" "MSG-C" >/dev/null 2>&1
for i in $(seq 1 60); do
  jq -e 'select(.type == "user") | .message.content == "Продовжуй"' "$TX" >/dev/null 2>&1 && break
  sleep 1
done
jq -e 'select(.type == "user") | .message.content == "Продовжуй"' "$TX" >/dev/null 2>&1 \
  && ok "the director's 'continue' reached the restarted worker, through the watchdog" \
  || bad "'continue' never reached a worker (log: $(tail -3 "$WDLOG" | tr '\n' ' '))"
grep -q "one more restart" "$WDLOG" && ok "his message is what got it one more restart" \
  || bad "no restart was made for his message"
for i in $(seq 1 30); do grep -q "episode closed" "$WDLOG" && break; sleep 1; done
grep -q "episode closed" "$WDLOG" && ok "the answer closed the episode" || bad "the episode stayed open after the answer"
for i in $(seq 1 30); do [ -d "$IDIR" ] || break; sleep 1; done
[ ! -d "$IDIR" ] && awk '/episode closed/ {c=NR} /full teardown/ {t=NR} END {exit !(c && t && t > c)}' "$WDLOG" \
  && ok "the control: once nothing is kept, an idle pane is torn down exactly as before" \
  || bad "the ordinary idle teardown no longer happens (or happened before the episode closed)"
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null

echo "===== a question older than the worker binds nobody ====="
new_instance; start_worker answer
printf '{"type":"user","uuid":"u-old","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"старе питання"}}\n' >> "$TX"
: > "$IDIR/handshake-ok"
worker_owes_answer "$SESSION" "$IDIR" && bad "a question asked before this process started blocked delivery to it" \
  || ok "a restarted worker is not held to a question it never saw arrive"
printf '{"type":"user","uuid":"u-new","timestamp":"%s","message":{"role":"user","content":"нове питання"}}\n' \
  "$(date -u -v+1M '+%Y-%m-%dT%H:%M:%S.000Z')" >> "$TX"
worker_owes_answer "$SESSION" "$IDIR" && ok "one asked of this process still is" \
  || bad "a question this process was given was not seen as owed"

echo "===== what is never a hang ====="
not_a_hang() {   # $1=label, then a setup already applied
  make_still
  if SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1; then
    bad "$1 was treated as a frozen turn"
  else
    ok "$1 is left alone"
  fi
  rm -f "$(hung_file "$IDIR")"
}
new_instance; start_worker answer
printf '{"type":"user","uuid":"u-2","message":{"role":"user","content":"зроби"}}\n' >> "$TX"
: > "$IDIR/director-stopped";                not_a_hang "a turn the director stopped"; rm -f "$IDIR/director-stopped"
printf '{"type":"user","uuid":"u-3","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}\n' >> "$TX"
not_a_hang "an interruption"
printf '{"type":"assistant","uuid":"a-4","message":{"role":"assistant","model":"claude-test","content":[{"type":"tool_use","id":"t1","name":"Bash"},{"type":"tool_use","id":"t2","name":"Agent"}]}}\n' >> "$TX"
printf '{"type":"user","uuid":"u-4","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}\n' >> "$TX"
not_a_hang "a turn with a tool still out"
printf '{"type":"user","uuid":"u-5","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}\n' >> "$TX"
: > "$IDIR/paused-for-limit.json";           not_a_hang "a worker parked on a usage limit"; rm -f "$IDIR/paused-for-limit.json"
: > "$IDIR/ask-user.json";                   not_a_hang "a worker waiting on the director's answer"; rm -f "$IDIR/ask-user.json"
SUPERVISOR_CLAUDE_REACHABLE_CMD=/usr/bin/false not_a_hang "a worker with no route to the service"
# The control: with nothing holding it, this very turn IS a frozen one — so each "left alone" above
# was the exclusion's doing, not a turn that would never have qualified.
make_still
SUPERVISOR_HUNG_TURN_SECS=1 hung_turn_check "$IDIR" "$SESSION" 99999 RUN-1 \
  && ok "and with nothing holding it, the same turn is recovered" \
  || bad "the control turn was not recognised as frozen — the exclusions above prove nothing"
rm -f "$(hung_file "$IDIR")"
printf '{"type":"assistant","uuid":"a-6","isApiErrorMessage":true,"apiErrorStatus":400,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"bad request"}]}}\n' >> "$TX"
not_a_hang "a turn ended by a 4xx the retry cannot fix"

echo "===== stop honours generations ====="
new_instance; printf 'CURRENT\n' > "$IDIR/worker-generation"
"$BIN_DIR/night-shift.sh" stop --generation OLDER "$PROJ" >/dev/null 2>&1
[ -d "$IDIR" ] && ok "a replaced generation's stop is a no-op" || bad "a stale stop deleted the instance"
"$BIN_DIR/night-shift.sh" stop --generation CURRENT "$PROJ" >/dev/null 2>&1
[ ! -d "$IDIR" ] && ok "the current generation's stop still stops" || bad "the worker's own stop no longer works"

tmux kill-session -t "$SESSION" 2>/dev/null
echo
[ "$fails" -eq 0 ] && echo "PASS: test-hung-turn" || { echo "FAIL: test-hung-turn ($fails)"; exit 1; }
