#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"

OUT="${1:?usage: capture <out.png> [x,y,w,h | --window <pid>]}"; shift || true
REGION=""; WPID=""
case "${1:-}" in
  --window) WPID="${2:?--window needs a pid}" ;;
  ?*)       REGION="$1" ;;
esac

REQ_DIR="$SUP_STATE/capture-requests"
mkdir -p "$REQ_DIR" 2>/dev/null || true
SERVICE="$REQ_DIR/service.json"

if [ ! -f "$SERVICE" ]; then
  echo "capture: додаток Bulava не запущений — знімок зробити нікому. Заглушку не створюю." >&2
  exit 3
fi
svc_pid="$(jq -r '.pid // empty' "$SERVICE" 2>/dev/null)"
if [ -n "$svc_pid" ] && ! kill -0 "$svc_pid" 2>/dev/null; then
  echo "capture: Bulava більше не працює (pid $svc_pid) — знімок зробити нікому." >&2
  exit 3
fi

ID="cap-$$-$(date +%s)"
REQ="$REQ_DIR/$ID.json"
DONE="$REQ_DIR/$ID.done"
rm -f "$OUT" "$DONE" 2>/dev/null

jq -nc --arg out "$OUT" --arg region "$REGION" --argjson wpid "${WPID:-null}" \
  '{out:$out, region:(if $region == "" then null else $region end), window_pid:$wpid}' \
  > "$REQ.tmp" 2>/dev/null && mv -f "$REQ.tmp" "$REQ" || {
    echo "capture: не змогли записати запит у $REQ_DIR" >&2; exit 1; }

for _ in $(seq 1 40); do
  if [ -f "$DONE" ]; then
    if [ "$(jq -r '.ok // false' "$DONE" 2>/dev/null)" = "true" ] && [ -s "$OUT" ]; then
      rm -f "$REQ" "$DONE" 2>/dev/null
      printf '%s\n' "$OUT"; exit 0
    fi
    why="$(jq -r '.error // "невідома причина"' "$DONE" 2>/dev/null)"
    rm -f "$REQ" "$DONE" 2>/dev/null
    echo "capture: $why" >&2; exit 1
  fi
  sleep 0.5
done
rm -f "$REQ" 2>/dev/null
echo "capture: Bulava не відповіла за 20 с — знімка немає." >&2
exit 1
