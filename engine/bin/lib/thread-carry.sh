#!/bin/bash
# A chat's task, kept beyond the run folder it was worked in.
#
# The task record (thread/current.json) and what the task's preparation produced live in the run's
# instance folder, and stop, the idle teardown and every resume take that folder away. The next
# message in the same conversation then came back to an engine that remembered nothing — the worker
# itself resumes the same Claude session and remembers everything — and was opened as a new task:
# a full preparation for "the ticket was updated, check it". Bridge tasks keep theirs in
# lib/tasks.sh; this is the same idea for a conversation, keyed by its Claude session.
#
#   thread-carry/c-<hash of session id>/thread/          the record and its journal
#   thread-carry/c-<hash of session id>/material/        the preparation's material (CARRY_MATERIAL)
#   thread-carry/c-<hash of session id>/last-reply.txt   what Claude last said
#   thread-carry/c-<hash of session id>/meta.json        session id, run id, project, when
#
# Saved whenever a run folder goes, by whatever takes it. Restored only when Jev is asked — on, or in
# shadow, where its answer is written down and the old one is applied: restoring is what makes "is
# this the same task?" a question, and without Jev to answer it the old rule — no record, a new task —
# is the one that stays.
#
# Sourced by supervisor-lib.sh, after lib/tasks.sh.

# What a follow-up reads besides the record: the agreed position (thread_brief), the research and
# design precedent and the triage's choice (preflight's carry_task_material). Not the runspec: that
# belongs to a dispatch-scoped run and is written by dispatch.sh, never by a chat.
CARRY_MATERIAL="peer-alignment.md plan.md research.md research.json design.md design.json roles-chosen.json"

thread_carry_root() { printf '%s/thread-carry' "$SUP_STATE"; }

thread_carry_dir() {   # $1=Claude session id — the folder name is derived from it, never the id itself
  printf '%s/c-%s' "$(thread_carry_root)" "$(printf '%s' "${1:-}" | shasum -a 256 | cut -c1-20)"
}

_thread_carry_sid() { tr -d '[:space:]' < "${1:-}/claude-session-id" 2>/dev/null; }

# One lock per conversation, taken by both save and restore: a save swaps the folder in two renames,
# and a restore reading in between would find nothing, or one snapshot's record with another's
# material. A short wait, not a long one — a teardown must not hang on it.
_thread_carry_lock() {   # $1=carry dir → 0 when held
  local i=0
  until _take_lock "$1.lock"; do i=$((i + 1)); [ "$i" -ge 50 ] && return 1; sleep 0.1; done
}
_thread_carry_unlock() { rm -rf "${1:-}.lock" 2>/dev/null || true; }

# Before a run folder is taken away. Never fails its caller: losing the copy only means the old
# behaviour, and a teardown must not stop on it.
thread_carry_save() {   # $1=instance dir
  local idir="${1:-}" sid dir tmp f newer
  [ -s "$idir/thread/current.json" ] || return 0
  sid="$(_thread_carry_sid "$idir")"
  [ -n "$sid" ] || return 0
  dir="$(thread_carry_dir "$sid")"
  mkdir -p "$(thread_carry_root)" 2>/dev/null || return 0
  _thread_carry_lock "$dir" || return 0
  tmp="$dir.tmp.$$"; rm -rf "$tmp" 2>/dev/null
  mkdir -p "$tmp/thread" "$tmp/material" 2>/dev/null || { _thread_carry_unlock "$dir"; return 0; }
  # The record and its journal as one snapshot: a message being bound right now writes both.
  _thread_lock "$idir" || true
  cp -f "$idir/thread/current.json" "$tmp/thread/current.json" 2>/dev/null
  [ -s "$idir/thread/messages.jsonl" ] && cp -f "$idir/thread/messages.jsonl" "$tmp/thread/messages.jsonl" 2>/dev/null
  _thread_unlock "$idir"
  # An older copy never replaces a newer one: a stop racing a resume, or the teardown of a folder a
  # resume has already replaced, must not take the task back a step. The same task is compared by
  # revision — two messages can land in one second — and different tasks by when each last moved.
  newer="$(jq -n --slurpfile n "$tmp/thread/current.json" --slurpfile o "$dir/thread/current.json" '
            ($n[0] // {}) as $n | ($o[0] // {}) as $o
            | if ($o.thread_id // "") == "" then true
              elif ($n.thread_id // "") == ($o.thread_id // "") then (($n.revision // 0) >= ($o.revision // 0))
              else (($n.last_message_at // 0) >= ($o.last_message_at // 0)) end' 2>/dev/null)"
  [ -s "$dir/thread/current.json" ] || newer=true
  if [ "$newer" != true ]; then
    rm -rf "$tmp" 2>/dev/null; _thread_carry_unlock "$dir"; return 0
  fi
  for f in $CARRY_MATERIAL; do
    [ -s "$idir/$f" ] && cp -f "$idir/$f" "$tmp/material/$f" 2>/dev/null
  done
  claude_last_reply "$idir" > "$tmp/last-reply.txt" 2>/dev/null || true
  [ -s "$tmp/last-reply.txt" ] || { [ -s "$idir/carried-last-reply.txt" ] && cp -f "$idir/carried-last-reply.txt" "$tmp/last-reply.txt"; }
  jq -n --arg sid "$sid" --arg rid "$(tr -d '[:space:]' < "$idir/run-id" 2>/dev/null)" \
        --arg proj "$(cat "$idir/project" 2>/dev/null)" --argjson at "$(date +%s)" \
     '{session_id:$sid, run_id:$rid, project:$proj, saved_at:$at}' > "$tmp/meta.json" 2>/dev/null
  rm -rf "$dir.old.$$" 2>/dev/null
  [ -d "$dir" ] && mv "$dir" "$dir.old.$$" 2>/dev/null
  if mv "$tmp" "$dir" 2>/dev/null; then
    rm -rf "$dir.old.$$" 2>/dev/null
  else
    rm -rf "$tmp" 2>/dev/null; [ -d "$dir.old.$$" ] && mv "$dir.old.$$" "$dir" 2>/dev/null
  fi
  _thread_carry_unlock "$dir"
  thread_carry_prune
  return 0
}

# Into a resumed run's fresh folder, before its first message is accepted (night-shift.sh resume).
thread_carry_restore() {   # $1=new instance dir  $2=Claude session id being resumed
  local idir="${1:-}" sid="${2:-}" dir
  [ -n "$idir" ] && [ -d "$idir" ] && [ -n "$sid" ] || return 0
  jev_wants relation || return 0
  # Never over a task the folder already has: a revival keeps its folder, and its record is live.
  [ -s "$idir/thread/current.json" ] && return 0
  dir="$(thread_carry_dir "$sid")"
  [ -s "$dir/thread/current.json" ] || return 0
  _thread_carry_lock "$dir" || return 0
  _thread_carry_restore_locked "$idir" "$dir"
  _thread_carry_unlock "$dir"
  return 0
}

_thread_carry_restore_locked() {   # $1=new instance dir  $2=carry dir
  local idir="$1" dir="$2" f restored=""
  [ -s "$dir/thread/current.json" ] || return 0
  mkdir -p "$idir/thread" 2>/dev/null || return 0
  # The journal comes back closed. A message still queued when the old run went away will never be
  # delivered by this one, and a brief listing it as owed would send the worker after it.
  if [ -s "$dir/thread/messages.jsonl" ]; then
    jq -c 'if .delivered != true then .delivered = true | .lost_at_restart = true else . end' \
       "$dir/thread/messages.jsonl" > "$idir/thread/messages.jsonl" 2>/dev/null || true
  fi
  jq --argjson at "$(date +%s)" --arg rid "$(jq -r '.run_id // ""' "$dir/meta.json" 2>/dev/null)" \
     '.carried_at = $at | .carried_from_run = $rid' "$dir/thread/current.json" \
     > "$idir/thread/current.json.tmp" 2>/dev/null \
    && mv -f "$idir/thread/current.json.tmp" "$idir/thread/current.json" 2>/dev/null \
    || { rm -f "$idir/thread/current.json.tmp"; return 0; }
  for f in $CARRY_MATERIAL; do
    [ -s "$dir/material/$f" ] || continue
    cp -f "$dir/material/$f" "$idir/$f" 2>/dev/null && restored="$restored $f"
  done
  printf '%s\n' $restored > "$idir/carried-material" 2>/dev/null
  [ -s "$dir/last-reply.txt" ] && cp -f "$dir/last-reply.txt" "$idir/carried-last-reply.txt" 2>/dev/null
  echo "$(date '+%F %T') [carry] task $(jq -r '.thread_id // "?"' "$idir/thread/current.json" 2>/dev/null) (revision $(jq -r '.revision // "?"' "$idir/thread/current.json" 2>/dev/null)) brought back into $(basename "$idir") — its next message is asked whether it continues it" \
    >> "$SUP_STATE/supervisor.log" 2>/dev/null
  return 0
}

# The message turned out to start something else: what came back with the old task goes, so the new
# task's preparation is the only material anyone reads for it.
thread_carry_drop_material() {   # $1=instance dir
  local idir="${1:-}" f
  [ -s "$idir/carried-material" ] || { rm -f "$idir/carried-last-reply.txt" 2>/dev/null; return 0; }
  while IFS= read -r f; do
    case "$f" in ''|*/*) continue ;; esac
    rm -f "$idir/$f" 2>/dev/null
  done < "$idir/carried-material"
  rm -f "$idir/carried-material" "$idir/carried-last-reply.txt" 2>/dev/null
  return 0
}

# Kept for as long as a conversation is plausibly picked up again.
thread_carry_prune() {
  local root; root="$(thread_carry_root)"
  [ -d "$root" ] || return 0
  find "$root" -maxdepth 1 -type d -name 'c-*' -mtime "+${SUPERVISOR_THREAD_CARRY_DAYS:-30}" \
       -exec rm -rf {} + 2>/dev/null || true
}
