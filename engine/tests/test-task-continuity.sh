#!/bin/bash
# "Commit, merge and cut a release" is not a new job.
#
# It used to be treated as one. Every message went through the full opening ceremony — classify,
# external research, design precedent, two long positions, an alignment — so a one-line follow-up
# to work already under way sat for twenty minutes under a header saying both engines were reading
# it, and looked for all the world as though the whole task had started again.
#
# What is pinned here is the rule that replaced the guesswork: a task is open until something ends
# it, a message accepted while one is open belongs to it, and that is decided AS THE MESSAGE IS
# ACCEPTED rather than when it finally reaches the front of the queue. Both engines still read
# every message — only the depth moves.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
export SUPERVISOR_CLAUDE_USAGE_CMD="/usr/bin/true" SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
. "$BIN/supervisor-lib.sh"
# What "the window is spent" means, in today's terms. It used to be written into these fixtures
# as 99%, back when the guard paused at 90; the guard is 100 now — quota is bought to be used —
# and 99% is an engine that is still working. Taking the number from the guard keeps every
# assertion below about what it was written to be about, under any configuration.
SPENT="${SUPERVISOR_USAGE_GUARD:-100}"


PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
: > "$PROJ/README.md"; git -C "$PROJ" add -A 2>/dev/null
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"
mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "night-$SLUG" > "$IDIR/session"
printf '%s\n' "RUN-T" > "$IDIR/run-id"
printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
: > "$IDIR/direct-chat"

BIG="Хочу довести експериментальний adaptive-peer до надійної моделі спільної роботи, спроектуй з нуля"
SMALL="закоміть, померджай і випусти версію"

echo "===== the first message of a conversation opens a task ====="
rel="$(thread_bind "$IDIR" "$BIG" "id-1" "00000001" | awk '{print $1}')"
[ "$rel" = new ] && ok "the first message opens one" || bad "the first message was called '$rel'"
tid1="$(thread_get "$IDIR" '.thread_id')"
[ -n "$tid1" ] && ok "and the task has an identity" || bad "no task id was recorded"

echo "===== a message arriving while it is open is its next step ====="
out="$(thread_bind "$IDIR" "$SMALL" "id-2" "00000002")"
[ "$(printf '%s' "$out" | awk '{print $1}')" = continue ] \
  && ok "a follow-up to open work continues it" || bad "the follow-up was called '$out'"
[ "$(printf '%s' "$out" | awk '{print $2}')" = "$tid1" ] \
  && ok "under the same task identity" || bad "the follow-up was given a different task id"
[ "$(printf '%s' "$out" | awk '{print $3}')" = 2 ] \
  && ok "and the revision moves on" || bad "the revision did not advance: $out"
[ "$(thread_get "$IDIR" '.objective')" = "$BIG" ] \
  && ok "the objective is still the task's, not the last thing typed" \
  || bad "the objective was overwritten by the follow-up"

echo "===== a declared result settles a task; it does not close the conversation ====="
thread_settle "$IDIR" succeeded_changes "DISPATCH-1"
[ "$(thread_state "$IDIR")" = settled ] && ok "a result settles it" || bad "a result did not settle it"
rel="$(thread_bind "$IDIR" "$SMALL" "id-3" "00000003" | awk '{print $1}')"
[ "$rel" = continue ] \
  && ok "and 'commit it and release' after a success is still the same task" \
  || bad "a release request after success was called '$rel' and would be researched from scratch"
thread_settle "$IDIR" succeeded_changes "DISPATCH-2"
rel="$(thread_bind "$IDIR" "Спроектуй з нуля нову фічу експорту звітів у PDF" "id-4" "00000004" | awk '{print $1}')"
[ "$rel" = new ] \
  && ok "…while genuinely new work after a result opens a new task" \
  || bad "a plainly new task was folded into the finished one ($rel)"
[ "$(thread_get "$IDIR" '.thread_id')" != "$tid1" ] \
  && ok "with an identity of its own" || bad "the new task reused the old identity"

echo "===== the boundary is decided when the message is ACCEPTED, not when it is prepared ====="
# The race: a second message is accepted while the task is open, then the worker declares a result
# before the pump gets to it. Judged at preparation time it would have become a new task and paid
# for a full research pass; judged at acceptance it is what it was.
rm -rf "$IDIR/thread" "$IDIR/pending"
thread_bind "$IDIR" "$BIG" "id-5" "00000005" >/dev/null
env2="$(pending_enqueue "$IDIR" "$SMALL" "id-6" adaptive-peer conversation)"
thread_settle "$IDIR" succeeded_changes "DISPATCH-3"
[ "$(jq -r '.relation' "$env2")" = continue ] \
  && ok "a result landing between acceptance and preparation does not re-label the message" \
  || bad "the message was re-labelled: $(jq -r '.relation' "$env2")"
[ -n "$(jq -r '.thread_id // empty' "$env2")" ] \
  && ok "and the envelope carries the task it belongs to" || bad "the envelope has no task id"

echo "===== an open task that nobody has spoken to in hours stops claiming new messages ====="
# "Open" is a claim about the director's attention, not only about the code. It stops being true
# after long enough — and runs now survive long usage pauses, so hours of silence are reachable in
# a way they were not before this change.
rm -rf "$IDIR/thread"
thread_bind "$IDIR" "$BIG" "id-old" "00000030" >/dev/null
jq --argjson t "$(( $(date +%s) - 30000 ))" '.last_message_at = $t' "$(thread_file "$IDIR")" > "$TMP/t"   && mv "$TMP/t" "$(thread_file "$IDIR")"
rel="$(thread_relation "$IDIR" "Спроектуй з нуля нову систему сповіщень")"
[ "$rel" = new ]   && ok "after a long silence a plainly new request opens its own task"   || bad "a day-old open task swallowed a new one ($rel)"
rel="$(thread_relation "$IDIR" "$SMALL")"
[ "$rel" = continue ]   && ok "…while a small follow-up still lands on the task it plainly belongs to"   || bad "the silence valve threw away an obvious follow-up ($rel)"
SUPERVISOR_TASK_IDLE_NEW_SECS=99999   bash -c '. "'"$BIN"'/supervisor-lib.sh"; thread_relation "'"$IDIR"'" "Спроектуй з нуля нову систему сповіщень"'   | grep -q continue   && ok "and the silence that counts is configurable, not baked in"   || bad "the idle window is not honoured"

echo "===== the worker may overrule the boundary ====="
thread_boundary "$IDIR" new "окрема робота: перенести звіти на новий рендерер"
[ "$(thread_get "$IDIR" '.objective')" = "окрема робота: перенести звіти на новий рендерер" ] \
  && ok "Claude can declare a new task boundary and everything downstream follows it" \
  || bad "the worker's boundary call was ignored"
thread_settle "$IDIR" needs_input "DISPATCH-4"
thread_boundary "$IDIR" continue
[ "$(thread_state "$IDIR")" = open ] \
  && ok "…and can put a task back on the table" || bad "the task stayed settled"

echo "===== a burst of messages: the third one is read WITH the second ====="
rm -rf "$IDIR/thread"
thread_bind "$IDIR" "$BIG" "id-a" "00000010" >/dev/null
thread_bind "$IDIR" "спершу онови changelog" "id-b" "00000011" >/dev/null
thread_bind "$IDIR" "ні, не changelog — README" "id-c" "00000012" >/dev/null
brief="$(thread_brief "$IDIR" "$PROJ" "ні, не changelog — README")"
case "$brief" in *"спершу онови changelog"*) ok "an undelivered predecessor is in the brief" ;;
  *) bad "the correction would be read without the thing it corrects" ;; esac
thread_delivered "$IDIR" "id-b"
brief="$(thread_brief "$IDIR" "$PROJ" "")"
case "$brief" in *"спершу онови changelog"*) bad "a delivered message is still queued in the brief" ;;
  *) ok "and drops out of it once the worker has been given it" ;; esac
case "$brief" in *"$BIG"*) ok "the brief leads with the task, not the last message" ;;
  *) bad "the brief lost the objective" ;; esac
case "$brief" in *"Стан реалізації"*) ok "and says where the tree stands now" ;;
  *) bad "the brief has no implementation state" ;; esac


echo "===== the brief speaks only of THIS task, and only of what is still owed ====="
# A Codex handed a withdrawn instruction as pending work is being actively misled, and one handed
# the previous task's messages is answering about the wrong job.
rm -rf "$IDIR/thread"
thread_bind "$IDIR" "$BIG" "id-p1" "00000040" >/dev/null
thread_bind "$IDIR" "прибери зайвий лог" "id-p2" "00000041" >/dev/null
thread_bind "$IDIR" "передумав — лог лиши" "id-p3" "00000042" >/dev/null
thread_cancelled "$IDIR" "id-p2"
brief="$(thread_brief "$IDIR" "$PROJ" "")"
case "$brief" in *"прибери зайвий лог"*) bad "a message the director took back is still listed as owed" ;;
  *) ok "a withdrawn message drops out of the brief" ;; esac
case "$brief" in *"передумав"*) ok "…and the one that replaced it stays" ;;
  *) bad "the replacement was lost with it" ;; esac
thread_settle "$IDIR" succeeded_changes "D-OLD"
thread_bind "$IDIR" "Спроектуй з нуля новий імпорт CSV" "id-q1" "00000043" >/dev/null
brief="$(thread_brief "$IDIR" "$PROJ" "")"
case "$brief" in *"передумав"*) bad "the new task's brief carries the old task's messages" ;;
  *) ok "a new task starts with a brief of its own" ;; esac


echo "===== taking a message back for real, through the tool the app uses ====="
# The pump and the delivery stage each clear their own copy when they happen to be the one that
# notices. A message pulled out of the queue is removed from under both of them — so the only
# place a withdrawal is GUARANTEED to pass through has to be the one that updates the record.
rm -rf "$IDIR/thread" "$IDIR/pending" "$IDIR/withdrawn" "$IDIR/cancelled"
thread_bind "$IDIR" "$BIG" "id-w0" "00000060" >/dev/null
MID="dddddddd-0000-0000-0000-00000000000d"
pending_enqueue "$IDIR" "видали таблицю users" "$MID" adaptive-peer conversation >/dev/null
verdict="$(cd "$PROJ" && bash "$BIN/worker-withdraw.sh" "$PROJ" "$MID" 2>/dev/null | tail -1)"
[ "$verdict" = withdrawn ] && ok "the real withdrawal path reports it was taken back" \
  || bad "worker-withdraw said: $verdict"
brief="$(thread_brief "$IDIR" "$PROJ" "")"
case "$brief" in *"видали таблицю users"*)
    bad "a retracted instruction is still handed to Codex as work the task still owes" ;;
  *) ok "and the next Codex brief no longer carries the retracted instruction" ;; esac

echo "===== two messages accepted at the same instant get different revisions ====="
rm -rf "$IDIR/thread" "$IDIR/pending"
thread_bind "$IDIR" "$BIG" "id-r0" "00000050" >/dev/null
( pending_enqueue "$IDIR" "перше уточнення" "id-r1" adaptive-peer conversation >/dev/null ) &
( pending_enqueue "$IDIR" "друге уточнення" "id-r2" adaptive-peer conversation >/dev/null ) &
wait
revs="$(for f in "$IDIR/pending"/[0-9]*.json; do jq -r '.revision' "$f" 2>/dev/null; done | sort -u | wc -l | tr -d ' ')"
[ "$revs" = 2 ] && ok "each gets its own revision instead of both writing the same one" \
  || bad "concurrent acceptance collided on one revision"
jq -e . "$(thread_file "$IDIR")" >/dev/null 2>&1 \
  && ok "and the task record is still valid JSON afterwards" \
  || bad "concurrent writes left the task record corrupt"
[ "$(jq -sr 'length' "$(thread_log "$IDIR")" 2>/dev/null)" = 3 ] \
  && ok "…with both messages recorded, neither overwritten" \
  || bad "a concurrent append was lost: $(jq -sr 'length' "$(thread_log "$IDIR")" 2>/dev/null) entries"
rm -rf "$IDIR/pending"


echo "===== the app is quit and reopened while a message is still in the queue ====="
# Quitting Bulava kills the pump; nothing else. The envelope, the task it was bound to and the
# relation it was given all live in the run's folder, and the watchdog starts a new pump when it
# next comes round. What must survive that is the BOUNDARY: a follow-up accepted before the
# restart must not come back as a brand new task afterwards, or closing the lid would quietly cost
# the director a full research pass.
rm -rf "$IDIR/thread" "$IDIR/pending"
thread_bind "$IDIR" "$BIG" "id-restart-0" "00000070" >/dev/null
env_before="$(pending_enqueue "$IDIR" "$SMALL" "id-restart-1" adaptive-peer conversation)"
[ "$(jq -r '.relation' "$env_before")" = continue ] \
  && ok "the queued follow-up is bound to the open task before the restart" \
  || bad "it was not a continuation even before the restart"
tid_before="$(jq -r '.thread_id' "$env_before")"

# The restart itself: everything in memory is gone, the folder is not.
#
# Nothing is killed by NAME here. This suite starts no pump of its own — it calls the library
# directly — so a `pkill -f message-pump.sh` had nothing of its own to hit and reached across into
# whichever sibling suite happened to be running one. The whole set runs side by side, so that is
# not untidiness, it is one test failing another; and it did, intermittently, in exactly the way
# that passes when run alone. Removing what a dead process leaves behind is the entire simulation.
rm -f "$(pipeline_active_file "$IDIR")" "$IDIR/queue-wait.json"
rm -rf "$IDIR/pump.lock" "$IDIR/pipeline.lock" "$IDIR/delivery.lock"

[ -s "$env_before" ] && ok "the envelope outlives the process that would have opened it" \
  || bad "the queued message was lost with the pump"
[ "$(jq -r '.relation' "$env_before")" = continue ] \
  && ok "…and still carries the boundary it was given when it was accepted" \
  || bad "the relation did not survive the restart"
[ "$(jq -r '.thread_id' "$env_before")" = "$tid_before" ] \
  && ok "…under the same task" || bad "the task identity changed across the restart"
[ "$(thread_state "$IDIR")" = open ] \
  && ok "and the task itself is still open on the other side" \
  || bad "the task was closed by the restart: $(thread_state "$IDIR")"

# A message accepted AFTER the restart lands on the same task too — the record is what decides,
# not anything the pump was holding.
out="$(thread_bind "$IDIR" "а тепер ще й теги" "id-restart-2" "00000071")"
[ "$(printf '%s' "$out" | awk '{print $1}')" = continue ] \
  && ok "a message sent after reopening continues the same task" \
  || bad "reopening the app started a new task: $out"
[ "$(printf '%s' "$out" | awk '{print $2}')" = "$tid_before" ] \
  && ok "…under the identity it had before the restart" || bad "a new identity was issued"
brief="$(thread_brief "$IDIR" "$PROJ" "")"
case "$brief" in *"$SMALL"*) ok "and the brief still owes the message the restart interrupted" ;;
  *) bad "the message queued before the restart dropped out of the brief" ;; esac
rm -rf "$IDIR/pending"

echo "===== a follow-up is prepared cheaply, and BOTH engines still read it ====="
mkdir -p "$TMP/stub"
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
prompt=""; for a in "$@"; do prompt="$a"; done
printf '%s' "$prompt" >> "$REC/claude.prompts"
echo "READING — наступний крок; RISK — реліз незворотний; WHAT IS NOT DONE YET — нічого; PROOF — git log"
STUB
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; prev=""; prompt=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prompt="$a"; prev="$a"; done
printf '%s\n---\n' "$*" >> "$REC/codex.argv"
printf '%s' "$prompt" >> "$REC/codex.prompts"
answer='READING — наступний крок поточної задачі
RISK — реліз незворотний
WHAT IS NOT DONE YET — нічого
PROOF — git log'
[ -n "$out" ] && printf '%s\n' "$answer" > "$out"
printf '%s\n' "$answer"
STUB
chmod +x "$TMP/stub/claude" "$TMP/stub/codex"
export REC="$TMP/rec"; mkdir -p "$REC"

rm -rf "$IDIR/thread" "$IDIR/messages"
printf '# Research — earlier\n- a verified fact\n' > "$IDIR/research.md"
printf 'AGREED CORE — do the thing\n' > "$IDIR/peer-alignment.md"
thread_bind "$IDIR" "$BIG" "id-x" "00000020" >/dev/null
thread_bind "$IDIR" "$SMALL" "id-y" "00000021" >/dev/null
ART="$IDIR/messages/followup"; mkdir -p "$ART"
PATH="$TMP/stub:$PATH" PIPE_RELATION=continue SUPERVISOR_DESIGN_RESEARCH=1 \
  bash "$BIN/preflight.sh" --art "$ART" --stage context "$PROJ" "$SMALL" >/dev/null 2>&1
[ "$(tr -d '[:space:]' < "$ART/.scale")" = followup ] \
  && ok "the stage knows it is a follow-up" || bad "the follow-up ran the full context stage"
[ ! -s "$REC/codex.argv" ] \
  && ok "no external research, no design research, no classification call was made" \
  || bad "a follow-up still paid for model calls in the context stage: $(head -c 200 "$REC/codex.argv")"
[ -s "$ART/research.md" ] \
  && ok "the research the task already paid for is carried forward, not re-run" \
  || bad "the follow-up lost the task's research"
grep -q "ПОТОЧНА ЗАДАЧА" "$ART/peer-prompt.txt" 2>/dev/null \
  && ok "and both engines are handed the task's current state" \
  || bad "the follow-up prompt has no task context"
grep -q "$SMALL" "$ART/peer-prompt.txt" 2>/dev/null \
  && ok "together with what was actually asked" || bad "the follow-up prompt lost the message"

PATH="$TMP/stub:$PATH" bash "$BIN/preflight.sh" --art "$ART" --stage peer --engine claude "$PROJ" "$SMALL" >/dev/null 2>&1
PATH="$TMP/stub:$PATH" bash "$BIN/preflight.sh" --art "$ART" --stage peer --engine codex "$PROJ" "$SMALL" >/dev/null 2>&1
[ -s "$ART/peer-claude.md" ] && [ -s "$ART/peer-codex.md" ] \
  && ok "a cheap follow-up is still read independently by BOTH engines" \
  || bad "participation was traded away for speed — the one thing that must not happen"

echo "===== one engine out degrades honestly instead of stopping ====="
jq -n --arg spent "$SPENT" --argjson ts "$(date +%s)" \
  '{ts:$ts, observed_at:$ts, source:"cli",
    five_hour:{used_percentage:($spent|tonumber), resets_at:($ts + 3600), window_minutes:300},
    seven_day:{used_percentage:5, resets_at:($ts + 500000), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/codex-usage.json"
ART2="$IDIR/messages/degraded"; mkdir -p "$ART2"
PATH="$TMP/stub:$PATH" PIPE_RELATION=continue \
  bash "$BIN/preflight.sh" --art "$ART2" --stage context "$PROJ" "$SMALL" >/dev/null 2>&1
PATH="$TMP/stub:$PATH" bash "$BIN/preflight.sh" --art "$ART2" --stage peer --engine claude "$PROJ" "$SMALL" >/dev/null 2>&1
before="$(wc -c < "$REC/codex.prompts" 2>/dev/null || echo 0)"
PATH="$TMP/stub:$PATH" bash "$BIN/preflight.sh" --art "$ART2" --stage peer --engine codex "$PROJ" "$SMALL" >/dev/null 2>&1
after="$(wc -c < "$REC/codex.prompts" 2>/dev/null || echo 0)"
[ "$before" = "$after" ] \
  && ok "an engine with no window left is not called at all" \
  || bad "the whole budget was spent waiting for an engine known to be out"
[ -s "$ART2/peer-codex.unavailable" ] && ok "…and its absence is written down" \
  || bad "the missing engine left no trace"
PATH="$TMP/stub:$PATH" bash "$BIN/preflight.sh" --art "$ART2" --stage align "$PROJ" "$SMALL" >/dev/null 2>&1
[ -s "$ART2/degraded.md" ] && ok "the degradation is recorded as a fact of the run" \
  || bad "the run degraded silently"
[ -s "$ART2/plan.md" ] && ok "and the surviving position still becomes the working brief" \
  || bad "one engine being out lost the other one's work too"

prompt="$(compose_task_prompt "$IDIR" "$SMALL" "$ART2")"
case "$prompt" in *"ДЕГРАДОВАНИЙ РЕЖИМ"*) ok "the worker is told which engine is missing" ;;
  *) bad "the worker was not told it is working alone" ;; esac
case "$prompt" in *"ПРОДОВЖЕННЯ"*) ok "…and that this is the next step, not a fresh start" ;;
  *) bad "a follow-up was handed over as though the task were beginning" ;; esac
case "$prompt" in *"task-boundary"*) ok "…with a way to say the engine has the boundary wrong" ;;
  *) bad "the worker cannot correct the task boundary" ;; esac

echo
[ "$fails" = 0 ] && { echo "✅ task continuity: all $pass passed"; exit 0; }
echo "❌ task continuity: $fails failure(s)"; exit 1
