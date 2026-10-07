#!/bin/bash
#
# Bulava's browser, from the run's side: who has it, and letting go of it.
#
# The `accounts` browser is the one he signed in to — consoles, analytics, stores. It is lent to one
# run at a time; another run asking meanwhile is turned away at once (chrome-devtools-mcp then says
# "Could not connect to Chrome … 423"). Anything that needs no sign-in belongs in `browser`, the
# throwaway one every run has to itself.
#
# USAGE
#   browser status    # free | yours | busy (who has it, since when) | unavailable (why) | off
#   browser release   # done with it: the next run gets it now, not after your run goes quiet
#
#   Exit 3: Bulava is not running. Exit 1: it refused, and says why.
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
IDIR_SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="$SUP_STATE/browser-requests"
SERVICE="$SUP_STATE/browser/service.json"
TIMEOUT="${NS_BROWSER_TIMEOUT:-10}"
usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

op="${1:-}"
case "$op" in
  status|release) ;;
  ""|-h|--help|help) usage; [ -n "$op" ]; exit $? ;;
  *) echo "browser: невідома дія «${op}» (status або release)" >&2; exit 2 ;;
esac
token="$(jq -r '.token // empty' "$IDIR_SELF/browser.json" 2>/dev/null)"
if [ -z "$token" ]; then
  echo "browser: у цього прогону немає доступу до браузера Bulava (його вимкнено або Bulava не працювала, коли прогін стартував)." >&2
  exit 1
fi
svc_pid="$(jq -r '.pid // empty' "$SERVICE" 2>/dev/null)"
if [ -z "$svc_pid" ] || ! kill -0 "$svc_pid" 2>/dev/null; then
  echo "browser: додаток Bulava не запущений." >&2
  exit 3
fi

mkdir -p "$REQ_DIR" 2>/dev/null
id="$(date +%s)-$$-$RANDOM"
req="$REQ_DIR/$id.json"; done_file="$REQ_DIR/$id.done"
trap 'rm -f "$req" "$req.tmp" "$done_file"' EXIT
( umask 077; jq -n --arg op "$op" --arg token "$token" '{op:$op, token:$token}' > "$req.tmp" ) \
  && mv -f "$req.tmp" "$req" || { echo "browser: не вдалося записати запит у $REQ_DIR" >&2; exit 1; }
waited=0
while [ ! -f "$done_file" ]; do
  if [ "$waited" -ge $(( TIMEOUT * 10 )) ]; then
    echo "browser: Bulava не відповіла за ${TIMEOUT}с." >&2
    exit 4
  fi
  sleep 0.1; waited=$(( waited + 1 ))
done
if [ "$(jq -r '.ok' "$done_file" 2>/dev/null)" != true ]; then
  echo "browser: $(jq -r '.error // "Bulava відмовила."' "$done_file" 2>/dev/null)" >&2
  exit 1
fi
case "$op" in
  release)
    if [ "$(jq -r '.released' "$done_file")" = true ]; then echo "released"; else echo "not yours — nothing to release"; fi ;;
  status)
    jq -r '
      (.state) as $s
      | if $s == "busy" then "busy: \(.holder) has it since \(.since | strflocaltime("%H:%M")) — work on what does not need it, or try later"
        elif $s == "yours" then "yours"
        elif $s == "free" then "free"
        elif $s == "unavailable" then "unavailable: \(.reason)"
        else "off" end,
        (if (.sites // []) | length > 0 then "sites: " + ((.sites | map(.host + (if .withoutMe then "" else " (only with him)" end))) | join(", ")) else empty end)' "$done_file" ;;
esac
