#!/bin/bash
# Run ONE message through an ordered list of stages.
#
# The list is data (supervisor/pipelines/<name>.json), not control flow, because the shape of the
# work is a product decision: which engines form a position, whether they argue first, what gets
# compared, what the worker is finally handed. Today two definitions ship — `adaptive-peer` and
# `plain` — and a pipeline the director assembles by hand later is the same file with a different
# order. Nothing here knows what a "peer brief" is; it knows how to run stages, run a group of them
# side by side, keep their artifacts apart, time them, and stop when the message is withdrawn.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

IDIR="${1:?usage: pipeline.sh <instance-dir> <envelope.json>}"
ENVELOPE="${2:?usage: pipeline.sh <instance-dir> <envelope.json>}"
[ -s "$ENVELOPE" ] || { echo "❌ нема конверта: $ENVELOPE" >&2; exit 2; }

run_env_load "$IDIR"
LOG="$SUP_STATE/supervisor.log"
export INJECT_LOG="$LOG"

PROJ="$(cat "$IDIR/project" 2>/dev/null || true)"
[ -n "$PROJ" ] && [ -d "$PROJ" ] || { echo "❌ інстанс не називає проєкту" >&2; exit 2; }
SESSION="$(cat "$IDIR/session" 2>/dev/null || session_name "$(basename "$IDIR")")"

MSG="$(jq -r '.message // empty' "$ENVELOPE")"
MSG_ID="$(jq -r '.message_id // empty' "$ENVELOPE")"
SEQ="$(jq -r '.seq // "0"' "$ENVELOPE")"
PIPE="$(jq -r '.pipeline // "plain"' "$ENVELOPE")"
INTENT="$(jq -r '.intent // "conversation"' "$ENVELOPE")"
WANT_RID="$(jq -r '.run_id // empty' "$ENVELOPE")"
CTX_FILE="$(jq -r '.context_file // empty' "$ENVELOPE")"
DIRS_FILE="$(jq -r '.extra_dirs_file // empty' "$ENVELOPE")"
# Decided when the message was accepted, and carried here rather than re-derived: a result
# declared between acceptance and preparation must not turn a follow-up into a new task.
RELATION="$(jq -r '.relation // empty' "$ENVELOPE")"
THREAD_ID="$(jq -r '.thread_id // empty' "$ENVELOPE")"
case "$RELATION" in continue|new) ;; *) RELATION="" ;; esac
[ -n "$CTX_FILE" ] && export SUPERVISOR_CHAT_CONTEXT_FILE="$CTX_FILE"
[ -n "$DIRS_FILE" ] && export SUPERVISOR_EXTRA_DIRS_FILE="$DIRS_FILE"
[ -n "$MSG" ] || { echo "❌ порожній конверт" >&2; exit 2; }

case "$PIPE" in *[!a-z0-9-]*|"") PIPE=plain ;; esac   # a name goes onto a path
DEF="$ROOT/supervisor/pipelines/$PIPE.json"
[ -s "$DEF" ] || DEF="$ROOT/supervisor/pipelines/plain.json"
[ -s "$DEF" ] || { echo "❌ нема опису пайплайна" >&2; exit 2; }

# A caller that already owns the dispatch record (the night dispatcher does — it allocated the
# report folder and wrote the product memory against that id) says so, and this run reuses it
# instead of replacing a record other tools are already reading.
OWNED_DISPATCH="$(jq -r '.dispatch_id // empty' "$ENVELOPE")"
GUARD_DISPATCH="$(jq -r '.guard_dispatch // empty' "$ENVELOPE")"
DISPATCH_ID="${OWNED_DISPATCH:-$(uuidgen 2>/dev/null || printf '%s-%s' "$(date +%s)" "$$")}"

# One preparation at a time for this run, whoever asked for it. Taken here rather than in the two
# callers, so a night dispatch and a chat message cannot be mid-preparation together — which is
# what let them overwrite each other's active-stage marker and dispatch record, and left the
# dispatcher aborting its own work as superseded by the chat's.
if ! pipeline_lock_acquire "$IDIR" "$PIPE/${SEQ}" "${SUPERVISOR_PIPELINE_LOCK_WAIT:-${SUPERVISOR_PREFLIGHT_LOCK_WAIT:-3600}}"; then
  echo "$(date '+%F %T') [pipeline/$PIPE] gave up waiting for the run — message $SEQ stays queued" \
    >> "$LOG"
  exit 75
fi
trap 'pipeline_lock_release "$IDIR"' EXIT INT TERM
ART="$IDIR/messages/$SEQ-$(printf '%s' "${MSG_ID:-$DISPATCH_ID}" | tr -cd 'A-Za-z0-9-')"
mkdir -p "$ART" 2>/dev/null || true
# Each message keeps its own reasoning, and an instance lives for days. Keep the recent ones — the
# app and a person reading back both want them — and let the rest go.
( cd "$IDIR/messages" 2>/dev/null && ls -1dt ./*/ 2>/dev/null | tail -n +"${SUPERVISOR_KEEP_MESSAGE_ARTIFACTS:-12}" \
    | while IFS= read -r old_dir; do [ "$(basename "$old_dir")" = "$(basename "$ART")" ] || rm -rf "$old_dir"; done ) 2>/dev/null || true
printf '%s\n' "$MSG" > "$ART/task.txt"
STAGES_LOG="$ART/stages.jsonl"
: > "$STAGES_LOG" 2>/dev/null || true

now_ms() { perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000' 2>/dev/null || printf '%s000' "$(date +%s)"; }
plog() { echo "$(date '+%F %T') [pipeline/$PIPE] $*" >> "$LOG"; }

# A message can be taken back while its positions are still being formed. Every stage boundary and
# the moment before injection ask again, because the whole point of preparing is that it takes
# minutes — long enough for the director to change their mind, stop the run, or start another.
withdrawn() {
  # The whole run being torn down counts, and it is asked first: everything below reads files
  # inside a folder that may no longer exist.
  [ -d "$IDIR" ] || { plog "message $SEQ abandoned — the run is gone"; return 0; }
  [ -s "$ENVELOPE" ] || { plog "message $SEQ withdrawn — envelope gone"; return 0; }
  if [ -n "$MSG_ID" ] && message_cancelled "$IDIR" "$MSG_ID"; then
    plog "message $SEQ cancelled by the director"
    return 0
  fi
  local have; have="$(tr -d '[:space:]' < "$IDIR/run-id" 2>/dev/null || true)"
  if [ -n "$WANT_RID" ] && [ -n "$have" ] && [ "$WANT_RID" != "$have" ]; then
    plog "message $SEQ abandoned — run changed ($WANT_RID → $have)"
    return 0
  fi
  tmux has-session -t "$SESSION" 2>/dev/null || { plog "message $SEQ abandoned — session $SESSION is gone"; return 0; }
  if [ -n "$GUARD_DISPATCH" ]; then
    local cur; cur="$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null || true)"
    if [ "$cur" != "$GUARD_DISPATCH" ]; then
      plog "dispatch $GUARD_DISPATCH superseded by ${cur:-none} — not injecting"
      return 0
    fi
  fi
  return 1
}

# What the worker's own tools read: the task it was actually given. Without this record
# consult-codex asks Codex about an empty task and the review gate has no dispatch to name.
record_dispatch() {
  local rk chat=false
  # Checks a worker registered were checks for the PREVIOUS task. Left in place, the verifier ran
  # `tests/check_form.py` for a dispatch that had been asked to delete the very site the form was
  # on — and overrode the reviewer's PASS with the file-not-found. A follow-up keeps its checks; a
  # new task starts with none, and the old ones stay on disk under the dispatch they belonged to.
  if [ "${RELATION:-}" != continue ] && [ -s "$IDIR/checks.jsonl" ]; then
    _prev_did="$(jq -r '.id // empty' "$IDIR/dispatch.json" 2>/dev/null || true)"
    mkdir -p "$IDIR/dispatches" 2>/dev/null || true
    mv -f "$IDIR/checks.jsonl" "$IDIR/dispatches/${_prev_did:-previous}.checks.jsonl" 2>/dev/null \
      || rm -f "$IDIR/checks.jsonl" 2>/dev/null || true
    plog "registered checks of the previous task set aside (dispatches/${_prev_did:-previous}.checks.jsonl)"
  fi
  rk="$(printf '%s' "$DISPATCH_ID" | tr 'A-Z' 'a-z' | tr -cd 'a-f0-9' | cut -c1-8)"
  # A turn of a conversation, not a task somebody filed. The backlog adopts finished dispatches
  # into cards, and a chat that filed a card for every message the director typed would be its own
  # small disaster.
  [ -f "$IDIR/direct-chat" ] && chat=true
  mkdir -p "$IDIR/dispatches" 2>/dev/null || true
  jq -nc --arg id "$DISPATCH_ID" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg task "$MSG" \
     --arg rk "$rk" --arg pipe "$PIPE" --arg intent "$INTENT" --arg mid "${MSG_ID:-}" \
     --arg tid "${THREAD_ID:-}" --arg rel "${RELATION:-}" \
     --argjson chat "$chat" \
     '{id:$id, at:$at, task:$task, report_key:$rk, pipeline:$pipe, intent:$intent, chat:$chat}
      + (if $mid == "" then {} else {message_id:$mid} end)
      + (if $tid == "" then {} else {thread_id:$tid} end)
      + (if $rel == "" then {} else {relation:$rel} end)' > "$IDIR/dispatch.json.tmp" 2>/dev/null \
    && cp -f "$IDIR/dispatch.json.tmp" "$IDIR/dispatches/$DISPATCH_ID.json" 2>/dev/null \
    && mv -f "$IDIR/dispatch.json.tmp" "$IDIR/dispatch.json" \
    || rm -f "$IDIR/dispatch.json.tmp" 2>/dev/null || true
}

mark_stage() {   # $1=stage id  $2=state  (for the app and for the tests)
  local f; f="$(pipeline_active_file "$IDIR")"
  jq -nc --argjson pid "$$" --arg m "${MSG_ID:-}" --arg d "$DISPATCH_ID" --arg p "$PIPE" \
     --arg s "$1" --arg st "${2:-running}" --arg seq "$SEQ" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     '{pid:$pid, pipeline:$p, stage:$s, state:$st, seq:$seq, dispatch_id:$d, at:$at}
      + (if $m == "" then {} else {message_id:$m} end)' > "$f.tmp" 2>/dev/null \
    && mv -f "$f.tmp" "$f" 2>/dev/null || rm -f "$f.tmp" 2>/dev/null || true
}

# One stage. The command name is resolved inside bin/ and never taken as a path, so a pipeline
# definition can choose among the engine's own stages and nothing else.
run_stage() {   # $1=stage id  $2..=argv from the definition
  local id="$1"; shift
  local cmd="$1"; shift
  case "$cmd" in */*|..*|"") plog "stage $id: refusing command '$cmd'"; return 127 ;; esac
  [ -x "$BIN_DIR/$cmd" ] || { plog "stage $id: no such stage command '$cmd'"; return 127; }
  local s e rc
  s="$(now_ms)"
  PIPE_IDIR="$IDIR" PIPE_ART="$ART" PIPE_PROJ="$PROJ" PIPE_SESSION="$SESSION" \
  PIPE_ENVELOPE="$ENVELOPE" PIPE_DISPATCH_ID="$DISPATCH_ID" PIPE_STAGE="$id" \
  PIPE_MESSAGE_ID="$MSG_ID" PIPE_PIPELINE="$PIPE" PIPE_INTENT="$INTENT" \
  PIPE_RELATION="$RELATION" PIPE_THREAD_ID="$THREAD_ID" \
    "$BIN_DIR/$cmd" "$@" --art "$ART" "$PROJ" "$MSG" >>"$LOG" 2>&1
  rc=$?
  e="$(now_ms)"
  jq -nc --arg id "$id" --argjson s "$s" --argjson e "$e" --argjson rc "$rc" \
     '{stage:$id, started_ms:$s, ended_ms:$e, exit:$rc}' >> "$STAGES_LOG" 2>/dev/null || true
  plog "stage $id finished in $((e - s))ms (exit $rc)"
  return "$rc"
}

[ -n "$OWNED_DISPATCH" ] || record_dispatch
plog "message $SEQ (${MSG_ID:-no id}) → $(jq -r '[.stages[].id] | join(" → ")' "$DEF")"

# Stages in order; stages sharing a `group` start together and are waited on together. That is the
# whole of the parallelism: two positions formed side by side, neither able to see the other's file
# because each writes only its own and nothing is read until both have exited.
# An argv element may legitimately contain a space once these definitions are written by hand, so
# the list is read element by element rather than split on whitespace.
stage_argv() {   # $1 = index ; fills the global RUN_ARGV
  local a
  RUN_ARGV=()
  while IFS= read -r a; do RUN_ARGV+=("$a"); done < <(jq -r ".stages[$1].run[]" "$DEF")
}

# A follow-up to the open task does not get the two independent positions again.
#
# Every message the director typed ran the whole ceremony: Claude's position (Opus in plan mode, five
# to fifteen minutes), Codex's position, the comparison — sixty times in one week, for messages like
# «продовжуй» and «backdrop не перемикається». The worker already holds the context those positions
# were meant to give it, and it has `consult-codex` for the moment it actually wants a second opinion.
# So the stages that say so in the definition are skipped when the context stage has marked the
# message a follow-up. The first message of a task keeps the full flow.
followup_now() {
  [ "${SUPERVISOR_FOLLOWUP_PEERS:-0}" = 1 ] && return 1
  [ "$(cat "$ART/.scale" 2>/dev/null)" = followup ]
}
stage_skipped() {   # $1 = index → 0 when this stage is to be skipped for this message
  [ "$(jq -r ".stages[$1].skip_when_followup // false" "$DEF")" = true ] && followup_now
}

total="$(jq '.stages | length' "$DEF")"
i=0
while [ "$i" -lt "$total" ]; do
  grp="$(jq -r ".stages[$i].group // empty" "$DEF")"
  if [ -z "$grp" ]; then
    id="$(jq -r ".stages[$i].id" "$DEF")"
    opt="$(jq -r ".stages[$i].optional // false" "$DEF")"
    withdrawn && exit 7
    if stage_skipped "$i"; then
      plog "stage $id skipped — follow-up to the open task; the worker consults Codex itself when it needs to"
      i=$((i + 1))
      continue
    fi
    mark_stage "$id" running
    stage_argv "$i"
    # Captured, not read out of `$?` after a `!` — the negation would have overwritten it.
    run_stage "$id" "${RUN_ARGV[@]}"; st=$?
    if [ "$st" != 0 ]; then
      if [ "$st" = 7 ] || { [ -n "$MSG_ID" ] && message_cancelled "$IDIR" "$MSG_ID"; }; then
        plog "stage $id stopped because the message was taken back"
        rm -f "$(pipeline_active_file "$IDIR")" 2>/dev/null || true
        exit 7
      fi
      if [ "$opt" != true ]; then
        plog "stage $id failed and is required — stopping"
        mark_stage "$id" failed
        exit 1
      fi
      plog "stage $id failed but is optional — continuing degraded"
    fi
    i=$((i + 1))
    continue
  fi

  withdrawn && exit 7
  pids=""; ids=""; skipped_ids=""
  while [ "$i" -lt "$total" ] && [ "$(jq -r ".stages[$i].group // empty" "$DEF")" = "$grp" ]; do
    id="$(jq -r ".stages[$i].id" "$DEF")"
    if stage_skipped "$i"; then skipped_ids="$skipped_ids $id"; i=$((i + 1)); continue; fi
    [ -n "$pids" ] || mark_stage "$grp" running
    stage_argv "$i"
    run_stage "$id" "${RUN_ARGV[@]}" &
    pids="$pids $!"; ids="$ids $id"
    i=$((i + 1))
  done
  [ -z "$skipped_ids" ] || plog "group $grp: skipped$skipped_ids — follow-up to the open task; the worker consults Codex itself when it needs to"
  [ -n "$pids" ] || continue
  plog "group $grp: started$ids side by side"
  grp_rc=0
  for pid in $pids; do wait "$pid" 2>/dev/null || grp_rc=1; done
  [ "$grp_rc" = 0 ] || plog "group $grp: at least one stage failed — the pipeline continues with what it has"
done

withdrawn && exit 7
rm -f "$(pipeline_active_file "$IDIR")" 2>/dev/null || true
exit 0
