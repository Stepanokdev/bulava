#!/bin/bash
# A pause is measured in hours, never in days.
#
# The review gate parks a run until a rate-limit window resets, reading the reset timestamp out of
# the usage cache. Codex changed shape: it now reports ONE window with window_minutes 10080 as
# `primary`, and the parser mapped primary → five_hour — so a WEEKLY reset landed in the
# five-hour field and a run was parked until the following Saturday. Nothing ran, nothing was
# blocked, and the night looked like it had simply done nothing.
#
# Two things are locked down here: windows are classified by LENGTH, not position; and a claimed
# reset that is days away is treated as bad data (re-check soon) rather than obeyed.
#
# A third, added after the left panel went blank for a week: the reading must survive the session
# files Codex actually writes. A single line in a current rollout runs to megabytes, and the old
# reader took a BYTE tail of the file — so the fragment at the top was invalid JSON, jq exited on
# it before emitting anything, and every reading came back "unknown" while the limits sat in the
# file untouched. The CLI is asked directly now, with the log scan as the fallback; both are
# pinned here.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "===== windows are classified by length, not position ====="

# The real script, fed a known payload. A copy of its jq in here had already drifted from it,
# which is exactly how a test comes to pass a bug that does not exist.
export SUPERVISOR_STATE_DIR="$TMP/state"
export CODEX_SESSIONS_DIR="$TMP/sessions"
mkdir -p "$SUPERVISOR_STATE_DIR" "$CODEX_SESSIONS_DIR"

# A stub CLI that answers nothing, so these cases exercise the log fallback and its classifier
# rather than this machine's real quota.
cat > "$TMP/codex-silent" <<'STUB'
#!/bin/bash
# Exits at once without draining stdin, the way a CLI that has no `app-server` would.
exit 1
STUB
chmod +x "$TMP/codex-silent"
export SUPERVISOR_CODEX_BIN="$TMP/codex-silent"

usage_for() {  # $1 = the rate_limits object
  printf '{"rate_limits":%s}\n' "$1" > "$CODEX_SESSIONS_DIR/s.jsonl"
  bash "$BIN_DIR/codex-usage.sh" 2>/dev/null
}

# Today's payload: ONE weekly window, arriving as `primary`.
out="$(usage_for '{"primary":{"used_percent":91.0,"window_minutes":10080,"resets_at":9999999999},"secondary":null,"plan_type":"plus"}')"
[ "$(printf '%s' "$out" | jq -r '.five_hour.resets_at')" = "0" ] \
  && ok "a weekly reset does NOT land in the five-hour field" \
  || bad "the weekly reset is still read as a five-hour reset"
[ "$(printf '%s' "$out" | jq -r '.seven_day.used_percentage|floor')" = "91" ] \
  && ok "the weekly pressure is reported as weekly" || bad "weekly usage lost"
[ "$(printf '%s' "$out" | jq -r '.five_hour.used_percentage|floor')" = "0" ] \
  && ok "no short-window pressure is invented from weekly data" \
  || bad "weekly usage leaked into the short window"

# The older shape must still work: primary = short, secondary = weekly, no window_minutes.
out2="$(usage_for '{"primary":{"used_percent":80,"resets_at":1500},"secondary":{"used_percent":40,"resets_at":9000},"plan_type":"pro"}')"
[ "$(printf '%s' "$out2" | jq -r '.five_hour.resets_at')" = "1500" ] \
  && ok "the older payload shape still maps correctly" \
  || bad "backward compatibility broken for the old rate-limit shape"
[ "$(printf '%s' "$out2" | jq -r '.seven_day.used_percentage|floor')" = "40" ] \
  && ok "and its weekly window stays weekly" || bad "old-shape weekly window lost"

# Both windows short-ish: the first short one wins, nothing crashes.
out3="$(usage_for '{"primary":{"used_percent":10,"window_minutes":60,"resets_at":111},"secondary":{"used_percent":20,"window_minutes":300,"resets_at":222},"plan_type":"plus"}')"
[ "$(printf '%s' "$out3" | jq -r '.five_hour.resets_at')" = "111" ] \
  && ok "two short windows: the first is used" || bad "two short windows confused the parser"

echo "===== the reading survives the session files Codex actually writes ====="

# The shape as it really arrives: nested in an event_msg/token_count payload, next to a line of
# tool output big enough that a byte tail would land inside it, and followed by a half-written
# final line — a rollout that is still being appended to.
real="$CODEX_SESSIONS_DIR/rollout-real.jsonl"
big="$(head -c 300000 /dev/zero | tr '\0' 'x')"
{
  printf '{"timestamp":"2026-09-10T10:00:00.000Z","type":"response_item","payload":{"output":"%s"}}\n' "$big"
  printf '{"timestamp":"2026-09-10T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":41.0,"window_minutes":300,"resets_at":1500},"secondary":{"used_percent":62.0,"window_minutes":10080,"resets_at":9000}}}}\n'
  printf '{"timestamp":"2026-09-10T10:02:00.000Z","type":"response_item","payload":{"output":"%s"}}\n' "$big"
  printf '{"timestamp":"2026-09-10T10:03:00.000Z","type":"event_ms'
} > "$real"
rm -f "$CODEX_SESSIONS_DIR/s.jsonl"

out4="$(bash "$BIN_DIR/codex-usage.sh" 2>/dev/null)"
[ "$(printf '%s' "$out4" | jq -r '.five_hour.used_percentage|floor')" = "41" ] \
  && ok "a reading is found past a 300 KB line and a truncated tail" \
  || bad "the reading was lost to line size again (\"$(printf '%s' "$out4" | jq -rc '.reason // .five_hour')\")"
[ "$(printf '%s' "$out4" | jq -r '.seven_day.used_percentage|floor')" = "62" ] \
  && ok "and its weekly window came with it" || bad "weekly window lost in the real envelope"
[ "$(printf '%s' "$out4" | jq -r '.source')" = "session" ] \
  && ok "the fallback says where the number came from" || bad "the source is not recorded"

# The freshest reading wins, not the last one the file walk happened to reach.
printf '{"timestamp":"2026-09-10T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":9.0,"window_minutes":10080,"resets_at":2}}}}\n' \
  > "$CODEX_SESSIONS_DIR/rollout-older.jsonl"
touch "$CODEX_SESSIONS_DIR/rollout-older.jsonl"
out5="$(bash "$BIN_DIR/codex-usage.sh" 2>/dev/null)"
[ "$(printf '%s' "$out5" | jq -r '.five_hour.used_percentage|floor')" = "41" ] \
  && ok "an older reading in a newer file does not win" \
  || bad "a stale reading overwrote the fresh one"

echo "===== the CLI is asked first, and it is believed ====="

# `codex app-server --stdio` answers account/rateLimits/read with the live windows, in camelCase.
cat > "$TMP/codex-rpc" <<'STUB'
#!/bin/bash
cat >/dev/null &
printf '%s\n' '{"id":1,"result":{"codexHome":"/tmp"}}'
printf '%s\n' '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":77,"windowDurationMins":300,"resetsAt":4242},"secondary":{"usedPercent":57,"windowDurationMins":10080,"resetsAt":8484},"planType":"plus"}}}}'
exit 0
STUB
chmod +x "$TMP/codex-rpc"

out6="$(SUPERVISOR_CODEX_BIN="$TMP/codex-rpc" bash "$BIN_DIR/codex-usage.sh" 2>/dev/null)"
[ "$(printf '%s' "$out6" | jq -r '.five_hour.used_percentage|floor')" = "77" ] \
  && ok "the live five-hour window comes from the CLI" || bad "the CLI answer was not used"
[ "$(printf '%s' "$out6" | jq -r '.seven_day.resets_at')" = "8484" ] \
  && ok "and so does the weekly reset" || bad "the CLI's weekly window was lost"
[ "$(printf '%s' "$out6" | jq -r '.source')" = "cli" ] \
  && ok "the source says it was asked, not scraped" || bad "the source is wrong for the CLI path"
[ "$(printf '%s' "$out6" | jq -r '.plan')" = "plus" ] \
  && ok "the plan comes across too" || bad "the plan was dropped"

# A CLI that answers something unusable must not shout down the logs.
cat > "$TMP/codex-garbage" <<'STUB'
#!/bin/bash
cat >/dev/null &
printf '%s\n' '{"id":2,"result":{"nothing":true}}'
exit 0
STUB
chmod +x "$TMP/codex-garbage"
out7="$(SUPERVISOR_CODEX_BIN="$TMP/codex-garbage" bash "$BIN_DIR/codex-usage.sh" 2>/dev/null)"
[ "$(printf '%s' "$out7" | jq -r '.source')" = "session" ] \
  && ok "an unusable CLI answer falls back to the logs" || bad "a useless CLI answer blocked the fallback"

# Nothing anywhere is "unknown" — never a zero pretending to be a reading.
out8="$(CODEX_SESSIONS_DIR="$TMP/empty" SUPERVISOR_CODEX_BIN="$TMP/codex-silent" bash "$BIN_DIR/codex-usage.sh" 2>/dev/null)"
[ "$(printf '%s' "$out8" | jq -r '.unknown')" = "true" ] \
  && ok "no source at all is unknown, not zero" || bad "no reading was reported as a real zero"

echo "===== a claimed reset days away is bad data, not an instruction ====="

# The clamp, as the gate defines it.
SUPERVISOR_MAX_PAUSE_SECONDS=21600
SUPERVISOR_RECHECK_SECONDS=1800
sane_resume_at() {
  local at="${1:-0}" now; now="$(date +%s)"
  if [ "${at:-0}" -gt "$now" ] && [ $(( at - now )) -le "$SUPERVISOR_MAX_PAUSE_SECONDS" ]; then
    printf '%s' "$at"
  else
    printf '%s' $(( now + SUPERVISOR_RECHECK_SECONDS ))
  fi
}

now="$(date +%s)"
in_two_hours=$(( now + 7200 ))
[ "$(sane_resume_at "$in_two_hours")" = "$in_two_hours" ] \
  && ok "a real reset two hours out is obeyed" || bad "a sane reset was overridden"

six_days=$(( now + 518400 ))
got="$(sane_resume_at "$six_days")"
[ "$got" -lt $(( now + 3600 )) ] \
  && ok "a reset six days out is replaced by a soon re-check" \
  || bad "still willing to sleep for days ($(( (got - now) / 3600 ))h)"

[ "$(sane_resume_at 0)" -gt "$now" ] && ok "a missing reset still yields a real time" \
                                     || bad "no reset time produced nothing"
past=$(( now - 100 ))
[ "$(sane_resume_at "$past")" -gt "$now" ] \
  && ok "a reset in the past is not obeyed either" || bad "a past timestamp was accepted"

echo "===== the guard's own thresholds still read the right fields ====="

rm -f "$CODEX_SESSIONS_DIR"/rollout-*.jsonl
usage_for '{"primary":{"used_percent":91.0,"window_minutes":10080,"resets_at":9999999999},"secondary":null,"plan_type":"plus"}' >/dev/null
week="$(jq -r '.seven_day.used_percentage // 0 | floor' "$SUPERVISOR_STATE_DIR/codex-usage.json")"
short="$(jq -r '.five_hour.used_percentage // 0 | floor' "$SUPERVISOR_STATE_DIR/codex-usage.json")"
[ "$week" -ge 80 ] && ok "the weekly guard can see weekly exhaustion ($week%)" \
                   || bad "weekly exhaustion invisible to the guard"
[ "$short" -eq 0 ] && ok "the short-window guard is not tricked into firing" \
                   || bad "the short-window guard would fire on weekly data"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
