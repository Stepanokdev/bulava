#!/bin/bash
# A position that is missing has a reason, and the reader is entitled to it.
#
# The brief said "No position from Claude — the work goes on with Codex's position." and stopped there, so the
# director asked the only question that sentence leaves: is this a glitch, or is the position there
# and simply not shown? Neither. The call had timed out, or crashed, or returned nothing — and the
# only path that wrote down a reason was the one for a spent usage window. Every other way a peer
# can fail wrote nothing at all.
#
# Model calls are stubbed. The stage, the files and the timing are real.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$TMP/state" "$TMP/project" "$TMP/stub"
export SUPERVISOR_STATE_DIR="$TMP/state"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
. "$BIN/supervisor-lib.sh"
IDIR="$(instance_dir "$(slug_for "$TMP/project")")"
mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$TMP/project")" > "$IDIR/project"
: > "$IDIR/started-at"

cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0,"window_minutes":300}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
EOF
chmod +x "$TMP/stub/usage"
export SUPERVISOR_CLAUDE_USAGE_CMD="$TMP/stub/usage" SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage"

# One peer call, with claude behaving however the case needs.
peer_run() {   # $1 = script body for the claude stub, $2 = plan timeout
  rm -f "$IDIR/peer-claude.unavailable" "$IDIR/peer-claude.md" "$IDIR/degraded.md" 2>/dev/null
  printf '#!/bin/bash\n%s\n' "$1" > "$TMP/stub/claude"
  chmod +x "$TMP/stub/claude"
  printf 'read this and say what you think\n' > "$IDIR/peer-prompt.txt"
  PATH="$TMP/stub:$PATH" SUPERVISOR_PEER_IDLE_TIMEOUT="$2" SUPERVISOR_PEER_POLL=1 \
    bash "$BIN/preflight.sh" --art "$IDIR" --stage peer --engine claude \
      "$TMP/project" "задача" >/dev/null 2>&1
}
reason() { cat "$IDIR/peer-claude.unavailable" 2>/dev/null; }

echo "===== a call that keeps working is not cut, however long it takes ====="
# The whole point. It used to be a fixed 360 seconds around a silent command, so a position that
# needed 361 was lost with nothing to show for it. Here the silence budget is three seconds and the
# call runs for five times that — because it keeps saying something.
STREAM_LOG="$TMP/stream.log"
: > "$STREAM_LOG"
peer_run 'for i in $(seq 1 15); do printf "{\"type\":\"stream_event\",\"i\":%s}\n" "$i"; sleep 1; done
printf "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"REAL GOAL — thought about it for a while\"}\n"' 3
if [ -s "$IDIR/peer-claude.md" ]; then
  ok "a call five times longer than its silence budget still delivered"
  grep -q "thought about it for a while" "$IDIR/peer-claude.md" \
    && ok "and the position is the answer, not the transcript" \
    || bad "the position is not what the model said: $(head -c 80 "$IDIR/peer-claude.md")"
  grep -q '"type"' "$IDIR/peer-claude.md" \
    && bad "the event stream leaked into the position" \
    || ok "no event stream in it"
else
  bad "a call that was working the whole time produced nothing: $(reason)"
fi
[ -e "$IDIR/peer-claude.unavailable" ] && bad "a working call was recorded as unavailable: $(reason)" \
                                       || ok "and nothing was written down against it"

echo
echo "===== a call that goes quiet is stopped, and the reason says so ====="
peer_run 'sleep 30' 3
if [ -s "$IDIR/peer-claude.unavailable" ]; then
  case "$(reason)" in
    *"замовк на"*) ok "silence is named as silence: $(reason)" ;;
    *"не встиг"*) bad "still reported as a fixed-time timeout: $(reason)" ;;
    *) bad "no usable reason for a silent call: $(reason)" ;;
  esac
else
  bad "a peer that went quiet left no reason at all"
fi

echo
echo "===== a call that crashed says that instead ====="
peer_run 'echo "boom" >&2; exit 3' 30
case "$(reason)" in
  *"код 3"*) ok "the exit code is in the reason: $(reason)" ;;
  *"не встиг"*) bad "a crash was reported as a timeout: $(reason)" ;;
  *) bad "no usable reason for a crash: $(reason)" ;;
esac

echo
echo "===== a call that said nothing is not the same as a call that failed ====="
peer_run 'exit 0' 30
case "$(reason)" in
  *"не сказав нічого"*) ok "an empty answer is named: $(reason)" ;;
  *) bad "returning nothing was not distinguished: $(reason)" ;;
esac

echo
echo "===== half a position is not a position, and the reader is told ====="
peer_run 'echo "REAL GOAL — half a thoug"; exit 3' 30
case "$(reason)" in
  *"неповну відповідь відкинуто"*) ok "the discarded partial output is mentioned: $(reason)" ;;
  *) bad "a truncated position was discarded silently: $(reason)" ;;
esac
[ -s "$IDIR/peer-claude.md" ] && bad "the truncated position was kept as a position" \
                             || ok "and it is not left behind as one"

echo
echo "===== the brief carries the reason, not just the absence ====="
printf 'RECOMMENDATION — ship it\n' > "$IDIR/peer-codex.md"
peer_run 'sleep 30' 3
PATH="$TMP/stub:$PATH" bash "$BIN/preflight.sh" --art "$IDIR" --stage align \
  "$TMP/project" "задача" >/dev/null 2>&1
if grep -q "Позиції Claude немає" "$IDIR/degraded.md" 2>/dev/null; then
  if grep -qE "Позиції Claude немає \(.+\)" "$IDIR/degraded.md"; then
    ok "the worker is told why: $(head -1 "$IDIR/degraded.md")"
  else
    bad "still the bare sentence the director asked about: $(head -1 "$IDIR/degraded.md")"
  fi
else
  bad "no degraded brief was written: $(head -1 "$IDIR/degraded.md" 2>/dev/null)"
fi
rm -f "$IDIR/peer-codex.md"

echo "===== a spent window and a failed call do not get the same sentence ====="
# They are different facts and they call for different answers: one comes back when the window
# reopens, the other is a call that has to be made again. Telling them apart is the whole reason
# the file carries a sentence rather than a flag.
timeout_reason="$(reason)"
cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
now=$(date +%s)
printf '{"ts":%s,"observed_at":%s,"five_hour":{"used_percentage":100,"resets_at":%s,"window_minutes":300},"seven_day":{"used_percentage":20,"resets_at":%s,"window_minutes":10080}}\n' \
  "$now" "$now" "$((now + 3600))" "$((now + 500000))" > "$SUPERVISOR_STATE_DIR/usage.json"
EOF
chmod +x "$TMP/stub/usage"
"$TMP/stub/usage"
peer_run 'echo "should never be called"' 30
case "$(reason)" in
  *"вичерпано вікно"*) ok "a spent window says so: $(reason)" ;;
  *) bad "the quota reason was lost: $(reason)" ;;
esac
[ "$(reason)" = "$timeout_reason" ] \
  && bad "a spent window and a timeout produce the same sentence" \
  || ok "and it is not the sentence a timeout produces"
rm -f "$SUPERVISOR_STATE_DIR/usage.json"

echo "===== Codex gets the budget its own stream needs ====="
# Measured, not assumed: Codex emits four events for a whole turn and nothing while it reasons, so
# one number for both engines would either cut Codex mid-thought or leave a hung Claude for a
# quarter of an hour. A Codex call that is quiet for longer than Claude's budget must survive.
codex_run() {   # $1 = stub body, $2 = claude's budget, $3 = codex's budget
  rm -f "$IDIR/peer-codex.unavailable" "$IDIR/peer-codex.md" 2>/dev/null
  # The login probe is not a turn, and the bodies below all answer as if it were one.
  printf '#!/bin/bash\nif [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi\n%s\n' \
    "$1" > "$TMP/stub/codex"
  chmod +x "$TMP/stub/codex"
  printf 'read this\n' > "$IDIR/peer-prompt.txt"
  PATH="$TMP/stub:$PATH" SUPERVISOR_PEER_IDLE_TIMEOUT="$2" SUPERVISOR_PEER_IDLE_TIMEOUT_CODEX="$3" \
    SUPERVISOR_PEER_POLL=1 bash "$BIN/preflight.sh" --art "$IDIR" --stage peer --engine codex \
      "$TMP/project" "задача" >/dev/null 2>&1
}
# Quiet for six seconds: past Claude's two, inside Codex's twenty.
codex_run 'out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
sleep 6
[ -n "$out" ] && printf "RECOMMENDATION — took a while to think\n" > "$out"
printf "{\"type\":\"turn.completed\"}\n"' 2 20
if [ -s "$IDIR/peer-codex.md" ]; then
  ok "a quiet Codex turn is not cut by Claude's budget"
else
  bad "Codex was stopped on Claude's budget: $(cat "$IDIR/peer-codex.unavailable" 2>/dev/null)"
fi

echo
echo "===== and a position that arrives clears what the last attempt said ====="
printf 'claude не встиг сформувати позицію за 2с\n' > "$IDIR/peer-claude.unavailable"
peer_run 'echo "REAL GOAL — done
APPROACH — direct
PROOF — test"' 30
[ -s "$IDIR/peer-claude.md" ] && ok "the position arrived" \
                             || bad "the successful call produced nothing"
[ -e "$IDIR/peer-claude.unavailable" ] \
  && bad "a stale reason outlived the answer that disproved it: $(reason)" \
  || ok "and the old reason is gone"

echo
[ "$fails" = 0 ] && echo "✅ a missing position always says why" || echo "❌ $fails problem(s)"
exit "$fails"
