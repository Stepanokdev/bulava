#!/bin/bash
# A usage limit is a thing that ENDS, and the engine has to notice.
#
# The incident this pins down: Codex hit its guard while reviewing, a `paused-for-limit` marker was
# written with a reset time, and then the limit really did reset — and nothing happened. A new
# message lay untouched in the queue for over an hour. Three separate faults, all of them here:
#
#   the marker did not say WHOSE limit it was, so a Codex window stopped a perfectly free Claude;
#   the watchdog waited it out with one long `sleep`, which counts only waking seconds, so a Mac
#     that slept through the reset woke with the deadline long past and kept waiting;
#   nothing checked the meter again, and nothing checked that the pause still belonged to the work
#     being done — so the resume, when it finally came, could land in a different task.
#
# Model calls are stubbed. Clocks, markers, queues and the pump are real.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"
cleanup() { tmux_cleanup 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0; fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
mkdir -p "$TMP/tmux"; tmux_isolate "$TMP/tmux"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
. "$BIN/supervisor-lib.sh"

PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
: > "$PROJ/README.md"; git -C "$PROJ" add -A 2>/dev/null
git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"
mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
printf '%s\n' "$SESSION" > "$IDIR/session"
printf '%s\n' "RUN-A" > "$IDIR/run-id"
printf '%s\n' "main" > "$IDIR/branch"
: > "$IDIR/started-at"; : > "$IDIR/direct-chat"

now() { date +%s; }
usage() {   # $1=claude|codex  $2=five-hour %  $3=resets_at  [$4=weekly %]
  local f; case "$1" in codex) f="$SUPERVISOR_STATE_DIR/codex-usage.json" ;; *) f="$SUPERVISOR_STATE_DIR/usage.json" ;; esac
  jq -n --argjson u "$2" --argjson r "$3" --argjson w "${4:-3}" --argjson ts "$(now)" \
    '{ts:$ts, observed_at:$ts, source:"cli",
      five_hour:{used_percentage:$u, resets_at:$r, window_minutes:300},
      seven_day:{used_percentage:$w, resets_at:($ts + 500000), window_minutes:10080}}' > "$f"
}
no_usage() { rm -f "$SUPERVISOR_STATE_DIR/usage.json" "$SUPERVISOR_STATE_DIR/codex-usage.json"; }
# Nothing in this suite may go and ask a real CLI what its limits are.
export SUPERVISOR_CLAUDE_USAGE_CMD="/usr/bin/true" SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"

echo "===== a week is not a five-hour window ====="
# The director's screenshot: Codex session 25% used, week 91%, five days to the weekly reset — and
# the app answering alone because "Codex is out of window". One guard was applied to both windows,
# and ten per cent of a week is most of a day, so 91% switched Codex off entirely for five days.
usage codex 25 "$(( $(now) + 14400 ))" 91
[ "$(provider_state codex | awk '{print $1}')" = available ] \
  && ok "91% of the week with three quarters of the session free is not out of window" \
  || bad "Codex is still called exhausted at 91% weekly: $(provider_state codex)"

usage codex 25 "$(( $(now) + 14400 ))" 98
[ "$(provider_state codex | awk '{print $1}')" = available ] \
  && ok "…and neither is 98%: the quota is used to the end, not to a margin" \
  || bad "something is still holding a reserve back: $(provider_state codex)"

usage codex 25 "$(( $(now) + 14400 ))" 100
[ "$(provider_state codex | awk '{print $1}')" = exhausted ] \
  && ok "a week that is actually spent still stops the work" \
  || bad "a spent week was not noticed: $(provider_state codex)"

usage codex 100 "$(( $(now) + 14400 ))" 40
[ "$(provider_state codex | awk '{print $1}')" = exhausted ] \
  && ok "and so does a five-hour window that is actually spent" \
  || bad "a spent session was not noticed: $(provider_state codex)"

# And the sentence a person reads about it has to say WHICH DAY. A weekly reset five days out was
# printed as a bare clock time, so it read as six minutes away.
far="$(( $(now) + 5 * 86400 ))"
case "$(when_human "$far")" in
  *"$(date -r "$far" '+%d.%m')"*) ok "a reset five days out names the date" ;;
  *) bad "five days away still reads as a time today: $(when_human "$far")" ;;
esac
case "$(when_human "$(( $(now) + 3600 ))")" in
  *сьогодні*) ok "and one an hour away says today" ;;
  *) bad "an hour away is not shown as today: $(when_human "$(( $(now) + 3600 ))")" ;;
esac

echo "===== whose limit it is decides who has to stop ====="
usage claude 4 "$(( $(now) + 9000 ))"
usage codex 99 "$(( $(now) + 9000 ))"
pause_record "$IDIR" codex "$(( $(now) + 9000 ))" "codex usage guard"
pause_blocks_worker "$IDIR" \
  && bad "a Codex window stopped Claude — the bug this suite exists for" \
  || ok "Codex being out does not make Claude busy"
[ "$(pause_provider "$IDIR")" = codex ] && ok "the marker says whose limit it is" \
  || bad "the marker does not name the engine"

usage claude 99 "$(( $(now) + 9000 ))"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
pause_blocks_worker "$IDIR" && ok "Claude's own limit does stop preparation" \
  || bad "an exhausted Claude was treated as free"

echo "===== the meter outranks the marker ====="
usage claude 5 "$(( $(now) + 9000 ))"          # it reset early
v="$(pause_reconcile "$IDIR")"
[ "$v" = cleared-fresh ] && ok "an early reset lifts the pause on the next check ($v)" \
  || bad "a window that reset early kept the run parked ($v)"
[ -e "$(pause_file "$IDIR")" ] && bad "the marker outlived the limit" || ok "and the marker is gone"

echo "===== a deadline that has passed is not a reason to wait for ever ====="
no_usage
pause_record "$IDIR" claude 0 "usage guard"
jq '.resume_after = 1' "$(pause_file "$IDIR")" > "$TMP/m" && mv "$TMP/m" "$(pause_file "$IDIR")"
v="$(pause_reconcile "$IDIR")"
[ "$v" = attempt ] && ok "an expired marker with no readable meter earns one controlled attempt" \
  || bad "expected a controlled attempt, got: $v"

echo "===== …and a blind attempt that fails backs off instead of spinning ====="
pause_record "$IDIR" claude 0 "usage limit seen in the worker pane"
after="$(jq -r '.resume_after' "$(pause_file "$IDIR")")"
[ "$(( after - $(now) ))" -ge 590 ] \
  && ok "the next attempt is at least the backoff away ($(( after - $(now) ))s)" \
  || bad "a failed attempt would be repeated at once ($(( after - $(now) ))s)"
v="$(pause_reconcile "$IDIR")"
[ "$v" = holds ] && ok "and until then it holds" || bad "the backoff was ignored ($v)"

echo "===== a lifted pause leaves the work owed a resume, whoever noticed it ====="
# The pump reconciles too, because it has to know whether preparing a message is pointless. When
# the pump is the one that removes the marker, the work that pause had stopped used to be owed a
# resume that nobody remembered — and if the message was then taken back, the run sat at an idle
# prompt for good.
rm -f "$IDIR/resume-pending" "$(pause_last_file "$IDIR")" "$IDIR/dispatch.json"
usage claude 99 "$(( $(now) + 9000 ))"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
usage claude 4 "$(( $(now) + 9000 ))"
pause_blocks_worker "$IDIR" && bad "the pump still saw the worker as parked"   || ok "the pump sees the limit is gone"
[ -e "$IDIR/resume-pending" ]   && ok "…and the resume the work was owed is written down, not lost with the marker"   || bad "the resume event vanished with the marker the pump removed"
rm -f "$IDIR/resume-pending"
pause_record "$IDIR" codex "$(( $(now) + 9000 ))" "codex usage guard"
usage codex 4 "$(( $(now) + 9000 ))"
pause_reconcile "$IDIR" >/dev/null
[ -e "$IDIR/resume-pending" ]   && bad "Codex coming back left a nudge owed to Claude, who was never stopped"   || ok "a Codex window coming back owes Claude nothing"
rm -f "$IDIR/resume-pending"
printf '%s
' "RUN-OTHER" > "$IDIR/run-id"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
printf '%s
' "RUN-A" > "$IDIR/run-id"
pause_reconcile "$IDIR" >/dev/null
[ -e "$IDIR/resume-pending" ]   && bad "a pause from finished work still asked for a resume"   || ok "and a pause from work that is over owes nothing at all"
rm -f "$IDIR/resume-pending"

echo "===== an exhaustion whose own reset has passed stops being a fact ====="
# Left unchecked this deadlocks: the marker re-arms itself half an hour at a time from a reset that
# already happened, so the controlled attempt that should break it is never reachable.
usage claude 99 "$(( $(now) - 600 ))"
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"
[ "${s%% *}" = unknown ]   && ok "a stale 'out of window' whose reset has passed is no longer believed"   || bad "an expired exhaustion was treated as current ($s) — the run would park for ever"
usage claude 99 "$(( $(now) + 9000 ))"
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"
[ "${s%% *}" = exhausted ]   && ok "…while one whose reset is still ahead is"   || bad "a still-valid exhaustion was thrown away ($s)"
rm -f "$(pause_last_file "$IDIR")" "$IDIR/resume-pending"
usage claude 99 "$(( $(now) - 600 ))"
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$SUPERVISOR_STATE_DIR/usage.json"
pause_record "$IDIR" claude "$(( $(now) - 300 ))" "usage guard"
jq '.resume_after = 1' "$(pause_file "$IDIR")" > "$TMP/m" && mv "$TMP/m" "$(pause_file "$IDIR")"
v="$(pause_reconcile "$IDIR")"
[ "$v" = attempt ]   && ok "and the deadlock breaks into a controlled attempt instead of re-arming for ever"   || bad "the pause re-armed itself from a reset that had already passed ($v)"

echo "===== only one process can hold the composer ====="
rm -rf "$IDIR/delivery.lock"
delivery_claim "$IDIR" one && ok "the first caller takes it" || bad "nobody could take a free lock"
delivery_claim "$IDIR" two && bad "two processes both hold the composer"   || ok "the second is refused while it is held"
delivery_release "$IDIR"
delivery_claim "$IDIR" three && ok "and it is free again once released" || bad "the lock leaked"
delivery_release "$IDIR"
# A lock directory with no pid in it yet is NOT an abandoned lock: its owner may be a microsecond
# from writing one. Breaking in on that is how two processes both came away believing they held it.
mkdir -p "$IDIR/delivery.lock"
delivery_claim "$IDIR" latecomer   && bad "a lock still being taken was stolen from its owner"   || ok "a lock with no pid yet is left alone during its grace"
SUPERVISOR_DELIVERY_CLAIM_GRACE=0 delivery_claim "$IDIR" reclaimer   && ok "…and reclaimed once it is plainly abandoned" || bad "an abandoned lock was never reclaimed"
delivery_release "$IDIR"
rm -rf "$IDIR/delivery.lock"


# TWO rescuers arriving at the same dead lock. Remove-then-recreate loses this: both delete, both
# create, and the second throws away a lock the first had already filled in.
rm -rf "$IDIR/delivery.lock" "$IDIR/delivery.lock.rescue"
mkdir -p "$IDIR/delivery.lock"; printf '%s\n' 999999 > "$IDIR/delivery.lock/pid"
cat > "$TMP/rescue.sh" <<'RESCUE'
#!/bin/bash
. "$BIN/supervisor-lib.sh"
if delivery_claim "$IDIR" "rescuer-$1"; then printf '%s\n' "$1" >> "$TMP/rescued"; fi
sleep 1
RESCUE
chmod +x "$TMP/rescue.sh"
: > "$TMP/rescued"
BIN="$BIN" IDIR="$IDIR" TMP="$TMP" SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" bash "$TMP/rescue.sh" A &
r1=$!
BIN="$BIN" IDIR="$IDIR" TMP="$TMP" SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" bash "$TMP/rescue.sh" B &
r2=$!
wait "$r1" 2>/dev/null; wait "$r2" 2>/dev/null
n="$(wc -l < "$TMP/rescued" | tr -d ' ')"
[ "$n" = 1 ] \
  && ok "two rescuers at one dead lock: exactly one comes away holding the composer" \
  || bad "$n processes all believe they hold the composer"
rm -rf "$IDIR/delivery.lock" "$IDIR/delivery.lock.rescue"

echo "===== a reading is as old as the OBSERVATION, not as the file ====="
# The session fallback scrapes a number out of a log line written hours ago and writes it down now.
# Judging by the file's own timestamp calls that measurement current.
jq -n --argjson ts "$(now)" --argjson old "$(( $(now) - 7200 ))" \
  '{ts:$ts, observed_at:$old, source:"session",
    five_hour:{used_percentage:99, resets_at:($ts - 600), window_minutes:300},
    seven_day:{used_percentage:5, resets_at:($ts + 500000), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"
[ "${s%% *}" = unknown ] \
  && ok "a young FILE holding a two-hour-old exhaustion with a passed reset is not believed" \
  || bad "a stale observation in a fresh file kept the pause alive for ever ($s)"

echo "===== a pause does not spend the run's own budget ====="
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending"
usage claude 99 "$(( $(now) + 60 ))"
: > "$IDIR/started-at"
before="$(stat -f %m "$IDIR/started-at")"
pause_record "$IDIR" claude "$(( $(now) + 60 ))" "usage guard"
jq --argjson r "$(( $(now) - 3600 ))" '.recorded_at = $r' "$(pause_file "$IDIR")" > "$TMP/m" \
  && mv "$TMP/m" "$(pause_file "$IDIR")"
usage claude 4 "$(( $(now) + 9000 ))"
pause_reconcile "$IDIR" >/dev/null
after="$(stat -f %m "$IDIR/started-at")"
[ "$(( after - before ))" -ge 3500 ] \
  && ok "an hour parked on a window gives the run an hour back ($(( after - before ))s)" \
  || bad "the wait counted against the run's budget, so a long pause eats the final review"

echo "===== a delivery that has already answered the pause leaves no nudge behind ====="
rm -f "$IDIR/resume-pending" "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")"
usage claude 99 "$(( $(now) + 9000 ))"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
usage claude 4 "$(( $(now) + 9000 ))"
jq -nc --argjson pid "$$" '{pid:$pid, session:"x"}' > "$(delivering_file "$IDIR")"
pause_reconcile "$IDIR" >/dev/null
rm -f "$(delivering_file "$IDIR")"
[ -e "$IDIR/resume-pending" ] \
  && bad "a nudge was queued behind a handover already in progress" \
  || ok "nothing is owed while the director's own words are already being handed over"

echo "===== an unknown meter is never read as 'free' ====="
no_usage
s="$(provider_state claude)"; [ "${s%% *}" = unknown ] && ok "no reading at all is unknown" \
  || bad "a missing reading was called '$s'"
printf '{"unknown":true,"reason":"x"}' > "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"; [ "${s%% *}" = unknown ] && ok "an explicitly unknown reading is unknown" \
  || bad "an unknown reading was called '$s'"
usage claude 4 "$(( $(now) + 900 ))"
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"; [ "${s%% *}" = unknown ] \
  && ok "a two-hour-old 'plenty left' is not current enough to prove availability" \
  || bad "a stale file confirmed availability: $s"
usage claude 4 "$(( $(now) + 900 ))"
jq --argjson o "$(( $(now) - 7200 ))" '.observed_at = $o' "$SUPERVISOR_STATE_DIR/usage.json" > "$TMP/u" \
  && mv "$TMP/u" "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"; [ "${s%% *}" = unknown ] \
  && ok "a fresh FILE with an old observation inside it is still unknown" \
  || bad "an old observation passed as current: $s"
usage claude 4 "$(( $(now) + 900 ))" 100
s="$(provider_state claude)"; [ "${s%% *}" = exhausted ] \
  && ok "a spent weekly window is exhaustion even when the five-hour one is empty" \
  || bad "weekly exhaustion was missed: $s"
# …and exhaustion is the claim that ages safely: it can only get better with time, never worse.
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$SUPERVISOR_STATE_DIR/usage.json"
s="$(provider_state claude)"; [ "${s%% *}" = exhausted ] \
  && ok "an old reading may still say 'out', because that only improves" \
  || bad "stale exhaustion was thrown away: $s"

echo "===== an unknown meter does not stop the engine being ASKED ====="
no_usage
provider_exhausted codex && bad "an unreadable meter refused the call" \
  || ok "with no reading at all, the call is still attempted"
provider_available codex && bad "an unreadable meter claimed availability" \
  || ok "…and it is still not called 'available'"

echo "===== a pause left by work that is over resumes nothing ====="
rm -f "$IDIR/last-resume" "$(pause_last_file "$IDIR")"
usage claude 99 "$(( $(now) + 9000 ))"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
printf '%s\n' "RUN-B" > "$IDIR/run-id"
v="$(pause_reconcile "$IDIR")"
[ "$v" = cleared-foreign-run ] && ok "a marker from a run that is gone is dropped ($v)" \
  || bad "a foreign run's pause was acted on ($v)"
printf '%s\n' "RUN-A" > "$IDIR/run-id"
jq -nc '{id:"DISPATCH-1"}' > "$IDIR/dispatch.json"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
jq -nc '{id:"DISPATCH-2"}' > "$IDIR/dispatch.json"
v="$(pause_reconcile "$IDIR")"
[ "$v" = cleared-foreign-work ] && ok "and so is one from work that has been superseded ($v)" \
  || bad "a superseded dispatch's pause was acted on ($v)"


echo "===== work detached from a run that no longer exists stops ====="
# The pump is detached on purpose: closing Bulava must not interrupt a preparation already under
# way. Detached is not immortal, though, and it was — one was found still spinning forty minutes
# after its run had been torn down, inside pipeline.sh, waiting out a one-hour lock in a directory
# that no longer existed. The cheap half of that is a process nobody wanted; the expensive half is
# winning the lock and then spending a model window preparing a message for work that is over.
gone="$TMP/gone-instance"
mkdir -p "$gone"
printf '%s\n' "$PROJ" > "$gone/project"
printf '%s\n' "RUN-GONE" > "$gone/run-id"
mkdir -p "$(pipeline_lock_dir "$gone")"
printf '%s\n' "$$" > "$(pipeline_lock_dir "$gone")/pid"     # held by this very much alive process
( pipeline_lock_acquire "$gone" "orphan" 3600 ) & LK=$!
sleep 1
kill -0 "$LK" 2>/dev/null && ok "it queues for the lock while the run is still there" \
  || bad "it gave up while the run was still there"
rm -rf "$gone"                                              # the run is torn down under it
tries=0
while kill -0 "$LK" 2>/dev/null && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
if kill -0 "$LK" 2>/dev/null; then
  bad "it kept waiting for a lock inside a run that had been deleted"
  kill "$LK" 2>/dev/null
else
  ok "…and stops as soon as the run it belongs to is gone"
fi
wait "$LK" 2>/dev/null

echo "===== markers whose owner has gone do not hold the queue ====="
jq -nc --argjson pid 999999 '{pid:$pid, at:1}' > "$IDIR/review-active"
review_active_live "$IDIR" && bad "a review with a dead reviewer still counted as running" \
  || ok "a review whose reviewer died is cleared"
[ -e "$IDIR/review-active" ] && bad "the orphan marker was left behind" || ok "…and the marker with it"
jq -nc --argjson pid "$$" '{pid:$pid, at:1}' > "$IDIR/review-active"
review_active_live "$IDIR" && ok "a review that IS running still counts" || bad "a live review was cleared"
rm -f "$IDIR/review-active"
jq -nc --argjson at "$(( $(now) - 10 ))" '{await_until:$at, reason:"x"}' > "$IDIR/awaiting-codex"
awaiting_codex_live "$IDIR" && bad "an expired consultation marker still blocked" \
  || ok "an expired consultation marker is cleared"
jq -nc --arg r "RUN-OLD" --argjson at "$(( $(now) + 9000 ))" '{run_id:$r, await_until:$at}' > "$IDIR/awaiting-codex"
awaiting_codex_live "$IDIR" && bad "another run's consultation blocked this one" \
  || ok "a consultation belonging to another run is cleared"


echo "===== a marker replaced WHILE we were asking the meter is not the one we decided about ====="
# Reading the owner takes no time; deciding takes seconds, because the meter is re-read over the
# network in between. New work can record its own pause inside that gap — and a drop based on the
# old reading would delete the NEW pause, unparking a run that had just been parked for a reason.
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending"
no_usage
cat > "$TMP/slow-usage.sh" <<'SLOW'
#!/bin/bash
sleep 2
jq -n --argjson ts "$(date +%s)" \
  '{ts:$ts, observed_at:$ts, source:"cli",
    five_hour:{used_percentage:4, resets_at:($ts + 9000), window_minutes:300},
    seven_day:{used_percentage:3, resets_at:($ts + 500000), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/usage.json"
SLOW
chmod +x "$TMP/slow-usage.sh"
jq -nc '{id:"DISPATCH-FIRST"}' > "$IDIR/dispatch.json"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "first pause"
( SUPERVISOR_CLAUDE_USAGE_CMD="$TMP/slow-usage.sh" pause_reconcile "$IDIR" > "$TMP/verdict" ) &
RC=$!
sleep 1
# A different piece of work parks the run while that reconciliation is still in flight.
jq -nc '{id:"DISPATCH-SECOND"}' > "$IDIR/dispatch.json"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "second pause, different work"
wait "$RC" 2>/dev/null
[ -s "$(pause_file "$IDIR")" ] \
  && ok "the pause recorded by the newer work survives a reconciliation that started before it" \
  || bad "a stale decision deleted a pause that had just been recorded"
[ "$(jq -r '.reason' "$(pause_file "$IDIR")" 2>/dev/null)" = "second pause, different work" ] \
  && ok "…and it is still the NEW marker, untouched" \
  || bad "the new marker was overwritten by the old decision"
[ "$(cat "$TMP/verdict" 2>/dev/null)" = holds ] \
  && ok "…and the stale reconciliation reports that the pause stands" \
  || bad "the stale reconciliation claimed the pause was lifted: $(cat "$TMP/verdict" 2>/dev/null)"
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending" "$IDIR/dispatch.json"



# The work changing hands DURING the meter read, without anyone touching the marker.
#
# This is the quiet version of the same fault. The marker is untouched, so the fingerprint check
# passes; the ownership check at the top of reconciliation was true when it ran; and the note that
# comes out the far side used to take its run and dispatch from the instance AS IT IS NOW — which
# is the new task. The watchdog then compared that note against the current dispatch, agreed with
# itself, and typed a resume owed to finished work into whatever had replaced it.
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending"
rm -rf "$IDIR/pause.lock"
no_usage
jq -nc '{id:"DISPATCH-DURING-A"}' > "$IDIR/dispatch.json"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "pause owned by A"
( SUPERVISOR_CLAUDE_USAGE_CMD="$TMP/slow-usage.sh" pause_reconcile "$IDIR" > "$TMP/verdict-b" ) &
RC=$!
sleep 1
# Only the dispatch moves on. No pause_record, no marker edit — nothing the fingerprint can see.
jq -nc '{id:"DISPATCH-DURING-B"}' > "$IDIR/dispatch.json"
wait "$RC" 2>/dev/null
if [ -e "$IDIR/resume-pending" ]; then
  note_did="$(jq -r '.dispatch_id // empty' "$IDIR/resume-pending" 2>/dev/null)"
  [ "$note_did" = "DISPATCH-DURING-B" ] \
    && bad "a resume owed to finished work was stamped with the NEW task and would be typed into it" \
    || ok "a resume note never claims the work that replaced the one it was owed to"
else
  ok "no resume is owed at all once the work it belonged to has been replaced"
fi
[ "$(cat "$TMP/verdict-b" 2>/dev/null)" = cleared-foreign-work ] \
  && ok "…and reconciliation says plainly that the work was superseded" \
  || bad "reconciliation reported: $(cat "$TMP/verdict-b" 2>/dev/null)"
# Prove it end to end: the watchdog must type nothing. It needs a pane to type INTO, or this
# asserts only that a watchdog with no session does nothing — which is true of every bug too.
tmux new-session -d -s "$SESSION" 'while :; do sleep 1; done' 2>/dev/null
tmux has-session -t "$SESSION" 2>/dev/null \
  || { echo "⚠️  tmux не піднявся — пропускаю наскрізну частину"; }
rm -f "$IDIR/last-resume" "$IDIR/resume-attempts" "$IDIR/stalled.json" "$IDIR/resume-refused"
export SUPERVISOR_RESUME_CONFIRM_WAIT=1 SUPERVISOR_WATCHDOG_POLL=1 \
       SUPERVISOR_IDLE_KILL_SECS=0 SUPERVISOR_STALL_PARK_SECS=0
usage claude 4 "$(( $(now) + 9000 ))"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 3
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
if tmux has-session -t "$SESSION" 2>/dev/null; then
  [ -e "$IDIR/last-resume" ] \
    && bad "the watchdog typed the stale resume into the new task after all" \
    || ok "…and the watchdog types nothing into the task that replaced it"
fi
unset SUPERVISOR_RESUME_CONFIRM_WAIT
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending" \
      "$IDIR/dispatch.json" "$IDIR/last-resume" "$IDIR/stalled.json"

# …and replaced at ANY point in the window, not only while the meter is being read. Between the
# fingerprint check and the removal there is still a jq, two file writes and a clock read, and a
# pause recorded inside THAT window was deleted just the same. The property has to hold whichever
# side of the check the writer lands on: a pause recorded by new work is never lost.
#
# Hammered rather than aimed, because the window is microseconds wide and there is no honest way
# to stand in the middle of it from outside.
cat > "$TMP/quick-usage.sh" <<'QUICK'
#!/bin/bash
jq -n --argjson ts "$(date +%s)" \
  '{ts:$ts, observed_at:$ts, source:"cli",
    five_hour:{used_percentage:4, resets_at:($ts + 9000), window_minutes:300},
    seven_day:{used_percentage:3, resets_at:($ts + 500000), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/usage.json"
QUICK
chmod +x "$TMP/quick-usage.sh"
lost=0
i=0
while [ "$i" -lt 25 ]; do
  i=$((i + 1))
  rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending" \
        "$SUPERVISOR_STATE_DIR/usage.json"
  pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "the pause being reconciled"
  ( SUPERVISOR_CLAUDE_USAGE_CMD="$TMP/quick-usage.sh" pause_reconcile "$IDIR" >/dev/null ) &
  A=$!
  ( sleep "0.0$(( i % 10 ))"
    pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "a pause recorded by newer work" ) &
  B=$!
  wait "$A" 2>/dev/null; wait "$B" 2>/dev/null
  # The writer either landed before the drop took the lock (mismatch, refused) or after it let go
  # (dropped, then written). Both end with the newer pause standing; neither may end with nothing.
  [ "$(jq -r '.reason // empty' "$(pause_file "$IDIR")" 2>/dev/null)" = "a pause recorded by newer work" ] \
    || lost=$((lost + 1))
done
[ "$lost" = 0 ] \
  && ok "across 25 interleavings, a pause recorded by newer work is never deleted by an older decision" \
  || bad "$lost of 25 interleavings lost the newer pause"
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending" \
      "$SUPERVISOR_STATE_DIR/usage.json"


# Deterministic, and about the other half of the guarantee. The hammer above proves nothing is
# lost across interleavings; this pins the exact case the reviewer named — a writer arriving AFTER
# the fingerprint was checked, while the drop is still mid-flight. It must wait for the drop and
# then land, not give up and not be deleted.
rm -f "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-pending"
rm -rf "$IDIR/pause.lock"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "the pause being dropped"
# Stand exactly where a drop stands: past its check, holding the marker, about to remove it.
_pause_lock "$IDIR"
( pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "arrived while the drop held the marker" \
    && printf 'wrote\n' > "$TMP/late-write" ) &
LATE=$!
sleep 2
rm -f "$(pause_file "$IDIR")"          # what the drop does, inside the lock
_pause_unlock "$IDIR"
wait "$LATE" 2>/dev/null
[ -s "$TMP/late-write" ] \
  && ok "a writer arriving mid-drop waits for it instead of giving up" \
  || bad "the pause that newer work tried to record was silently dropped"
[ "$(jq -r '.reason // empty' "$(pause_file "$IDIR")" 2>/dev/null)" = "arrived while the drop held the marker" ] \
  && ok "…and its marker is the one standing afterwards" \
  || bad "the marker afterwards is: $(jq -r '.reason // "<none>"' "$(pause_file "$IDIR")" 2>/dev/null)"
rm -f "$TMP/late-write" "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")"

echo "===== a question is never held for hours, whichever door it came through ====="
# The consultation channel was bounded and this hook was not, which is the same freeze reached a
# different way: a question is asked from inside Claude's own turn, so waiting out a five-hour
# window here froze the implementer solid.
HOOKS="$(cd "$BIN/../hooks" && pwd)"
QPROJ="$TMP/qrepo"; mkdir -p "$QPROJ"
QPROJ="$(canon_path "$QPROJ")"
QSLUG="$(slug_for "$QPROJ")"; QIDIR="$(instance_dir "$QSLUG")"; mkdir -p "$QIDIR"
printf '%s' "$QPROJ" > "$QIDIR/project"
printf '%s' "QRUN" > "$QIDIR/run-id"; printf '%s' "q-session" > "$QIDIR/session"
jq -n --argjson ts "$(now)" \
  '{ts:$ts, observed_at:$ts, source:"cli",
    five_hour:{used_percentage:99, resets_at:($ts + 14400), window_minutes:300},
    seven_day:{used_percentage:5, resets_at:($ts + 500000), window_minutes:10080}}' \
  > "$SUPERVISOR_STATE_DIR/codex-usage.json"
printf '#!/bin/bash\nexit 1\n' > "$TMP/no-codex"; chmod +x "$TMP/no-codex"
q_started="$(now)"
jq -n --arg cwd "$QPROJ" '{cwd:$cwd, tool_use_id:"t-1", tool_input:{questions:[
  {question:"Назвати поле lastSeenAt чи lastOpenedAt?", header:"Іменування", multiSelect:false,
   options:[{label:"lastSeenAt",description:""},{label:"lastOpenedAt",description:""}]}]}}' \
  | ORCHESTRATOR_RUN_ID=QRUN SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
    SUPERVISOR_ASK_USER_WAIT_DEGRADED=3 \
    SUPERVISOR_CODEX_BIN="$TMP/no-codex" \
    bash "$HOOKS/answer-question.sh" > "$TMP/q-out.json" 2>/dev/null
q_elapsed=$(( $(now) - q_started ))
[ "$q_elapsed" -lt 40 ] \
  && ok "a Codex window four hours out does not hold the question (returned in ${q_elapsed}s)" \
  || bad "the question hook froze the implementer for ${q_elapsed}s"
[ -s "$QIDIR/peer-codex.unavailable" ] \
  && ok "…and the run records that Codex sat this one out" \
  || bad "the degradation left no trace for the app to show"
[ ! -e "$QIDIR/awaiting-codex" ] \
  && ok "…leaving no countdown behind over a run that is not waiting" \
  || bad "an awaiting-codex marker outlived the wait"
# And what it hands back is CONTROL, not a park: a reversible question nobody read is Claude's to
# decide. Bounding the Codex wait only to fall into an hour of waiting for the director would have
# been the same freeze one door further along.
grep -q "Це оборотне рішення — воно твоє" "$TMP/q-out.json" 2>/dev/null \
  && ok "…and a reversible question nobody read comes back to Claude to decide" \
  || bad "the hook parked the run instead of returning control: $(head -c 200 "$TMP/q-out.json" 2>/dev/null)"
grep -q '"source":"claude"' "$SUPERVISOR_STATE_DIR/decisions.jsonl" 2>/dev/null \
  && ok "…and the journal records who actually decided it" \
  || bad "the journal still credits a gate or a reviewer that never read it"

# The SAME path with the director's own patience left at its DEFAULT — nothing shortened, nothing
# stubbed. The earlier version of this test set SUPERVISOR_ASK_USER_WAIT=2, which hid an hour-long
# wait rather than proving there was none.
#
# Measured from the countdown the hook publishes rather than by sitting through it: the marker
# carries the deadline it intends to wait until, so the bound can be read in a second instead of
# three minutes. Waiting it out would prove the same thing and make this suite too slow to be
# worth running, which is its own way of losing the guarantee.
rm -f "$QIDIR/ask-user.json" "$QIDIR/awaiting-codex" "$QIDIR/peer-codex.unavailable"
jq -n --arg cwd "$QPROJ" '{cwd:$cwd, tool_use_id:"t-2", tool_input:{questions:[
  {question:"Який відступ поставити у списку — 8 чи 12?", header:"Верстка", multiSelect:false,
   options:[{label:"8",description:""},{label:"12",description:""}]}]}}' \
  | ORCHESTRATOR_RUN_ID=QRUN SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
    SUPERVISOR_CODEX_BIN="$TMP/no-codex" \
    bash "$HOOKS/answer-question.sh" >/dev/null 2>&1 &
QHOOK=$!
tries=0; deadline=""
while [ "$tries" -lt 60 ]; do
  [ -s "$QIDIR/awaiting-codex" ] && { deadline="$(jq -r '.await_until // empty' "$QIDIR/awaiting-codex" 2>/dev/null)"; }
  [ -n "$deadline" ] && break
  sleep 0.25; tries=$((tries + 1))
done
kill "$QHOOK" 2>/dev/null; wait "$QHOOK" 2>/dev/null
case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
q_wait=$(( deadline - $(now) ))
[ "$deadline" -gt 0 ] \
  && ok "the hook publishes the deadline it intends to wait until ($(( q_wait ))s away)" \
  || bad "no countdown was published, so the wait cannot be read"
# 180s of patience plus the marker's own 120s of slack. An hour would be 3720.
[ "$deadline" -gt 0 ] && [ "$q_wait" -le 400 ] \
  && ok "with the director's patience at its DEFAULT it is minutes, not the full hour" \
  || bad "the default path still intends to wait ${q_wait}s"
rm -f "$QIDIR/ask-user.json" "$QIDIR/awaiting-codex"

# A question a keyword flags as risky is bounded the same way — the flag is a regex over the text,
# not a judgement, and an hour of frozen turn is a lot to spend on a guess. What does NOT change is
# where it ends up: nobody decides an irreversible action on Claude's behalf.
rm -f "$QIDIR/ask-user.json" "$QIDIR/awaiting-codex"
q_started="$(now)"
jq -n --arg cwd "$QPROJ" '{cwd:$cwd, tool_use_id:"t-3", tool_input:{questions:[
  {question:"Чи запускати міграцію на production?", header:"Deploy", multiSelect:false,
   options:[{label:"Так",description:""},{label:"Ні",description:""}]}]}}' \
  | ORCHESTRATOR_RUN_ID=QRUN SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
    SUPERVISOR_ASK_USER_WAIT_DEGRADED=3 SUPERVISOR_CODEX_BIN="$TMP/no-codex" \
    bash "$HOOKS/answer-question.sh" > "$TMP/q-risky.json" 2>/dev/null
q_elapsed=$(( $(now) - q_started ))
[ "$q_elapsed" -lt 40 ] \
  && ok "a risky-looking question is bounded too (returned in ${q_elapsed}s)" \
  || bad "a regex guess froze the implementer for ${q_elapsed}s"
grep -q "НЕ виконуй цю дію" "$TMP/q-risky.json" 2>/dev/null \
  && ok "…and it still ends in 'do not do this, finish blocked', not in Claude deciding it" \
  || bad "an irreversible action was handed back for Claude to decide: $(head -c 200 "$TMP/q-risky.json" 2>/dev/null)"
rm -f "$SUPERVISOR_STATE_DIR/codex-usage.json"

echo "===== the watchdog: no long sleep, no resume into somebody else's work ====="
# A clean slate: the cases above deliberately leave a controlled attempt and the resume it owes,
# and a watchdog started on top of that would be answering the previous question.
rm -f "$IDIR/resume-pending" "$IDIR/review-pending" "$IDIR/last-resume"       "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")" "$IDIR/resume-attempts"
export SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_IDLE_KILL_SECS=0 SUPERVISOR_STALL_PARK_SECS=0
export SUPERVISOR_PUMP_CMD="$TMP/pump-stub.sh"
cat > "$TMP/pump-stub.sh" <<'PUMP'
#!/bin/bash
printf '%s\n' "started" >> "$SUPERVISOR_STATE_DIR/pump-started"
PUMP
chmod +x "$TMP/pump-stub.sh"
tmux new-session -d -s "$SESSION" 'while :; do sleep 1; done' 2>/dev/null
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "⚠️  tmux не піднявся — пропускаю решту"; [ "$fails" = 0 ] && exit 0 || exit 1
fi

# A pause four hours out, belonging to Codex. The old watchdog would have slept through all of it
# and the queue with it; this one has to come round every poll and start the pump anyway.
rm -f "$SUPERVISOR_STATE_DIR/pump-started" "$IDIR/last-resume" "$(pause_last_file "$IDIR")"
rm -f "$IDIR/dispatch.json"
usage codex 99 "$(( $(now) + 14400 ))"
usage claude 4 "$(( $(now) + 9000 ))"
pause_record "$IDIR" codex "$(( $(now) + 14400 ))" "codex usage guard"
pending_enqueue "$IDIR" "закоміть і випусти версію" "aaaaaaaa-0000-0000-0000-000000000001" adaptive-peer conversation >/dev/null
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
tries=0
while [ ! -s "$SUPERVISOR_STATE_DIR/pump-started" ] && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -s "$SUPERVISOR_STATE_DIR/pump-started" ] \
  && ok "a queued message is picked up while Codex is parked, instead of waiting out the window" \
  || bad "the queue was frozen behind a Codex pause — the original hour-long stall"
[ -e "$IDIR/last-resume" ] \
  && bad "Codex coming back typed a 'carry on' at Claude, who was never stopped" \
  || ok "…and nothing was typed at Claude, who was never stopped"

# A marker left behind by earlier work. Nothing may be typed from it.
rm -f "$IDIR/last-resume" "$(pause_last_file "$IDIR")" "$IDIR/pending"/*.json 2>/dev/null
no_usage
jq -nc '{id:"DISPATCH-OLD"}' > "$IDIR/dispatch.json"
pause_record "$IDIR" claude "$(( $(now) - 10 ))" "usage guard"
jq -nc '{id:"DISPATCH-NEW"}' > "$IDIR/dispatch.json"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
tries=0
while [ -e "$(pause_file "$IDIR")" ] && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
sleep 1
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -e "$(pause_file "$IDIR")" ] && bad "the stale marker was never reconciled" \
  || ok "a marker belonging to finished work is dropped"
[ -e "$IDIR/last-resume" ] \
  && bad "a stale watchdog typed 'carry on with the current task' into different work" \
  || ok "…and nothing was resumed from it"

# A watchdog whose run has been replaced supervises nobody.
printf '%s\n' "RUN-A" > "$IDIR/run-id"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 1
printf '%s\n' "RUN-C" > "$IDIR/run-id"
tries=0
while kill -0 "$WD" 2>/dev/null && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
kill -0 "$WD" 2>/dev/null && { bad "the old watchdog kept supervising a new run"; kill "$WD" 2>/dev/null; } \
  || ok "a watchdog whose run was replaced stands down"
wait "$WD" 2>/dev/null

# A review the Codex window interrupted. Claude was ALLOWED to stop, so without this the run ends
# up looking reviewed when nothing ever reviewed it — and with no further messages, nothing else
# would ever ask for it again.
rm -f "$IDIR/last-resume" "$IDIR/resume-pending" "$(pause_file "$IDIR")" "$(pause_last_file "$IDIR")"       "$IDIR/resume-attempts" "$IDIR/dispatch.json" "$IDIR/pending"/*.json 2>/dev/null
export SUPERVISOR_RESUME_CONFIRM_WAIT=1
usage codex 4 "$(( $(now) + 9000 ))"
usage claude 4 "$(( $(now) + 9000 ))"
jq -nc --argjson at "$(now)" '{reason:"codex window ran out before the review", at:$at}' > "$IDIR/review-pending"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
tries=0
while [ ! -e "$IDIR/last-resume" ] && [ "$tries" -lt 60 ]; do sleep 0.25; tries=$((tries + 1)); done
# `last-resume` is written before the attempt; the line saying WHY comes after it finishes.
tries=0
while ! grep -q "review was still owed" "$SUP_STATE/watchdog.log" 2>/dev/null && [ "$tries" -lt 40 ]; do
  sleep 0.25; tries=$((tries + 1))
done
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -e "$IDIR/last-resume" ]   && ok "a review a Codex window interrupted is asked for again once Codex is back"   || bad "the deferred review was silently dropped — the run would look reviewed"
grep -q "review was still owed" "$SUP_STATE/watchdog.log" 2>/dev/null   && ok "…and the log says that is what it was for" || bad "the resume did not name the owed review"

rm -f "$IDIR/last-resume" "$IDIR/resume-attempts" "$IDIR/stalled.json"
jq -nc --argjson at "$(now)" '{reason:"x", at:$at}' > "$IDIR/review-pending"
usage codex 99 "$(( $(now) + 9000 ))"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 2
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -e "$IDIR/last-resume" ]   && bad "the worker was nudged for a review while Codex was still out"   || ok "and it waits rather than nudging while Codex is still out"
rm -f "$IDIR/review-pending" "$IDIR/stalled.json" "$IDIR/resume-attempts"
unset SUPERVISOR_RESUME_CONFIRM_WAIT



# A meter that cannot be read must not end a run as though it had been checked. Codex itself may
# be perfectly fine — the attempt is the better test, and it is the same rule the peer stage and
# the consultations already follow.
rm -f "$IDIR/last-resume" "$IDIR/resume-attempts" "$IDIR/stalled.json" "$IDIR/resume-refused"
export SUPERVISOR_RESUME_CONFIRM_WAIT=1
no_usage
jq -nc --argjson at "$(now)" '{reason:"x", at:$at}' > "$IDIR/review-pending"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
tries=0
while [ ! -e "$IDIR/last-resume" ] && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -e "$IDIR/last-resume" ] \
  && ok "an unreadable meter still gets the owed review asked for, rather than dropped" \
  || bad "a telemetry outage silently ended the run unreviewed"
[ -e "$IDIR/review-pending" ] \
  && ok "…and the review stays owed until the gate itself says it happened" \
  || bad "delivering a prompt was mistaken for a review having run"
rm -f "$IDIR/review-pending" "$IDIR/last-resume" "$IDIR/resume-attempts" "$IDIR/stalled.json"
unset SUPERVISOR_RESUME_CONFIRM_WAIT


# The work changing hands WHILE the composer is busy. Checking ownership before taking the claim
# is checking early: taking it can block until somebody else finishes a handover, and the task can
# be superseded inside that wait.
rm -f "$IDIR/last-resume" "$IDIR/resume-attempts" "$IDIR/stalled.json" "$IDIR/resume-refused" \
      "$IDIR/review-pending"
export SUPERVISOR_RESUME_CONFIRM_WAIT=1
usage claude 4 "$(( $(now) + 9000 ))"
jq -nc '{id:"DISPATCH-OWNER-A"}' > "$IDIR/dispatch.json"
jq -nc --arg r "RUN-A" --arg d "DISPATCH-OWNER-A" --argjson at "$(now)" \
  '{reason:"limit lifted", at:$at, run_id:$r, dispatch_id:$d}' > "$IDIR/resume-pending"
# Somebody else is mid-handover, so the watchdog's claim has to wait.
mkdir -p "$IDIR/delivery.lock"; printf '%s\n' "$$" > "$IDIR/delivery.lock/pid"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 2
# …and while it waits, the run moves on to different work.
jq -nc '{id:"DISPATCH-OWNER-B"}' > "$IDIR/dispatch.json"
rm -rf "$IDIR/delivery.lock"
tries=0
while [ -e "$IDIR/resume-pending" ] && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -e "$IDIR/last-resume" ] \
  && bad "a resume owed to finished work was typed into the task that replaced it" \
  || ok "work that changes hands while the composer is busy does not inherit the old resume"
[ -e "$IDIR/resume-pending" ] \
  && bad "…and the stale note was left to try again" \
  || ok "…and the note that asked for it is dropped"
rm -f "$IDIR/dispatch.json" "$IDIR/last-resume" "$IDIR/resume-attempts" "$IDIR/stalled.json"
unset SUPERVISOR_RESUME_CONFIRM_WAIT

# A worker that will not take a resume is parked for a person, not nudged for ever.
rm -f "$IDIR/last-resume" "$IDIR/review-pending"
: > "$IDIR/resume-refused"
jq -nc --argjson at "$(now)" '{reason:"limit lifted", at:$at}' > "$IDIR/resume-pending"
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
tries=0
while [ -e "$IDIR/resume-pending" ] && [ "$tries" -lt 40 ]; do sleep 0.25; tries=$((tries + 1)); done
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -e "$IDIR/resume-pending" ] \
  && bad "an owed resume kept being retried at a worker that had already refused three times" \
  || ok "a worker that refuses resumes is parked for a person, not nudged in a loop"
[ -e "$IDIR/last-resume" ] && bad "…and it was typed at anyway" || ok "…and nothing was typed at it"
rm -f "$IDIR/resume-refused" "$IDIR/stalled.json"

# Parked on a window is waiting, not stalled, and certainly not dead.
printf '%s\n' "RUN-A" > "$IDIR/run-id"
rm -f "$IDIR/stalled.json" "$(pause_last_file "$IDIR")" "$IDIR/dispatch.json"
export SUPERVISOR_IDLE_KILL_SECS=1 SUPERVISOR_STALL_PARK_SECS=1
usage claude 99 "$(( $(now) + 9000 ))"
pause_record "$IDIR" claude "$(( $(now) + 9000 ))" "usage guard"
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date '+%Y%m%d%H%M')" "$IDIR/last-activity" 2>/dev/null
bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
sleep 3
alive=0; kill -0 "$WD" 2>/dev/null && alive=1
kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
[ -d "$IDIR" ] && [ "$alive" = 1 ] \
  && ok "a run parked on a usage window is not torn down for going quiet" \
  || bad "the idle teardown fired during a quota pause"
[ -e "$IDIR/stalled.json" ] \
  && bad "a quota pause was reported to the director as a stall" \
  || ok "…and it is not reported as a stall either"

echo
[ "$fails" = 0 ] && { echo "✅ limit recovery: all $pass passed"; exit 0; }
echo "❌ limit recovery: $fails failure(s)"; exit 1
