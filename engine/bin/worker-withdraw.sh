#!/bin/bash
# Take one message back, wherever it currently is.
#
# The app used to answer this by rewriting the retry queue itself, which could only ever see one of
# the three places a message can be: waiting to be prepared, being prepared right now, or composed
# and parked for a retry. A message caught mid-preparation came back as "already read" — the one
# answer that was certainly false, because the worker had not been given anything at all.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

PROJ="$(canon_path "${1:?usage: worker-withdraw.sh <project-dir> <message-id>}")"
MID="$(printf '%s' "${2:?usage: worker-withdraw.sh <project-dir> <message-id>}" | tr -d '[:space:]')"
[ -n "$MID" ] || { echo "нема ідентифікатора повідомлення" >&2; exit 2; }
slug="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$slug")"
[ -d "$IDIR" ] || { echo "already-read"; exit 0; }
LOG="$SUP_STATE/supervisor.log"
low="$(printf '%s' "$MID" | tr 'A-Z' 'a-z')"

# Asked twice for one press of the button — stopping what is running and taking the message back
# are two paths that both end here — the second caller gets the same answer as the first. Without
# this the first call removes the message and the second, finding nothing, reports it as read: the
# app then marks something the worker never saw as read, and hides it.
recorded="$(withdraw_verdict "$IDIR" "$MID" || true)"
if [ -n "$recorded" ]; then
  echo "$recorded"; exit 0
fi

# Already in front of the worker: there is nothing to take back, and saying otherwise would make
# the app hide a message the session has read.
if was_delivered "$IDIR" "$MID"; then
  record_withdraw_verdict "$IDIR" "$MID" already-read
  echo "already-read"; exit 0
fi

settle() {   # $1 = withdrawn | already-read
  record_withdraw_verdict "$IDIR" "$MID" "$1"
  # The task record has to forget it too. This is the ONE place every withdrawal passes through —
  # the pump and the delivery stage each clear their own copy when they happen to be the ones that
  # notice, but a message taken back out of the queue is removed from under both of them, and
  # without this the next brief would hand Codex an instruction the director had already retracted
  # as something still owed.
  [ "$1" = withdrawn ] && thread_cancelled "$IDIR" "$MID"
  [ "$1" = already-read ] && clear_cancel "$IDIR" "$MID"
  echo "$1"
  exit 0
}

# The marker FIRST, before anything is inspected.
#
# A message moves between the three places while this runs: the pump can claim an envelope that is
# about to be deleted, and a pipeline can pass its last check and inject a message the director has
# already taken back. Looking before marking left a window in both directions. Marking first closes
# them: the pump refuses a marked envelope before claiming it, every stage boundary asks again, and
# the delivery stage asks one last time immediately before it types anything.
cancel_message "$IDIR" "$MID" || true
touched=0

# Being handed over RIGHT NOW. The handoff publishes where it has got to, and the answer differs on
# the two sides of one moment — the Enter key.
#
#   waiting    nothing typed            → stopping it is enough
#   typed      text sits in the composer→ stop it AND clear the composer, or the next message the
#                                          director sends would arrive with this one glued in front
#   submitted  Enter has been sent      → it may already be Claude's; the honest answer is that it
#   confirmed  the turn is running        was read, and the app then offers to replace it instead
#
# Every transition is published a moment BEFORE the step it names, so the one answer that must
# never be wrong — "nothing has been typed" — is the one this cannot get wrong.
handoff="$(delivering_file "$IDIR")"
if [ -s "$handoff" ]; then
  h_mid="$(jq -r '.message_id // empty' "$handoff" 2>/dev/null | tr 'A-Z' 'a-z')"
  if [ "$h_mid" = "$low" ]; then
    h_phase_file="$(jq -r '.phase_file // empty' "$handoff" 2>/dev/null)"
    h_pid="$(jq -r '.pid // empty' "$handoff" 2>/dev/null)"
    h_session="$(jq -r '.session // empty' "$handoff" 2>/dev/null)"
    phase="$(cat "$h_phase_file" 2>/dev/null | tr -d '[:space:]')"
    case "$phase" in
      submitting|submitted|confirmed)
        echo "$(date '+%F %T') [withdraw] $MID was already at '$phase' — nothing to take back" >> "$LOG"
        settle already-read ;;
    esac
    kill_tree "$h_pid"
    # Read again: the kill may have landed on the far side of the Enter key.
    phase="$(cat "$h_phase_file" 2>/dev/null | tr -d '[:space:]')"
    case "$phase" in
      submitting|submitted|confirmed)
        echo "$(date '+%F %T') [withdraw] $MID reached the worker while it was being taken back ($phase)" >> "$LOG"
        settle already-read ;;
      typing|typed)
        # The composer holds this message — all of it, or the part that had gone in when the paste
        # was stopped. Either way it must not sit there to be sent in front of the next message.
        if [ -n "$h_session" ] && ! clear_composer "$h_session" >/dev/null 2>&1; then
          # It would not clear, which means a turn is running in it — so the text went in after all.
          echo "$(date '+%F %T') [withdraw] $MID could not be cleared from the composer — treating it as read" >> "$LOG"
          settle already-read
        fi
        echo "$(date '+%F %T') [withdraw] $MID was in the composer ($phase) and has been cleared" >> "$LOG" ;;
      *)
        echo "$(date '+%F %T') [withdraw] $MID stopped before anything was typed" >> "$LOG" ;;
    esac
    # The stage that was carrying this message was killed, so it will never write its own last
    # line. Whoever ended a handoff records how it ended, or the trail simply stops mid-sentence
    # and nobody reading it back can tell a withdrawal from a crash.
    [ -n "$h_phase_file" ] && printf '%s outcome=withdrawn phase=%s\n' \
      "$(date '+%F %T.000')" "${phase:-waiting}" >> "$h_phase_file.log" 2>/dev/null
    rm -f "$handoff" 2>/dev/null || true
    drop_pending "$IDIR" "$MID" || true
    rm -f "$(pipeline_active_file "$IDIR")" 2>/dev/null || true
    settle withdrawn
  fi
fi

# 1. Being prepared this second. Its envelope is still in the queue and looks exactly like one that
# is merely waiting, so this is asked before the queue — and the two model calls are stopped rather
# than left to finish into the void.
act="$(pipeline_active_file "$IDIR")"
if [ -s "$act" ]; then
  got="$(jq -r '.message_id // empty' "$act" 2>/dev/null | tr 'A-Z' 'a-z')"
  if [ "$got" = "$low" ]; then
    stage="$(jq -r '.stage // "?"' "$act" 2>/dev/null)"
    kill_tree "$(jq -r '.pid // empty' "$act" 2>/dev/null)"
    # And the marker the app reads, so the conversation stops saying "preparing" at once rather
    # than when the pump next gets a turn.
    rm -f "$act" 2>/dev/null || true
    echo "$(date '+%F %T') [withdraw] cancelled the preparation of $MID (stage $stage)" >> "$LOG"
    touched=1
  fi
fi

# 2. Waiting to be prepared, or the envelope of the one just stopped — either way it must not be
# picked up again.
if drop_pending "$IDIR" "$MID"; then
  [ "$touched" = 1 ] || echo "$(date '+%F %T') [withdraw] pending message $MID removed before preparation" >> "$LOG"
  touched=1
fi

if [ "$touched" = 1 ]; then settle withdrawn; fi

# 3. Composed and parked for a retry. Still never typed at the worker.
f="$(undelivered_file "$IDIR")"
for q in "$f" "$IDIR/undelivered.jsonl"; do
  [ -s "$q" ] || continue
  if jq -e --arg id "$low" 'select((.id // "" | ascii_downcase) == $id)' "$q" >/dev/null 2>&1; then
    tmp="$q.tmp.$$"
    jq -c --arg id "$low" 'select((.id // "" | ascii_downcase) != $id)' "$q" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }
    if [ -s "$tmp" ]; then mv -f "$tmp" "$q"; else rm -f "$tmp" "$q"; fi
    echo "$(date '+%F %T') [withdraw] parked message $MID removed from the retry queue" >> "$LOG"
    settle withdrawn
  fi
done

# Nowhere to be found: the worker has it. The cancellation marker must not be left behind, or a
# reader of this directory would see a withdrawal that never happened.
settle already-read
