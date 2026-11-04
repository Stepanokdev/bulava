#!/bin/bash
#
# Put a frame or a clip in front of the reviewer: what the work looks like to a person.
#
# The review used to read the diff and nothing else, so a button pushed off the screen, text drawn
# over a picture and a model standing inside a wall all passed — the code was fine. The frames
# named here are attached to the reviewer's message, a clip as a few frames taken from it, and the
# caption tells it what it is looking at. Which contract item a frame proves is the caption's job:
# "1. неправильний пароль: помилка під полем, кнопка «Увійти» видна".
#
# USAGE
#   show-reviewer <frame.png|jpg|webp | clip.mp4|mov|webm> ["що на ньому"]
#   show-reviewer --list
#
#   The same file again replaces its caption. Up to 12 per request; a new request starts empty.
#   Frames are evidence the worker chose, and the reviewer is told so: show the hard cases, not
#   only the good angle.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"; . "$BIN_DIR/lib/pieces.sh"
usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

case "${1:-}" in ""|-h|--help) usage; [ -n "${1:-}" ]; exit $? ;; esac

# The run this process belongs to — the same lookup `add-check` makes.
scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" = instance ]; then
  IDIR="$(instance_dir "${scope#instance:}")"
elif [ ! -d "${IDIR:-}" ]; then
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ кадр НЕ записано — прогін $ORCHESTRATOR_RUN_ID більше не існує" >&2; exit 1
  fi
  IDIR="$(instance_dir "$(slug_for "$PWD")")"
fi
[ -d "$IDIR" ] || { echo "❌ нема теки прогону — запусти через night-shift" >&2; exit 1; }
FRAMES="$(review_frames_file "$IDIR")"

if [ "$1" = --list ]; then
  [ -s "$FRAMES" ] || { echo "рев'юеру ще нічого не показано"; exit 0; }
  jq -r '"\(.path)" + (if (.caption // "") != "" then " — \(.caption)" else "" end)' "$FRAMES"
  exit 0
fi

file="$1"; caption="${2:-}"
case "$file" in /*) ;; *) file="$PWD/$file" ;; esac
[ -f "$file" ] || { echo "❌ нема файлу: $file" >&2; exit 2; }
file="$(cd -P "$(dirname "$file")" && pwd)/$(basename "$file")"
ext="$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')"
case "$ext" in
  png|jpg|jpeg|webp) kind=image ;;
  mp4|mov|webm|m4v)  kind=video ;;
  *) echo "❌ показати можна кадр (png, jpg, webp) або кліп (mp4, mov, webm), а не .$ext" >&2; exit 2 ;;
esac
if [ "$kind" = video ] && ! command -v ffmpeg >/dev/null 2>&1; then
  echo "❌ кліп не покажу: нема ffmpeg, щоб узяти з нього кадри. Покажи кадри самі (png)." >&2; exit 2
fi

if [ -f "$FRAMES" ] && jq -e --arg p "$file" 'select(.path == $p)' "$FRAMES" >/dev/null 2>&1; then
  jq -c --arg p "$file" 'select(.path != $p)' "$FRAMES" > "$FRAMES.tmp.$$" && mv -f "$FRAMES.tmp.$$" "$FRAMES" \
    || { rm -f "$FRAMES.tmp.$$"; echo "❌ не зміг замінити попередній запис" >&2; exit 1; }
fi
if [ -f "$FRAMES" ] && [ "$(grep -c . "$FRAMES" 2>/dev/null || echo 0)" -ge 12 ]; then
  echo "❌ вже 12 — більше не додаю. Залиш ті, що доводять пункти контракту." >&2; exit 2
fi
jq -nc --arg p "$file" --arg c "$caption" --arg k "$kind" --arg ts "$(date '+%F %T')" \
       --arg rid "$(cat "$IDIR/run-id" 2>/dev/null || true)" \
   '{ts:$ts, run_id:$rid, path:$p, kind:$k, caption:$c}' >> "$FRAMES" \
  || { echo "❌ не зміг записати" >&2; exit 1; }
if [ "$kind" = video ]; then
  echo "покажу рев'юеру кадри з кліпу $(basename "$file")"
else
  echo "покажу рев'юеру $(basename "$file")"
fi
