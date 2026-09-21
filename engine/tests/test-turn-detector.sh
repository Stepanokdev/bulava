#!/bin/bash
# A worker sitting at its prompt must read as idle.
#
# The detector matched any mention of tokens, and Claude Code shows "new task? /clear to save 231.4k
# tokens" on a long session — while idle. So from the moment a session grew big enough to show that
# hint, every injection failed: the director's answer to a worker's question was reported as
# delivered-to-the-session and never arrived.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

idle_pane='
✻ Churned for 2h 8m 50s
                                         new task? /clear to save 231.4k tokens
────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents'

busy_pane='
✻ Churning… (12s · ↑ 1.4k tokens · esc to interrupt)
────────────────────────────────────────────────────────────────────────────────
❯'

echo "===== an idle worker with a big session is idle ====="
if _pane_says_turn_running "$idle_pane"; then bad "the token hint still reads as a running turn"
else ok "the '231.4k tokens' hint no longer means busy"; fi

echo
echo "===== a working one is still busy ====="
if _pane_says_turn_running "$busy_pane"; then ok "'esc to interrupt' reads as a running turn"
else bad "a running turn now reads as idle — we would type into a busy head"; fi

echo
echo "===== and the elapsed-time summary of a FINISHED turn is not a turn ====="
if _pane_says_turn_running '✻ Churned for 2h 8m 50s'; then bad "a finished turn's summary reads as running"
else ok "a finished turn's summary is not mistaken for one"; fi

echo
[ "$fails" = 0 ] && echo "✅ turn detector: idle is idle" || echo "❌ turn detector: $fails problem(s)"
exit "$fails"
