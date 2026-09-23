#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

PROJ="$(canon_path "${1:?usage: worker-interrupt.sh <project-dir> <run-id|->}")"
RID="${2:-'-'}"; [ "$RID" = "-" ] && RID=""
slug="$(slug_for "$PROJ")"; idir="$SUP_INSTANCES/$slug"; session="$(session_name "$slug")"

[ -d "$idir" ] || { echo "нема живого інстанса"; exit 3; }
[ -n "$RID" ] || { echo "нема run-id для безпечної зупинки"; exit 4; }
inst_rid="$(tr -d '[:space:]' < "$idir/run-id" 2>/dev/null || true)"
[ -n "$inst_rid" ] && [ "$inst_rid" = "$RID" ] \
  || { echo "жива сесія належить іншому рану"; exit 4; }
tmux has-session -t "$session" 2>/dev/null || { echo "сесія вже закрита"; exit 3; }

# Stop is his decision, and it outlives the Escape that carries it. The frozen-turn recovery must
# not read a turn he stopped as a turn that hung and start it again; the next message he sends
# clears this.
: > "$idir/director-stopped" 2>/dev/null || true

# What Stop means depends on what is happening, and the order here is the order the app's own
# header uses: a running turn first, then preparation.
#
# Preparation counts as something to stop even though the pane is perfectly still: nothing has been
# typed at the worker, and the work is two model calls the director has just decided they do not
# want. And it counts from the moment the message is ACCEPTED, not from the moment a pipeline
# claims it — the app already says "preparing" for an envelope still waiting in the queue, so Stop
# in that gap used to do nothing at all and the pump delivered the message a moment later.
if ! _turn_running "$session" && [ ! -e "$idir/review-active" ]; then
  act="$(pipeline_active_file "$idir")"
  mid=""
  if pipeline_running "$idir"; then
    mid="$(jq -r '.message_id // empty' "$act" 2>/dev/null)"
  else
    head="$(pending_head "$idir" || true)"
    [ -n "$head" ] && mid="$(jq -r '.message_id // empty' "$head" 2>/dev/null)"
  fi
  if [ -n "$mid" ]; then
    # One implementation of taking a message back, not two. It knows the difference between a
    # message nothing has been typed for and one that is already in the composer, and Stop needs
    # exactly the same distinction.
    verdict="$("$BIN_DIR/worker-withdraw.sh" "$PROJ" "$mid" 2>/dev/null)"
    if [ "$verdict" = withdrawn ]; then
      echo "■ Зупиняю підготовку; діалог і черга залишаються"
      exit 0
    fi
    # It got there first. Stop the turn it started, which is what Stop meant anyway.
    if _turn_running "$session"; then
      tmux send-keys -t "$session" Escape 2>/dev/null || { echo "не вдалося передати Stop"; exit 1; }
      echo "■ Зупиняю поточну відповідь; діалог і черга залишаються"
      exit 0
    fi
    echo "повідомлення вже дійшло до воркера"
    exit 2
  fi
  echo "поточний хід уже зупинився"
  exit 2
fi

tmux send-keys -t "$session" Escape 2>/dev/null || { echo "не вдалося передати Stop"; exit 1; }
echo "■ Зупиняю поточну відповідь; діалог і черга залишаються"
exit 0
