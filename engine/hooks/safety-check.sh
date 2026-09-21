#!/bin/bash
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$HOOK_DIR/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
LOG="$SUP_STATE/supervisor.log"
STALE_HOURS=$SUPERVISOR_STALE_DISABLE_HOURS   # config.sh; distinct from watchdog idle-kill
now=$(date +%s)
disabled=""

hs_input="$(perl -e 'alarm 2; local $/; print <STDIN>' 2>/dev/null || true)"
if [ -n "${ORCHESTRATOR_RUN_ID:-}" ] && [ -n "$hs_input" ]; then
  hs_cwd="$(echo "$hs_input" | jq -r '.cwd // ""' 2>/dev/null || echo "")"
  hs_slug="$(active_instance_for_cwd "$hs_cwd")"
  if [ -n "$hs_slug" ] && [ "$(cat "$(instance_dir "$hs_slug")/run-id" 2>/dev/null)" = "$ORCHESTRATOR_RUN_ID" ]; then
    : > "$(instance_dir "$hs_slug")/handshake-ok"
    hs_sid="$(echo "$hs_input" | jq -r '.session_id // ""' 2>/dev/null || echo "")"
    if [ -n "$hs_sid" ]; then
      printf '%s' "$hs_sid" > "$(instance_dir "$hs_slug")/claude-session-id"
    fi
  fi
fi

age_h() { local f="$1" m; m=$(stat -f %m "$f" 2>/dev/null || echo "$now"); echo $(( (now - m) / 3600 )); }

if [ -d "$SUP_INSTANCES" ]; then
  for d in "$SUP_INSTANCES"/*/; do
    [ -f "$d/started-at" ] || continue
    marker="$d/last-activity"; [ -f "$marker" ] || marker="$d/started-at"
    if [ "$(age_h "$marker")" -ge "$STALE_HOURS" ]; then
      [ -f "$d/watchdog.pid" ] && kill "$(cat "$d/watchdog.pid")" 2>/dev/null
      proj="$(cat "$d/project" 2>/dev/null)"
      rm -rf "$d"
      disabled="$disabled $proj"
      echo "$(date '+%F %T') [safety] stale instance auto-disabled: $proj" >> "$LOG"
    fi
  done
fi

if [ -f "$SUP_STATE/night-mode" ] && ! _any_instance; then
  if [ "$(age_h "$SUP_STATE/night-mode")" -ge "$STALE_HOURS" ]; then
    [ -f "$SUP_STATE/watchdog.pid" ] && { kill "$(cat "$SUP_STATE/watchdog.pid")" 2>/dev/null; rm -f "$SUP_STATE/watchdog.pid"; }
    rm -f "$SUP_STATE/night-mode"
    disabled="$disabled (legacy)"
    echo "$(date '+%F %T') [safety] stale legacy night-mode auto-disabled" >> "$LOG"
  fi
fi

if ! _any_instance && [ ! -f "$SUP_STATE/night-project" ] && [ ! -f "$SUP_STATE/night-branch" ] && [ ! -f "$SUP_STATE/watchdog.pid" ]; then
  rm -f "$SUP_STATE/night-mode"
fi

if [ -n "$disabled" ]; then
  echo '{"systemMessage":"🌙→☀️ Залежалий нічний режим автоматично вимкнено для:'"$disabled"'. Питання знову доходять до тебе. Запустити: night-shift start"}'
fi
exit 0
