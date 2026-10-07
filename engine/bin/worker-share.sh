#!/bin/bash
#
# Show something on the director's phone — through Bulava, which serves it on the home Wi-Fi.
#
# A site, a page, a note or a file made for him sat on the Mac's disk, and the phone in his hand
# could not open it: a path in a chat is only text there. Bulava keeps one small server for every
# project; this asks it to share one thing and prints the link. Nothing leaves the local network,
# and a link opens only the thing it was made for.
#
# USAGE
#   phone-link <file-or-folder> [--title "Назва"]
#
#   A folder must have an index.html: a site opens with everything in its folder. A page opens with
#   the folder it sits in; anything else (a note, a PDF, a picture, a video) opens alone, and a note
#   (.md) opens as a page. It must be inside this run's project, not hidden, and not the whole
#   project folder — put results in a folder of their own, such as artifacts/.
#
#   Prints the links, one per line: the Mac's Bonjour name first (it survives a new address from
#   the router), then its current addresses. Put the first in your answer.
#
#   Exit 3: Bulava is not running, so nobody can share it. Exit 1: Bulava refused, and says why.
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
# Called as $IDIR/phone-link: the run's own folder says which project it is.
IDIR_SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="$SUP_STATE/share-requests"
SERVICE="$REQ_DIR/service.json"
TIMEOUT="${NS_SHARE_TIMEOUT:-20}"
usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

target="${1:-}"
case "$target" in ""|-h|--help|help) usage; [ -n "$target" ]; exit $? ;; esac
shift
title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title="${2:-}"; shift 2 || shift ;;
    *) echo "phone-link: невідомий аргумент «$1»" >&2; exit 2 ;;
  esac
done
case "$target" in /*) ;; *) target="$(pwd -P)/$target" ;; esac
project="$(cat "$IDIR_SELF/project" 2>/dev/null || true)"
[ -n "$project" ] || project="$(pwd -P)"

if [ ! -f "$SERVICE" ]; then
  echo "phone-link: додаток Bulava не запущений — показати на телефоні нікому." >&2
  exit 3
fi
svc_pid="$(jq -r '.pid // empty' "$SERVICE" 2>/dev/null)"
if [ -n "$svc_pid" ] && ! kill -0 "$svc_pid" 2>/dev/null; then
  echo "phone-link: Bulava більше не працює (pid $svc_pid) — показати на телефоні нікому." >&2
  exit 3
fi
# Not `.enabled // true`: jq's `//` takes false for missing, and a switched-off share read as on.
if [ "$(jq -r 'if .enabled == false then "off" else "on" end' "$SERVICE" 2>/dev/null)" = off ]; then
  echo "phone-link: посилання для телефона вимкнені в налаштуваннях Bulava." >&2
  exit 1
fi

id="$(date +%s)-$$-$RANDOM"
req="$REQ_DIR/$id.json"; done_file="$REQ_DIR/$id.done"
trap 'rm -f "$req" "$req.tmp" "$done_file"' EXIT
jq -n --arg path "$target" --arg project "$project" --arg title "$title" \
  '{path:$path, project:$project} + (if $title == "" then {} else {title:$title} end)' > "$req.tmp" \
  && mv -f "$req.tmp" "$req" || { echo "phone-link: не вдалося записати запит у $REQ_DIR" >&2; exit 1; }

waited=0
while [ ! -f "$done_file" ]; do
  if [ "$waited" -ge $(( TIMEOUT * 10 )) ]; then
    echo "phone-link: Bulava не відповіла за ${TIMEOUT}с." >&2
    exit 4
  fi
  sleep 0.1; waited=$(( waited + 1 ))
done
if [ "$(jq -r '.ok' "$done_file" 2>/dev/null)" != true ]; then
  echo "phone-link: $(jq -r '.error // "Bulava відмовила."' "$done_file" 2>/dev/null)" >&2
  exit 1
fi
jq -r '.urls[]' "$done_file"
