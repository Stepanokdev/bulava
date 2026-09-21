#!/bin/bash
# A reading we do not have must not read as "nothing used".
#
# `codex-usage.sh` asks the CLI for the rate limits (`codex app-server --stdio`,
# `account/rateLimits/read`) and falls back to Codex's own session logs when that method is not
# there. Both routes have broken before — once when Codex renamed which window it calls primary,
# once when session lines grew past the byte tail the old reader took.
#
# When it breaks, the file it leaves behind used to be `{}` — and every reader took
# `.five_hour.used_percentage // 0`, which is 0, which means "full quota". So a failed scrape
# reported the most permissive possible answer, silently, and the guard that exists to stop work
# before a window runs out simply never engaged.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"

# These cases are about what happens when there is NO reading to be had, so the CLI must not be
# the real one — on this machine it answers, and the test would then be reading his actual quota
# instead of its own fixtures.
cat > "$TMP/codex-silent" <<'STUB'
#!/bin/bash
# Exits at once without draining stdin, the way a CLI that has no `app-server` would.
exit 1
STUB
chmod +x "$TMP/codex-silent"
export SUPERVISOR_CODEX_BIN="$TMP/codex-silent"

echo "===== no session at all ====="
CODEX_SESSIONS_DIR="$TMP/empty" bash "$ROOT/bin/codex-usage.sh" >/dev/null 2>&1
out="$TMP/state/codex-usage.json"
jq -e '.unknown == true' "$out" >/dev/null 2>&1 \
  && ok "the reading says it is unknown" || bad "wrote: $(cat "$out")"
jq -e 'has("five_hour") | not' "$out" >/dev/null 2>&1 \
  && ok "and invents no window it never read" || bad "invented a window"
[ "$(jq -r '.five_hour.used_percentage // 0' "$out")" = "0" ] \
  && ok "a naive reader still gets 0 — which is why readers must check .unknown" \
  || bad "unexpected"

echo "===== a session with no rate limits in it ====="
mkdir -p "$TMP/sessions"
printf '{"type":"event_msg","payload":{"nothing":"here"}}\n' > "$TMP/sessions/rollout.jsonl"
CODEX_SESSIONS_DIR="$TMP/sessions" bash "$ROOT/bin/codex-usage.sh" >/dev/null 2>&1
jq -e '.unknown == true' "$out" >/dev/null 2>&1 \
  && ok "an unparseable tail is unknown, not zero" || bad "wrote: $(cat "$out")"

echo "===== a real reading is still a reading ====="
cat > "$TMP/sessions/rollout.jsonl" <<'J'
{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":42.0,"resets_at":1788200000,"window_minutes":300},"secondary":{"used_percent":7.0,"resets_at":1788700000,"window_minutes":10080}}}}
J
CODEX_SESSIONS_DIR="$TMP/sessions" bash "$ROOT/bin/codex-usage.sh" >/dev/null 2>&1
jq -e '.unknown != true and .five_hour.used_percentage == 42' "$out" >/dev/null 2>&1 \
  && ok "the five-hour window is read" || bad "read: $(jq -c '.five_hour' "$out")"
jq -e '.seven_day.used_percentage == 7' "$out" >/dev/null 2>&1 \
  && ok "and the weekly one is not mistaken for it" || bad "read: $(jq -c '.seven_day' "$out")"
# The bug this classification exists for: a single window reported as `primary` with a WEEKLY
# length used to land in five_hour, and the gate paused a run until the following Saturday.
cat > "$TMP/sessions/rollout.jsonl" <<'J'
{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":88.0,"resets_at":1788700000,"window_minutes":10080}}}}
J
CODEX_SESSIONS_DIR="$TMP/sessions" bash "$ROOT/bin/codex-usage.sh" >/dev/null 2>&1
jq -e '.seven_day.used_percentage == 88' "$out" >/dev/null 2>&1 \
  && ok "a weekly window stays weekly however it is labelled" \
  || bad "weekly landed elsewhere: $(jq -c '{five_hour, seven_day}' "$out")"

echo "===== and the question hook does not hold on a reading it lacks ====="
hook="$(cat "$ROOT/hooks/answer-question.sh")"
case "$hook" in *'codex usage unknown'*) ok "it says so in the log rather than acting on a fabricated 0" ;;
  *) bad "an unknown reading is still silently treated as 0%" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ an unknown reading is unknown, not full quota"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
