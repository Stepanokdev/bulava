#!/bin/bash
# What Codex has left of its windows — asked of Codex itself.
#
# This used to be scraped out of the newest rollout in ~/.codex/sessions: `tail -c 200000` piped
# into a jq that picked up whatever object carried `rate_limits`. Two things were wrong with it,
# and the second one killed it outright.
#
# It reported the limits as of the last time Codex happened to answer a prompt, not as of now. And
# a BYTE tail cuts a line in half — survivable while session lines were small, fatal once they
# were not. A single line in a current rollout runs to 1.8 MB (tool output, world state), so the
# fragment at the top of the tail is invalid JSON, jq exits on it before emitting anything, and
# every reading came back `unknown`. The left panel simply stopped showing Codex at all.
#
# So the CLI is asked directly. `codex app-server --stdio` answers `account/rateLimits/read` with
# the live windows — no model call, no thread, nothing spent. The session scan stays as a fallback
# for a CLI too old to have that method, and it reads WHOLE LINES now.
set -u

STATE_DIR="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
OUT="$STATE_DIR/codex-usage.json"
mkdir -p "$STATE_DIR"

SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
CODEX_BIN="${SUPERVISOR_CODEX_BIN:-codex}"
RPC_TIMEOUT="${NS_CODEX_RPC_TIMEOUT:-12}"
RPC_PATIENCE="${NS_CODEX_RPC_PATIENCE:-60}"   # tenths of a second to wait for the answer
SESSION_DAYS="${NS_CODEX_SESSION_DAYS:-3}"

with_timeout() { local to="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$to" "$@"; }

unknown() {
  jq -nc --argjson ts "$(date +%s)" --arg why "$1" '{ts:$ts, unknown:true, reason:$why}' > "$OUT"
  cat "$OUT"
  exit 0
}

# MARK: the two sources, both normalised to one shape

# Ask the CLI. Its fields are camelCase and its windows are named the same way the session
# payloads name them, so the answer is translated here and classified in one place below.
ask_cli() {
  command -v "$CODEX_BIN" >/dev/null 2>&1 || return 1
  local work fifo out srv waited
  work="$(mktemp -d)" || return 1
  fifo="$work/ask"; out="$work/answered"
  mkfifo "$fifo" 2>/dev/null || { rm -rf "$work"; return 1; }

  # Stdin is held open on purpose, and closed the moment the answer is in hand.
  #
  # Handing the requests over as a plain file does not work: stdin is then already at EOF and the
  # server shuts down before the rate-limit read comes back from the network — it answers
  # `initialize` and quits. Holding the pipe open with a `sleep` instead leaves that sleep and the
  # server itself running until some timeout expires, once a minute, forever. So our end of the
  # pipe is a file descriptor we close ourselves: the server sees EOF and exits as soon as we have
  # what we asked for, and `wait` collects it.
  with_timeout "$RPC_TIMEOUT" "$CODEX_BIN" app-server --stdio < "$fifo" > "$out" 2>/dev/null &
  srv=$!
  exec 9>"$fifo"
  # In a subshell: a CLI with no `app-server` at all exits at once, and writing to a pipe with
  # nobody on the other end raises SIGPIPE — which, from the script's own shell, would kill the
  # script rather than fall through to the session fallback.
  (
    printf '%s\n' \
      '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"bulava-usage","version":"1"}}}' \
      '{"method":"initialized","params":{}}' \
      '{"id":2,"method":"account/rateLimits/read"}' >&9
  ) 2>/dev/null || true

  waited=0
  while [ "$waited" -lt "$RPC_PATIENCE" ] && ! grep -q '"id":2' "$out" 2>/dev/null; do
    # A server that has already gone is not going to answer: waiting out the full patience on a
    # CLI that has no such method would make every reading six seconds late for nothing. What it
    # managed to write before exiting is still read below.
    kill -0 "$srv" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  exec 9>&-
  wait "$srv" 2>/dev/null

  grep -m1 '"id":2' "$out" 2>/dev/null \
    | jq -c '
        (.result.rateLimitsByLimitId.codex // .result.rateLimits) as $r
        | select($r != null)
        | { plan_type: ($r.planType // null),
            primary:   ($r.primary   | if . == null then null else
                          { used_percent: .usedPercent, resets_at: .resetsAt,
                            window_minutes: .windowDurationMins } end),
            secondary: ($r.secondary | if . == null then null else
                          { used_percent: .usedPercent, resets_at: .resetsAt,
                            window_minutes: .windowDurationMins } end) }' 2>/dev/null
  rm -rf "$work"
}

# Read the freshest reading Codex left behind in its own logs.
#
# Whole lines, parsed one at a time: a fragment — or a megabyte of tool output — must not take the
# rest of the file with it, which is exactly what the byte tail did. Several files are searched
# because the newest session is not necessarily the one that carries a reading, and the winner is
# the latest by the line's own timestamp rather than by file order.
ask_sessions() {
  local files
  files="$(find "$SESSIONS_DIR" -name '*.jsonl' -mtime -"$SESSION_DAYS" 2>/dev/null \
           | xargs ls -t 2>/dev/null | head -8)"
  [ -n "$files" ] || return 1
  # shellcheck disable=SC2086  # the list is newline-separated paths from find
  grep -a -h -F '"rate_limits"' $files 2>/dev/null \
    | jq -Rc 'fromjson? // empty
              | . as $line
              | (.. | objects | select(has("rate_limits")) | .rate_limits | select(. != null))
              | {t: ($line.timestamp // ""), r: .}' 2>/dev/null \
    | jq -sc 'if length == 0 then empty else (max_by(.t) | .) end' 2>/dev/null \
    | jq -c '
        # Codex stamps these with milliseconds — "2026-09-10T10:01:00.000Z" — which
        # `fromdateiso8601` will not parse. It returned null, and null then fell through to "now",
        # so a reading scraped out of a log written hours ago was recorded as a current
        # observation. That is the one direction this must never fail in: an unreadable
        # observation time becomes 0, which reads as ancient, not as fresh.
        def seen: if type == "string" and . != ""
                  then ((sub("\\.[0-9]+(?=Z|[+-])"; "")) | (try fromdateiso8601 catch 0))
                  else 0 end;
        {plan_type: (.r.plan_type // null), primary: .r.primary, secondary: .r.secondary,
         observed_at: (.t | seen)}' 2>/dev/null
}

# MARK: which window is which

# Classify by WINDOW LENGTH, not by position.
#
# `primary` used to be the five-hour window and `secondary` the weekly one. Codex has since sent a
# single window with window_minutes 10080 as `primary` and nothing as `secondary` — so the WEEKLY
# reset landed in five_hour.resets_at, a timestamp days away. The review gate reads that field to
# decide how long to pause a run and parked one until the following Saturday: the work sat
# "paused", nothing happened, and the night looked like it had simply done nothing.
#
# window_minutes is missing in older payloads, so fall back to what the positions used to mean.
#
# `ts` and `observed_at` are two different facts and conflating them is how a stale reading passed
# for a current one. `ts` is when this file was written; `observed_at` is when Codex actually
# measured the numbers inside it. For the CLI they are the same instant. For the session fallback
# they are not — the reading is scraped out of a log line that may be hours old — and a reader
# deciding whether an engine is FREE has to go by the second one.
classify() {  # $1 = which source answered
  jq -c --argjson ts "$(date +%s)" --arg src "$1" '
      [ (.primary   | select(. != null) | . + {_w: (.window_minutes // 300)}),
        (.secondary | select(. != null) | . + {_w: (.window_minutes // 10080)}) ] as $wins
      | ($wins | map(select(._w <= 360))  | first) as $short
      | ($wins | map(select(._w >  360))  | first) as $long
      | {
          ts: $ts,
          observed_at: (.observed_at // $ts),
          source: $src,
          plan: (.plan_type // null),
          five_hour: { used_percentage: ($short.used_percent // 0), resets_at: ($short.resets_at // 0),
                       window_minutes: ($short._w // 0) },
          seven_day: { used_percentage: ($long.used_percent  // 0), resets_at: ($long.resets_at  // 0),
                       window_minutes: ($long._w  // 0) }
        }'
}

# MARK: the reading

source_name="cli"
reading="$(ask_cli || true)"
if [ -z "${reading:-}" ]; then
  source_name="session"
  reading="$(ask_sessions || true)"
fi
[ -n "${reading:-}" ] || unknown "codex did not report any rate limits"

printf '%s' "$reading" | classify "$source_name" > "$OUT.tmp" 2>/dev/null

# A reading is real when EITHER window has a length. Demanding the five-hour one rejected the
# shape Codex actually sends when it reports a single weekly window — a valid reading that would
# then have been recorded as "unknown".
if [ -s "$OUT.tmp" ] \
   && jq -e '(.five_hour.window_minutes > 0) or (.seven_day.window_minutes > 0)' "$OUT.tmp" >/dev/null 2>&1; then
  mv "$OUT.tmp" "$OUT"
else
  rm -f "$OUT.tmp"
  unknown "rate limits arrived in a shape this build does not know"
fi
cat "$OUT" 2>/dev/null || echo '{}'
