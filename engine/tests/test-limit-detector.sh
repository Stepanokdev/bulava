#!/bin/bash
# A clock is not a refusal.
#
# The incident: a run on another machine stopped dead with nine per cent of its window used. The
# watchdog reads the last lines of Claude's pane looking for a usage limit, and its pattern accepted
# `resets? … [0-9]` — while our OWN statusline.sh renders `| 5h: 9% (reset 01:40) |` into that very
# pane. `reset 0` matched. The engine paused a run because of a number it had printed itself, and
# the queue behind it stopped.
#
# What has to be true, both ways round: our own status bar never pauses anything, a real refusal
# still does, and a reset time with no refusal in it pauses only when the meter independently says
# the window is gone.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"
cleanup() { tmux_cleanup 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
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
: > "$IDIR/started-at"; : > "$IDIR/direct-chat"

now() { date +%s; }
usage() {   # $1=five-hour %  [$2=weekly %]  [$3=five-hour reset]  [$4=weekly reset]
  jq -n --argjson u "$1" --argjson w "${2:-3}" \
        --argjson r "${3:-$(( $(now) + 9000 ))}" --argjson wr "${4:-$(( $(now) + 500000 ))}" \
        --argjson ts "$(now)" \
    '{ts:$ts, observed_at:$ts, source:"cli",
      five_hour:{used_percentage:$u, resets_at:$r, window_minutes:300},
      seven_day:{used_percentage:$w, resets_at:$wr, window_minutes:10080}}' \
    > "$SUPERVISOR_STATE_DIR/usage.json"
}
export SUPERVISOR_CLAUDE_USAGE_CMD="/usr/bin/true" SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"

STATUS='[Opus 5] ~/proj | 5h: 9% (reset 01:40) | 7d: 10% | Cx: 4%'

echo "===== our own status bar is not evidence ====="
printf '%s\n' "$STATUS" | limit_strip_status | grep -qiE "$LIMIT_EXPLICIT|$LIMIT_AMBIGUOUS" \
  && bad "the status line we print ourselves still reads as a usage limit" \
  || ok "the status bar says a time, and a time is not a refusal"
printf '%s\n' "$STATUS" | limit_strip_status | grep -q '5h:' \
  && bad "the strip left the fragment behind" \
  || ok "only our own fragment is removed"
printf 'Claude usage limit reached | 5h: 9%% (reset 01:40)\n' | limit_strip_status \
  | grep -qiE "$LIMIT_EXPLICIT" \
  && ok "and an error sharing that line survives the strip" \
  || bad "stripping the status fragment took a real error with it"

echo
echo "===== a refusal still stops the work ====="
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s\n' "$line" | limit_strip_status | grep -qiE "$LIMIT_EXPLICIT" \
    && ok "refusal recognised: ${line:0:52}" \
    || bad "a real limit message was not recognised: $line"
done <<'MSGS'
Claude usage limit reached. Your limit will reset at 3pm (Europe/Kyiv).
You have hit your usage limit. Try again later.
Stop and wait for limit to reset
Ask your admin for more usage
You are out of messages until the window resets
MSGS

echo
echo "===== and text ABOUT limits is not a refusal ====="
for line in \
  'watchdog приймає рядок статусу reset 01:40 за usage limit' \
  'the detector used to fire on a session limit string in the pane' \
  '5h: 9% (reset 01:40)'
do
  printf '%s\n' "$line" | limit_strip_status | grep -qiE "$LIMIT_EXPLICIT" \
    && bad "a sentence discussing limits counts as a refusal: $line" \
    || ok "discussion is not refusal: ${line:0:46}"
done

# ---------------------------------------------------------------- the real watchdog
# The detector reads the BOTTOM of the pane, where a real session's newest output is. A fixture
# that prints one line into a fresh pane leaves it at the top with twenty blank lines under it,
# and proves nothing at all — the first version of this suite did exactly that.
pane_with() {   # $1 = what Claude's pane shows
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux new-session -d -s "$SESSION" "printf '\n%.0s' \$(seq 30); printf '%s\n' \"$1\"; sleep 300" 2>/dev/null
  sleep 0.6
  tmux capture-pane -pt "$SESSION" 2>/dev/null | tail -12 | grep -qF "${1:0:24}" \
    || bad "fixture: the pane does not show the text the detector reads"
}
WD_LOG="$SUPERVISOR_STATE_DIR/watchdog.log"
run_watchdog() {   # $1 = seconds to let it poll
  # Each case is its own machine. The detector only looks again once the re-check cooldown has
  # passed since the last resume, so a case that paused leaves the next one deaf for ten minutes —
  # which reads exactly like the detector being broken.
  rm -f "$WD_LOG" "$IDIR/last-resume" "$IDIR/resume-pending" "$IDIR/pause-last.json" \
        "$IDIR/resume-attempts" "$IDIR/stalled.json"
  bash "$BIN/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
  local wd=$!
  sleep "$1"
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
}
export SUPERVISOR_WATCHDOG_POLL=1 SUPERVISOR_TURN_PROBE_GAP=0 \
       SUPERVISOR_IDLE_KILL_SECS=0 SUPERVISOR_STALL_PARK_SECS=0

echo
echo "===== the pane the user actually had ====="
rm -f "$(pause_file "$IDIR")"
usage 9 10
pane_with "$STATUS"
run_watchdog 4                      # four polls, the report asked for at least two
detected() { grep -q "usage-limit state detected" "$WD_LOG" 2>/dev/null; }
if detected; then
  bad "nine per cent used, and the run was paused for a usage limit anyway: $(grep -m1 'usage-limit' "$WD_LOG")"
else
  ok "a status bar at 9% does not pause the run"
fi

echo
echo "===== a real refusal in the pane still does ====="
rm -f "$(pause_file "$IDIR")"
usage 9 10
pane_with 'Claude usage limit reached. Your limit will reset at 01:40.'
run_watchdog 4
if grep -q "usage-limit state detected in pane (explicit)" "$WD_LOG" 2>/dev/null; then
  ok "the refusal was believed without asking the meter"
  grep -q "marked paused-for-limit (claude" "$WD_LOG" 2>/dev/null \
    && ok "and the pause was recorded as Claude's" \
    || bad "it was detected and nothing was recorded"
  grep -q "detected in pane (explicit): Claude usage limit reached" "$WD_LOG" 2>/dev/null \
    && ok "the log carries the line that fired, so a false one can be read back" \
    || bad "the log does not say what it matched"
else
  bad "a real usage limit no longer stops the work — far worse than the bug being fixed"
fi

echo
echo "===== a reset time alone waits for the meter to agree ====="
rm -f "$(pause_file "$IDIR")"
usage 9 10
pane_with 'Next window resets at 01:40'
run_watchdog 4
grep -q "usage-limit state detected" "$WD_LOG" 2>/dev/null \
  && bad "a bare reset time paused a window with 9% used" \
  || ok "a time with no refusal in it is not enough on its own"

rm -f "$(pause_file "$IDIR")"
usage 100 10
pane_with 'Next window resets at 01:40'
run_watchdog 4
grep -q "usage-limit state detected in pane (ambiguous-confirmed)" "$WD_LOG" 2>/dev/null \
  && ok "…and with the meter reading 99% it is" \
  || bad "an exhausted meter plus a reset time did not pause"

echo
echo "===== the recorded return is the window that actually ran out ====="
rm -f "$(pause_file "$IDIR")"
# Inside the six hours a pause is ever allowed to wait: further out than that and the engine
# deliberately re-checks in half an hour instead, which would hide which window it picked.
WRESET=$(( $(now) + 14400 ))
usage 4 100 "$(( $(now) + 3600 ))" "$WRESET"
pane_with 'Claude usage limit reached. Your limit will reset next week.'
run_watchdog 4
want="$(when_human "$WRESET")"
if grep -q "marked paused-for-limit (claude, resume after $want)" "$WD_LOG" 2>/dev/null; then
  ok "the weekly window's reset is what it waits for"
else
  bad "it waits for the five-hour reset while the WEEK ran out: $(grep -m1 'marked paused' "$WD_LOG" || echo 'nothing recorded')"
fi

echo
echo "===== Enter goes to the limit dialog, not to whatever is on screen ====="
rm -f "$(pause_file "$IDIR")"
usage 9 10
pane_with 'Claude usage limit reached. Press enter to confirm your name'
run_watchdog 4
grep -q "selected 'Stop and wait" "$WD_LOG" 2>/dev/null \
  && bad "Enter was typed into a prompt that was not the limit dialog" \
  || ok "no Enter without the limit dialog on screen"

rm -f "$(pause_file "$IDIR")"
usage 9 10
# The phrase, quoted in the middle of a transcript, with an ordinary prompt underneath it. Typing
# Enter here answers whatever question is actually on screen.
pane_with 'the report says: Stop and wait for limit to reset
Do you want to delete the branch? (y/N)'
run_watchdog 4
grep -q "selected 'Stop and wait" "$WD_LOG" 2>/dev/null \
  && bad "Enter was typed under a question that was not the limit dialog" \
  || ok "a refusal quoted above a prompt does not get a keystroke"

rm -f "$(pause_file "$IDIR")"
usage 9 10
pane_with 'Claude usage limit reached.
> 1. Stop and wait for limit to reset'
run_watchdog 4
grep -q "selected 'Stop and wait" "$WD_LOG" 2>/dev/null \
  && ok "…and the real dialog, at the bottom of the pane, still gets answered" \
  || bad "a genuine limit dialog was left unanswered — the run would wait for a person"

echo
echo "===== a refusal that names no window is still a refusal ====="
printf 'You have reached your limit. Please try again later.\n' | limit_strip_status \
  | grep -qiE "$LIMIT_EXPLICIT" \
  && ok "«reached your limit» counts, with no window named" \
  || bad "a refusal was missed because it did not say which limit"

echo
[ "$fails" = 0 ] && echo "✅ a clock is not a refusal, and a refusal is not a clock" \
                 || echo "❌ $fails problem(s)"
exit "$fails"
