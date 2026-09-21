#!/bin/bash
set -u
STATE_DIR="$HOME/.claude/supervisor"
mkdir -p "$STATE_DIR"

input=$(cat)

echo "$input" | jq -c '{
  ts: now | floor,
  session_id: .session_id,
  cwd: (.cwd // .workspace.current_dir // ""),
  five_hour: (.rate_limits.five_hour // null),
  seven_day: (.rate_limits.seven_day // null)
}' > "$STATE_DIR/usage.json.tmp" 2>/dev/null && mv "$STATE_DIR/usage.json.tmp" "$STATE_DIR/usage.json"

MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""' | sed "s|^$HOME|~|")

FIVE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

LIMITS=""
if [ -n "$FIVE" ]; then
  RESET_HUMAN=""
  if [ -n "$FIVE_RESET" ]; then
    RESET_HUMAN=$(date -r "$FIVE_RESET" +%H:%M 2>/dev/null || true)
  fi
  LIMITS=" | 5h: ${FIVE%.*}%${RESET_HUMAN:+ (reset $RESET_HUMAN)}"
  [ -n "$WEEK" ] && LIMITS="$LIMITS | 7d: ${WEEK%.*}%"
fi

CODEX=""
if [ -f "$STATE_DIR/codex-usage.json" ]; then
  CX=$(jq -r '.five_hour.used_percentage // empty | floor' "$STATE_DIR/codex-usage.json" 2>/dev/null)
  [ -n "$CX" ] && CODEX=" | Cx: ${CX}%"
fi

NIGHT=""
[ -f "$STATE_DIR/night-mode" ] && NIGHT=" | 🌙 night shift"

echo "[$MODEL] $DIR$LIMITS$CODEX$NIGHT"
