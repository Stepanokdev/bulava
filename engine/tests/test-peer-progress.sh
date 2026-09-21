#!/bin/bash
# While two engineers read a message, the app has to be able to say so — and say it about the
# engineer that is actually still reading.
#
# The chat had one sentence for the whole of preparation, and it read the same after two seconds as
# after two minutes, and the same again when the pipeline behind it had died. A user asked whether a
# simple question had hung. Nothing in the instance let the app answer that, so this publishes it:
# a peer says when it started while it runs, takes it back when it stops, and Codex's finished
# reading is left where the chat can show it.
#
# Model calls are stubbed. The pipeline, the files and the timing are real.
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

# Codex that takes its time, so there is a "while it runs" to look at at all.
cat > "$TMP/stub/codex" <<'EOF'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
answer='RECOMMENDATION — publish after the detector is fixed
MISSED RISKS — installed copies lag the checkout
CONFIDENCE — high'
sleep 3
[ -n "$out" ] && printf '%s\n' "$answer" > "$out"
printf '%s\n' "$answer"
EOF
cat > "$TMP/stub/claude" <<'EOF'
#!/bin/bash
sleep 3
echo 'REAL GOAL — finished
APPROACH — direct
PROOF — test'
EOF
cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0,"window_minutes":300}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
EOF
chmod +x "$TMP/stub/codex" "$TMP/stub/claude" "$TMP/stub/usage"

echo "===== a peer says when it started, while it is still reading ====="
# Left over from a preparation that was killed. A new one must not inherit it, or the app counts
# from a start time that belongs to nothing.
mkdir -p "$IDIR"
printf '{"started_at":1,"partial":"/nowhere"}\n' > "$IDIR/peer-claude.running"

PATH="$TMP/stub:$PATH" SUPERVISOR_DESIGN_RESEARCH=0 SUPERVISOR_PLAN_TIMEOUT=30 \
  bash "$BIN/preflight.sh" "$TMP/project" "Виправ опечатку" >/dev/null 2>&1 &
PF=$!

# The planted claim carries started_at:1, so "is this a real one" is a question about its contents
# rather than about the order two files happened to appear in.
claim_started() { jq -r '.started_at // 0' "$1" 2>/dev/null || echo 0; }
seen_codex=0; seen_claude=0; stale_cleared=0; started_at=0; partial=""
for _ in $(seq 1 200); do
  kill -0 "$PF" 2>/dev/null || break
  if [ ! -e "$IDIR/peer-claude.running" ] || [ "$(claim_started "$IDIR/peer-claude.running")" != 1 ]; then
    stale_cleared=1
  fi
  if [ -s "$IDIR/peer-codex.running" ] && [ "$seen_codex" = 0 ]; then
    seen_codex=1
    started_at="$(claim_started "$IDIR/peer-codex.running")"
    partial="$(jq -r '.partial // empty' "$IDIR/peer-codex.running" 2>/dev/null)"
  fi
  if [ -s "$IDIR/peer-claude.running" ] && [ "$(claim_started "$IDIR/peer-claude.running")" != 1 ]; then
    seen_claude=1
  fi
  sleep 0.2
done
wait "$PF" 2>/dev/null

[ "$stale_cleared" = 1 ] \
  && ok "a start time left by a dead preparation is cleared before this one begins" \
  || bad "the previous preparation's claim survived into this one"
[ "$seen_codex" = 1 ] \
  && ok "Codex publishes that it is reading, while it reads" \
  || bad "nothing said Codex was reading — the chat has nothing to count"
[ "$seen_claude" = 1 ] \
  && ok "and so does Claude" \
  || bad "Claude's reading is invisible"
if [ "${started_at:-0}" -gt "$(( $(date +%s) - 300 ))" ] 2>/dev/null; then
  ok "the start time is this run's, not an old one"
else
  bad "start time looks wrong: $started_at"
fi
case "$partial" in
  */.peer-codex.partial) ok "it names the file the answer is arriving in" ;;
  *) bad "no partial named, so the app cannot show how much has arrived: '$partial'" ;;
esac

echo
echo "===== and takes it back the moment it stops ====="
[ -e "$IDIR/peer-codex.running" ] \
  && bad "Codex still claims to be reading after it finished — the frozen header again" \
  || ok "nobody claims to be reading once the positions are in"
[ -e "$IDIR/peer-claude.running" ] \
  && bad "Claude still claims to be reading" \
  || ok "both claims are withdrawn"

echo
echo "===== Codex's reading is left where the chat can show it ====="
if [ -s "$IDIR/peer-codex.latest.md" ]; then
  ok "Codex's position is published to the instance"
  if cmp -s "$IDIR/peer-codex.md" "$IDIR/peer-codex.latest.md"; then
    ok "and it is the position itself, not a summary of it"
  else
    bad "what the chat would show is not what Codex wrote"
  fi
  grep -q "MISSED RISKS" "$IDIR/peer-codex.latest.md" \
    && ok "with Codex's own words in it" \
    || bad "the published position has lost its content"
else
  bad "Codex read the message and the reader still cannot see a word of it"
fi

echo
[ "$fails" = 0 ] && echo "✅ preparation says who is reading, and for how long" \
                 || echo "❌ $fails problem(s)"
exit "$fails"
