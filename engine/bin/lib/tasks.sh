#!/bin/bash
# A task that outlives its sessions: the record a bridge keeps work under for days.
#
# A run's folder (the instance directory) is temporary by design — `stop`, the watchdog's idle rule
# and every resume take it away — and with it went the only copy of what the task was: its goal, its
# acceptance criteria, the agreed plan, which branch it was on and what the reviewer said. A merge
# request reviewed a week later then came back to an engine that remembered nothing, and a comment
# on it became a brand-new task with the comment as its goal.
#
# So a task named by the bridge (`dispatch.sh --task-id PRJ-123`) gets a folder of its own under
# $SUP_STATE/tasks, outside every instance, and the timers that clean sessions up never touch it:
#
#   tasks/index.json            task id → key, so a tracker key is never a path
#   tasks/<key>/task.json       goal, branch, base, state, attempts, receipts, question, messages seen
#   tasks/<key>/material/       runspec.json, plan.md, peer-alignment.md, research/design — what the
#                               first preparation produced, put back in front of every later attempt
#   tasks/<key>/events.jsonl    the task's own event stream, one versioned line per change
#
# Files and jq, like the rest of the engine. One attempt runs per task at a time, so the only
# concurrent writers are a bridge's call and the gate finishing an attempt; both go through one lock.
#
# Sourced by supervisor-lib.sh. Nothing here runs unless a task id was given.

tasks_root() { printf '%s/tasks' "$SUP_STATE"; }

# The folder name for a task: derived from the id, never the id itself.
task_key() {   # $1=task id
  printf 't-%s' "$(printf '%s' "${1:-}" | shasum -a 256 | cut -c1-20)"
}
task_dir()  { printf '%s/%s' "$(tasks_root)" "$(task_key "${1:-}")"; }
task_file() { printf '%s/task.json' "$(task_dir "${1:-}")"; }
task_exists() { [ -n "${1:-}" ] && [ -s "$(task_file "$1")" ]; }

# Read one value with a jq expression; nothing when the task or the value is not there.
task_get() {   # $1=task id $2=jq expression
  [ -s "$(task_file "${1:-}")" ] || return 0
  jq -r "${2:-.} // empty" "$(task_file "$1")" 2>/dev/null
}

_task_lock()   { local l i=0; l="$(task_dir "$1")/.lock"; mkdir -p "$(dirname "$l")" 2>/dev/null
                 until _take_lock "$l"; do i=$((i + 1)); [ "$i" -ge 100 ] && return 1; sleep 0.1; done; }
_task_unlock() { rm -rf "$(task_dir "$1")/.lock" 2>/dev/null; }

# One attempt's life in one folder at a time. Held by a dispatch from the moment it checks that the
# task is free until the new attempt is on the record, and by a settled attempt's release from the
# moment it checks the worker generation until its session is gone — so a release can never see the
# old worker and then stop the new one, and two follow-ups can never both find the task free. The
# lock lives outside the instance directory, which is exactly the thing both of them replace.
task_lifecycle_lock_dir() { printf '%s/locks/task-life-%s' "$SUP_STATE" "$(slug_for "${1:-}")"; }
task_lifecycle_lock() {   # $1=project dir [$2=seconds to wait, default 120]
  local l i=0 max
  l="$(task_lifecycle_lock_dir "$1")"; max=$(( ${2:-120} * 5 ))
  until _take_lock "$l"; do i=$((i + 1)); [ "$i" -ge "$max" ] && return 1; sleep 0.2; done
  printf '%s\n' "${BASHPID:-$$}" > "$l/pid"
}
task_lifecycle_unlock() {   # $1=project dir — only the holder lets go
  local l; l="$(task_lifecycle_lock_dir "$1")"
  [ "$(cat "$l/pid" 2>/dev/null)" = "${BASHPID:-$$}" ] && rm -rf "$l" 2>/dev/null
  return 0
}

_iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Apply a jq filter to task.json under the lock, atomically. Extra arguments go to jq as they are
# (`--arg name value`, `--argjson name json`). A write that cannot happen is an error to the caller:
# a state change that did not reach the disk must not be reported as made.
task_update() {   # $1=task id $2=jq filter [jq args…]
  local tid="$1" filter="$2" f rc
  shift 2
  f="$(task_file "$tid")"; [ -s "$f" ] || return 1
  _task_lock "$tid" || return 1
  _task_apply "$f" "$filter" "$@"; rc=$?
  _task_unlock "$tid"
  return "$rc"
}
_task_apply() {   # $1=task file $2=jq filter [jq args…] — the caller holds the lock
  local f="$1" filter="$2" tmp rc
  shift 2
  tmp="$f.tmp.$$"
  jq --arg _now "$(_iso_now)" "$@" "$filter | .updated_at = \$_now" "$f" > "$tmp" 2>/dev/null \
    && [ -s "$tmp" ] && mv -f "$tmp" "$f"; rc=$?
  [ "$rc" = 0 ] || rm -f "$tmp" 2>/dev/null
  return "$rc"
}

# Is the task's last attempt still this one (dispatch id, run id, not stopped or superseded)? Read
# under the task's lock, so a stop or a /continue is either before it or after it. 0 = yes.
task_attempt_is() {   # $1=task id $2=dispatch id $3=run id
  local tid="$1" did="$2" rid="$3" f rc
  f="$(task_file "$tid")"; [ -s "$f" ] || return 1
  _task_lock "$tid" || return 1
  jq -e --arg d "$did" --arg r "$rid" '
      (.attempts[-1] // null) as $a
      | $a != null and ($a.dispatch_id // "") == $d
        and ((($a.run_id // "") == "") or $a.run_id == $r)
        and ((($a.disposition // "") | IN("stopped", "superseded")) | not)' "$f" >/dev/null 2>&1; rc=$?
  _task_unlock "$tid"
  return "$rc"
}

# The same, only if the task's last attempt is still the one this run is: its dispatch id, its run id
# (when the attempt has one), and not closed by a stop. Checked under the lock that guards the write,
# so nothing can start or stop an attempt between the check and the write — read before the lock, a
# late verdict could settle an attempt that `stop` had closed a moment earlier, or one a /continue
# had just opened. Returns 3, writing nothing, when the attempt is not this run's any more.
# TASK_ATTEMPT_OPEN_ONLY=1: and only while nothing has ended it (a stop never closes a settled one).
# An attempt a verdict ended may be settled again by a later verdict of the same live run (a run
# parked as needs-user, answered in the chat, then passed): that is the newer word on the same work.
task_update_attempt() {   # $1=task id $2=dispatch id $3=run id $4=jq filter [jq args…]
  local tid="$1" did="$2" rid="$3" filter="$4" f rc
  shift 4
  f="$(task_file "$tid")"; [ -s "$f" ] || return 1
  _task_lock "$tid" || return 1
  if ! jq -e --arg d "$did" --arg r "$rid" --arg open "${TASK_ATTEMPT_OPEN_ONLY:-0}" '
        (.attempts[-1] // null) as $a
        | $a != null and ($a.dispatch_id // "") == $d
          and ((($a.run_id // "") == "") or $a.run_id == $r)
          and ((($a.disposition // "") | IN("stopped", "superseded")) | not)
          and ($open != "1" or $a.ended_at == null)' "$f" >/dev/null 2>&1; then
    _task_unlock "$tid"
    return 3
  fi
  _task_apply "$f" "$filter" "$@"; rc=$?
  _task_unlock "$tid"
  return "$rc"
}

# One line of the task's own stream. Versioned, with an id a reader can deduplicate by and a
# sequence a reader can resume from; the time is UTC. Unknown numbers are null, never zero.
task_event() {   # $1=task id $2=kind $3=extra json object
  local tid="$1" kind="$2" extra="${3:-}" d seq n
  task_exists "$tid" || return 0
  n="$(task_get "$tid" '.attempts | length')"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  d="$(task_dir "$tid")"
  case "$extra" in '{'*'}') ;; *) extra='{}' ;; esac
  seq=0; [ -f "$d/events.jsonl" ] && seq="$(wc -l < "$d/events.jsonl" | tr -d ' ')"
  seq=$((seq + 1))
  jq -nc --arg id "$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || printf 'e-%s-%s' "$(date +%s)" "$$")" \
     --argjson seq "$seq" --arg at "$(_iso_now)" --arg tid "$tid" --arg k "$kind" \
     --arg st "$(task_get "$tid" .state)" --argjson n "$n" \
     --argjson x "$extra" \
     '{v:1, event_id:$id, seq:$seq, at:$at, task_id:$tid, attempt:($n // 0), kind:$k, state:$st} + $x' \
     >> "$d/events.jsonl" 2>/dev/null || true
}

# Create the record for a new task. The goal is the text as it first arrived; nothing later
# replaces it — a comment is added to a task, it does not become one.
task_create() {   # $1=task id $2=project $3=source $4=author $5=goal $6=branch $7=base ref
  local tid="$1" d f tmp
  d="$(task_dir "$tid")"; f="$d/task.json"
  mkdir -p "$d/material" 2>/dev/null || return 1
  _task_lock "$tid" || return 1
  if [ ! -s "$f" ]; then
    tmp="$f.tmp.$$"
    jq -n --arg tid "$tid" --arg key "$(task_key "$tid")" --arg p "$2" --arg src "$3" --arg au "$4" \
          --arg goal "$5" --arg br "$6" --arg base "$7" --arg now "$(_iso_now)" '
      {schema:1, task_id:$tid, key:$key, project:$p, source:$src, author:$au,
       state:"queued", state_reason:"", created_at:$now, updated_at:$now,
       objective:$goal, branch:$br, base_ref:$base, base_sha:"",
       repos:[], attempts:[], question:null, messages:{}, last_receipt:null}' > "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$f" || { rm -f "$tmp" 2>/dev/null; _task_unlock "$tid"; return 1; }
  fi
  _task_unlock "$tid"
  # The index is a convenience for people and listings; the key is always derivable from the id.
  local idx; idx="$(tasks_root)/index.json"
  _take_lock "$(tasks_root)/.index-lock" || true
  { [ -s "$idx" ] && cat "$idx" || echo '{}'; } \
    | jq --arg tid "$tid" --arg key "$(task_key "$tid")" '.[$tid] = $key' > "$idx.tmp.$$" 2>/dev/null \
    && mv -f "$idx.tmp.$$" "$idx" || rm -f "$idx.tmp.$$" 2>/dev/null
  rm -rf "$(tasks_root)/.index-lock" 2>/dev/null
  task_event "$tid" created "$(jq -nc --arg s "$3" --arg a "$4" '{source:$s, author:$a}')"
}

# Was this message already taken for this task? A bridge redelivers — GitLab retries a webhook, a
# poller restarts — and the same comment must not start the same work twice.
#   new        never seen: go on
#   duplicate  same id, same text: the earlier acceptance stands (printed as JSON on stdout)
#   conflict   same id, different text: refused, a caller has two different things under one name
task_message_check() {   # $1=task id $2=message id $3=text
  local tid="$1" mid="$2" sum prev
  [ -n "$mid" ] && task_exists "$tid" || { printf 'new'; return 0; }
  sum="$(printf '%s' "${3:-}" | shasum -a 256 | cut -c1-64)"
  prev="$(jq -c --arg m "$mid" '.messages[$m] // empty' "$(task_file "$tid")" 2>/dev/null)"
  [ -n "$prev" ] || { printf 'new'; return 0; }
  if [ "$(printf '%s' "$prev" | jq -r '.sha256')" = "$sum" ]; then
    printf 'duplicate\n%s' "$prev"
  else
    printf 'conflict'
  fi
}

task_message_record() {   # $1=task id $2=message id $3=text $4=dispatch id
  [ -n "${2:-}" ] || return 0
  task_update "$1" '.messages[$m] = {sha256:$s, at:$_now, dispatch_id:$d, attempt:((.attempts | length))}' \
    --arg m "$2" --arg s "$(printf '%s' "${3:-}" | shasum -a 256 | cut -c1-64)" --arg d "${4:-}"
}

# An attempt begins: a dispatch has an instance and a run to point at.
#
# Each connected repository keeps the base it had when it first appeared in the task (`repo_bases`),
# the same way the main one keeps `base_sha`: a later attempt is measured from it (`record_extra_repos`).
task_attempt_begin() {   # $1=task id $2=instance dir $3=dispatch id $4=kind (initial|continue)
  local tid="$1" idir="$2" did="$3" kind="${4:-initial}" rid base xb
  rid="$(tr -d '[:space:]' < "$idir/run-id" 2>/dev/null || true)"
  base="$(read_base_sha "$idir")"
  xb="$(cut -d$'\037' -f1,2 "$idir/extra-repos" 2>/dev/null \
        | jq -Rn '[inputs | split("\u001f") | select(length == 2 and .[0] != "" and .[1] != "") | {(.[0]): .[1]}] | add // {}' 2>/dev/null)"
  case "$xb" in '{'*) ;; *) xb='{}' ;; esac
  # One attempt is open at a time: one still open when the next begins (a second /continue before the
  # first got its verdict) is closed as superseded, and its late verdict is then stale.
  task_update "$tid" '
    .attempts |= (if length == 0 then . else
        (.[-1] |= (if .ended_at == null then .ended_at = $_now | .result = "superseded" | .disposition = "superseded" else . end))
      end)
    | .attempts += [{n:((.attempts | length) + 1), kind:$k, dispatch_id:$d, run_id:$r,
                   instance:$i, started_at:$_now, ended_at:null, result:null, review:null}]
    | .state = "running" | .state_reason = ""
    | .question = (if $k == "continue" then null else .question end)
    | .base_sha = (if (.base_sha // "") == "" then $b else .base_sha end)
    | .repo_bases = ($xb + (.repo_bases // {}))' \
    --arg k "$kind" --arg d "$did" --arg r "$rid" --arg i "$idir" --arg b "$base" --argjson xb "$xb" || return 1
  rm -f "$idir/gate-question.json" 2>/dev/null
  task_event "$tid" attempt-started "$(jq -nc --arg k "$kind" --arg d "$did" --arg r "$rid" '{attempt_kind:$k, dispatch_id:$d, run_id:$r}')"
}

# What the first preparation produced, kept for every later attempt. Only what is missing is saved:
# a follow-up does not prepare again, and its instance would otherwise overwrite the plan the task
# was agreed on with nothing.
TASK_MATERIAL="runspec.json plan.md peer-alignment.md research.md research.json design.md design.json"
task_material_save() {   # $1=task id $2=instance dir
  local tid="$1" idir="$2" m f
  m="$(task_dir "$tid")/material"; mkdir -p "$m" 2>/dev/null || return 0
  for f in $TASK_MATERIAL; do
    [ -s "$idir/$f" ] && [ ! -s "$m/$f" ] && cp -f "$idir/$f" "$m/$f" 2>/dev/null
  done
  return 0
}

# …and put back in front of an attempt. The runspec is what the review judges against, the plan is
# the context it reads beside it; with both restored, a fresh session is reviewed against the goal
# the task started with, not against the comment that reopened it.
task_material_restore() {   # $1=task id $2=instance dir
  local tid="$1" idir="$2" m f
  m="$(task_dir "$tid")/material"
  for f in $TASK_MATERIAL; do
    [ -s "$m/$f" ] && cp -f "$m/$f" "$idir/$f.tmp.$$" 2>/dev/null && mv -f "$idir/$f.tmp.$$" "$idir/$f"
  done
  return 0
}

# The review budget a bridge gave one task: `review-policy.json` in the run's folder, with the
# criteria copied beside it as `report-criteria.md`. Keys, all optional:
#   roundsCeiling     the most code-review rounds this task gets (0 = no ceiling)
#   reportMaxRounds   the most report-review rounds (0 = no limit)
#   reportCriteria    the copied criteria; they replace the server's own rule for reports
#   reportAtLimit     "accept": a report still failing at its limit is accepted with the notes
# Any report setting also asks for the report to be reviewed (`reportReview`).
REVIEW_POLICY_FILES="review-policy.json report-criteria.md"
review_policy_write() {   # $1=idir $2=rounds $3=report rounds $4=criteria file $5=at limit
  local idir="$1" crit=""
  rm -f "$idir/review-policy.json" "$idir/report-criteria.md" 2>/dev/null
  [ -n "$2$3$4$5" ] || return 0
  if [ -n "$4" ]; then
    cp -f "$4" "$idir/report-criteria.md.tmp.$$" 2>/dev/null \
      && mv -f "$idir/report-criteria.md.tmp.$$" "$idir/report-criteria.md" || return 1
    crit="$idir/report-criteria.md"
  fi
  jq -nc --arg r "$2" --arg rr "$3" --arg c "$crit" --arg al "$5" '
      (if $r  == "" then {} else {roundsCeiling: ($r|tonumber)} end)
    + (if $rr == "" and $c == "" and $al == "" then {} else {reportReview: true} end)
    + (if $rr == "" then {} else {reportMaxRounds: ($rr|tonumber)} end)
    + (if $c  == "" then {} else {reportCriteria: $c} end)
    + (if $al == "" then {} else {reportAtLimit: $al} end)' > "$idir/review-policy.json.tmp" 2>/dev/null \
    && mv -f "$idir/review-policy.json.tmp" "$idir/review-policy.json"
}
review_policy_save() {   # $1=task id $2=idir — the task keeps the policy its first attempt was sent with
  local m f; m="$(task_dir "$1")/material"; mkdir -p "$m" 2>/dev/null || return 0
  rm -f "$m/review-policy.json" "$m/report-criteria.md" 2>/dev/null
  for f in $REVIEW_POLICY_FILES; do [ -s "$2/$f" ] && cp -f "$2/$f" "$m/$f" 2>/dev/null; done
  return 0
}
review_policy_restore() {   # $1=task id $2=idir
  local m f; m="$(task_dir "$1")/material"
  rm -f "$2/review-policy.json" "$2/report-criteria.md" 2>/dev/null
  for f in $REVIEW_POLICY_FILES; do
    [ -s "$m/$f" ] && cp -f "$m/$f" "$2/$f.tmp.$$" 2>/dev/null && mv -f "$2/$f.tmp.$$" "$2/$f"
  done
  # The criteria path inside the policy names the folder it was written in; the copy is here now.
  if [ -s "$2/review-policy.json" ] && [ -s "$2/report-criteria.md" ]; then
    jq -c --arg c "$2/report-criteria.md" '.reportCriteria = $c' "$2/review-policy.json" > "$2/review-policy.json.tmp" 2>/dev/null \
      && mv -f "$2/review-policy.json.tmp" "$2/review-policy.json"
  fi
  return 0
}
# Put the task's policy into the current dispatch record, over whatever a pipeline set: the bridge
# that sent the task spoke last. Unrelated pipeline gates stay as they are.
review_policy_apply() {   # $1=idir
  local idir="$1"
  [ -s "$idir/review-policy.json" ] && [ -s "$idir/dispatch.json" ] || return 0
  jq -c --slurpfile p "$idir/review-policy.json" '.pipeline_gates = ((.pipeline_gates // {}) + $p[0])' \
     "$idir/dispatch.json" > "$idir/dispatch.json.pol.$$" 2>/dev/null \
    && mv -f "$idir/dispatch.json.pol.$$" "$idir/dispatch.json" || rm -f "$idir/dispatch.json.pol.$$" 2>/dev/null
  return 0
}

# Which state an attempt's end leaves the task in, from the gate's disposition and the worker's word.
task_state_for() {   # $1=disposition $2=declared result → state
  case "$1:$2" in
    passed:succeeded_changes)                    printf 'waiting_review' ;;
    passed:succeeded_no_change|passed:succeeded_research) printf 'done' ;;
    passed:*)                                    printf 'waiting_review' ;;
    *:needs_input)                               printf 'needs_input' ;;
    *:blocked|*:blocked_by_harness)              printf 'blocked' ;;
    *)                                           printf 'failed' ;;
  esac
}

# An attempt has ended: record it on the task, tell the bridge, and on a server let the session go.
# Called by the review gate when it settles a run (`mark_done`) and by the server's Codex policy.
# The state is on disk before anyone is told about it, so whatever a notification says can be read.
task_on_terminal() {   # $1=instance dir $2=disposition → 3 when the verdict was stale and nothing was written
  local idir="$1" disp="${2:-}" tid result state reason receipt repos q gen rid did cx rc
  tid="$(cat "$idir/task-id" 2>/dev/null || true)"
  [ -n "$tid" ] && task_exists "$tid" || return 0
  # Which worker this verdict is about, read before anything is published: once the state says
  # "settled" a follow-up may start, and the generation in this folder may then be its, not ours.
  gen="$(cat "$idir/worker-generation" 2>/dev/null || true)"
  # And only the attempt this run is: a late verdict from an attempt that has since been replaced
  # must not settle the one that replaced it.
  # The ids the caller took when it started (the review gate: TASK_RUN_ID / TASK_DISPATCH_ID), else
  # the folder's. A gate that ran for an hour must not read them now: a /continue may have given this
  # folder to the next attempt meanwhile.
  rid="${TASK_RUN_ID:-$(tr -d '[:space:]' < "$idir/run-id" 2>/dev/null || true)}"
  did="${TASK_DISPATCH_ID:-$(jq -r '.id // empty' "$idir/dispatch.json" 2>/dev/null || true)}"
  # Checked where it counts: under the task's lock, in the same step as the write below.
  result="$(jq -r '.result // empty' "$idir/outcome.json" 2>/dev/null)"
  state="$(task_state_for "$disp" "$result")"
  reason="$(jq -r '.reason // empty' "$idir/outcome.json" 2>/dev/null)"
  [ -n "$reason" ] || reason="$disp"
  [ "$disp" = stalled ] && reason=stalled
  receipt="$(jq -c . "$idir/report/receipt.json" 2>/dev/null || echo null)"
  repos="$(printf '%s' "$receipt" | jq -c '.repos // empty' 2>/dev/null)"
  [ -n "$repos" ] || repos="$(repos_state_json "$idir" "$(cat "$idir/project" 2>/dev/null)" 2>/dev/null || echo '[]')"
  case "$repos" in '['*) ;; *) repos='[]' ;; esac
  # Settled by the review gate: the commits its reviewer read (REVIEW_SNAPSHOT), not HEAD now. A
  # bridge publishes reviewed_sha, and a commit that landed after the verdict was never reviewed.
  repos="$(repos_as_reviewed "$repos")"
  q="$(jq -c '.question // null' "$idir/outcome.json" 2>/dev/null || echo null)"
  # The review's own question (review-gate.sh, spec_conflict_park): the reviewer disputes something
  # the task decided, and that is for the task's author to answer, whatever the worker declared.
  if [ "$disp" = needs-user ] && [ -s "$idir/gate-question.json" ]; then
    state=needs_input; reason=spec_conflict
    q="$(jq -c '{id, text, options}' "$idir/gate-question.json" 2>/dev/null || echo null)"
  fi
  # Whether Codex took part in all of this attempt, so a bridge can say so without opening the app:
  # a task that passed with Codex missing from a step is not reported as an ordinary pass.
  cx="$(codex_participation "$idir" 2>/dev/null)"
  case "$cx" in '{'*) ;; *) cx='{"status":"full"}' ;; esac
  [ "$state" = needs_input ] || q=null
  # What a passing review saw in each repository: the next attempt has work to review there only
  # once HEAD moves past it.
  task_update_attempt "$tid" "$did" "$rid" '
    .state = $st | .state_reason = $why | .repos = $repos
    | .repo_reviewed = ((.repo_reviewed // {}) + (if $disp == "passed"
        then ([$repos[] | select((.path // "") != "" and (.reviewed_sha // "") != "") | {(.path): .reviewed_sha}] | add // {})
        else {} end))
    | .last_receipt = $rc | .question = $q
    | .last_outcome = $oc
    | .codex = $cx
    | .attempts |= (if length == 0 then . else
        (.[-1] |= (.ended_at = $_now | .result = $res | .review = $disp | .disposition = $disp | .codex = $cx))
      end)' \
    --arg st "$state" --arg why "$reason" --argjson repos "$repos" --argjson rc "$receipt" \
    --argjson q "$q" --arg res "$result" --arg disp "$disp" \
    --argjson cx "$cx" \
    --argjson oc "$(jq -c . "$idir/outcome.json" 2>/dev/null || echo null)"; rc=$?
  if [ "$rc" = 3 ]; then
    task_event "$tid" stale-verdict "$(jq -nc --arg d "$disp" --arg did "$did" '{disposition:$d, dispatch_id:$did}')"
    return 3
  fi
  [ "$rc" = 0 ] || return 1
  # Only now: a stale verdict must not leave its folder's files as the task's material either.
  task_material_save "$tid" "$idir"
  task_event "$tid" attempt-ended "$(jq -nc --arg d "$disp" --arg r "$result" --arg why "$reason" --argjson cx "$cx" \
      '{disposition:$d, result:(if $r == "" then null else $r end), reason:$why, codex:$cx}')"
  task_notify "$tid"
  [ "${SUPERVISOR_PROFILE:-}" = server ] && task_release_session "$idir" "$gen"
  return 0
}

# An attempt stopped from outside (`night-shift stop`: a bridge's timeout, a person) with no verdict.
# It used to leave the record as it was: `repos: []`, `ended_at: null`, no material — and the brief of
# the continuation then had nothing under "where the work is". The attempt is closed here the way a
# verdict closes it, with the commits as they stand (none of them reviewed: no review finished), and
# `result: stopped`. The task's state is left alone: the bridge that stopped it decides what it is
# now. A verdict that settled the attempt first is never overwritten.
task_on_stop() {   # $1=instance dir
  local idir="$1" tid rid did repos
  tid="$(cat "$idir/task-id" 2>/dev/null || true)"
  [ -n "$tid" ] && task_exists "$tid" || return 0
  rid="$(tr -d '[:space:]' < "$idir/run-id" 2>/dev/null || true)"
  did="$(jq -r '.id // empty' "$idir/dispatch.json" 2>/dev/null || true)"
  [ -z "$(task_get "$tid" '.attempts[-1].ended_at')" ] || return 0
  repos="$(repos_state_json "$idir" "$(cat "$idir/project" 2>/dev/null)" 2>/dev/null || echo '[]')"
  case "$repos" in '['*) ;; *) repos='[]' ;; esac
  # Whose attempt it is and whether a verdict closed it first: decided under the lock, with the write.
  TASK_ATTEMPT_OPEN_ONLY=1 task_update_attempt "$tid" "$did" "$rid" '
    .repos = (if ($repos | length) > 0 then [$repos[] | del(.reviewed_sha)] else .repos end)
    | .attempts |= (if length == 0 then . else
        (.[-1] |= (if .ended_at == null then .ended_at = $_now | .result = "stopped" | .disposition = "stopped" else . end))
      end)' \
    --argjson repos "$repos" || return 0
  task_material_save "$tid" "$idir"
  task_event "$tid" attempt-stopped '{}'
}

# Tell the bridge to look now: SUPERVISOR_ON_OUTCOME=/path/script is run with the task file's path.
# A hint, not a delivery: detached, ten seconds at most, its failure is logged and nothing else. The
# bridge still reconciles with `night-shift task show`, and may hear about one change twice.
task_notify() {   # $1=task id
  local hook="${SUPERVISOR_ON_OUTCOME:-}" f
  [ -n "$hook" ] && [ -x "$hook" ] || return 0
  f="$(task_file "$1")"
  ( TASK_ID="$1" TASK_STATE="$(task_get "$1" .state)" \
      perl -e 'alarm shift; exec @ARGV' 10 "$hook" "$f" >> "$SUP_STATE/on-outcome.log" 2>&1 \
      || echo "$(date '+%F %T') [on-outcome] $hook exited non-zero for $1" >> "$SUP_STATE/supervisor.log" ) \
    </dev/null >/dev/null 2>&1 &
  return 0
}

# On a server a settled attempt does not keep its session: the task is safe in its record, and a
# session left at its prompt would only be found by the idle timers hours later. Stopped from the
# outside a few seconds on, because this runs inside that session's own Stop hook — and only the
# worker generation that was settled, so a newer attempt started meanwhile is never the one stopped.
task_release_session() {   # $1=instance dir $2=the settled worker's generation
  local idir="$1" gen="${2:-}" proj ses
  proj="$(cat "$idir/project" 2>/dev/null || true)"; [ -n "$proj" ] || return 0
  # No generation to compare means no way to tell this worker from a successor: nothing is stopped.
  [ -n "$gen" ] || return 0
  ses="$(cat "$idir/session" 2>/dev/null || session_name "$(slug_for "$proj")")"
  nohup bash -c '. "$1/supervisor-lib.sh" >/dev/null 2>&1; sleep "$2"; task_release_now "$3" "$4" "$5" "$6"' \
    release "$_SUP_BIN_DIR" "${SUPERVISOR_RELEASE_DELAY:-5}" "$idir" "$gen" "$proj" "$ses" \
    >> "$SUP_STATE/supervisor.log" 2>&1 &
  return 0
}

# The release itself, under the folder's lifecycle lock: the generation is checked and the session
# taken down with nothing able to start in between. A different generation means a newer attempt
# owns the folder now, and then nothing at all is touched.
task_release_now() {   # $1=instance dir $2=generation $3=project $4=session
  local idir="$1" gen="$2" proj="$3" ses="$4"
  task_lifecycle_lock "$proj" 60 || { echo "$(date '+%F %T') [task] release of $(basename "$idir") skipped — the folder is busy"; return 0; }
  if [ "$(cat "$idir/worker-generation" 2>/dev/null)" != "$gen" ]; then
    task_lifecycle_unlock "$proj"; return 0
  fi
  "$_SUP_BIN_DIR/night-shift.sh" stop --generation "$gen" "$proj"
  tmux kill-session -t "$ses" 2>/dev/null || true
  task_lifecycle_unlock "$proj"
}

# Is an attempt of this task working right now? `running` on the record and an instance that is
# still there with the same run — a record left `running` by a machine that rebooted mid-attempt is
# not a reason to refuse every message after it.
task_busy() {   # $1=task id
  local tid="$1" idir rid
  [ "$(task_get "$tid" .state)" = running ] || return 1
  idir="$(task_get "$tid" '.attempts[-1].instance')"
  rid="$(task_get "$tid" '.attempts[-1].run_id')"
  [ -n "$idir" ] && [ -d "$idir" ] || return 1
  [ -z "$rid" ] || [ "$(tr -d '[:space:]' < "$idir/run-id" 2>/dev/null)" = "$rid" ] || return 1
  tmux has-session -t "$(cat "$idir/session" 2>/dev/null || echo none)" 2>/dev/null
}

# The brief a fresh session gets for a follow-up: the task as it was agreed, where its work stands,
# and what is new. The goal and the criteria come from the record, never from the new message.
task_brief() {   # $1=task id $2=message $3=source $4=author [$5=question id answered]
  local tid="$1" msg="$2" src="${3:-other}" who="${4:-unknown}" qid="${5:-}" m n crit repos r
  m="$(task_dir "$tid")/material"
  n="$(task_get "$tid" '.attempts | length')"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; n=$((n + 1))
  crit=""
  [ -s "$m/runspec.json" ] && crit="$(jq -r '(.acceptance // [])[] | "- " + (if type == "string" then . else (.text // tostring) end)' "$m/runspec.json" 2>/dev/null)"
  repos="$(task_get "$tid" '.repos' )"; [ -n "$repos" ] || repos='[]'
  printf 'ПРОДОВЖЕННЯ ЗАДАЧІ %s, спроба %s. Це та сама задача, а не нова: її мета й критерії нижче не змінюються від нового повідомлення. Нове повідомлення каже, що поправити або доробити.\n\n' "$tid" "$n"
  printf '## Мета задачі (як її поставили)\n%s\n\n' "$(task_get "$tid" .objective)"
  if [ -n "$crit" ]; then
    printf '## Критерії приймання\n%s\n\n' "$crit"
  elif [ -s "$m/plan.md" ]; then
    printf '## Критерії\nДив. узгоджений план задачі (він лежить у теці прогону як plan.md і є в контексті ревʼю).\n\n'
  fi
  printf '## Де робота зараз\n'
  printf '%s' "$repos" | jq -r '.[] | "- \(.path): гілка \(.branch // "?"), база \((.base_sha // "?")[0:12]), останній переглянутий коміт \((.reviewed_sha // "?")[0:12])"' 2>/dev/null
  printf '%s' "$repos" | jq -r '.[] | [.path, .base_sha] | @tsv' 2>/dev/null | while IFS=$'\t' read -r r b; do
    [ -d "$r" ] && [ -n "$b" ] || continue
    printf '\n%s, коміти задачі:\n' "$r"
    git -C "$r" log --oneline "$b..HEAD" 2>/dev/null | head -20
    git -C "$r" diff --stat "$b" 2>/dev/null | tail -1
  done
  printf '\n'
  # What the review still has open (the task's ledger, review-gate.sh). The next review is a check of
  # exactly these ids, not a new reading.
  local lf lopen
  lf="$SUP_STATE/review-ledger-$(task_key "$tid")"
  if [ -s "$lf" ]; then
    lopen="$(python3 "$_SUP_BIN_DIR/lib/review-ledger.py" open "$lf" 2>/dev/null)"
    if [ -n "$lopen" ]; then
      printf '## Що лишилось відкритим з рев'"'"'ю\nНаступне рев'"'"'ю перевірить саме ці пункти за їхніми id. Пункт, що суперечить явному рішенню в задачі, не латай: заяви needs_input з цитатою задачі.\n%s\n\n' "$lopen"
    fi
  fi
  if [ -n "$qid" ]; then
    printf '## Питання, на яке це відповідь\n%s\n\n' "$(task_get "$tid" '.question.text')"
  fi
  printf '## Нове\n%s\n\n' "$(untrusted_frame "$src" "$who" "$msg")"
  printf '## Що зробити\nВнеси потрібні зміни в ту саму гілку задачі, закоміть усе, перевір і оголоси результат. Те, що вже прийняте раніше, не переписуй без потреби.\n'
}

# The record as the bridge reads it.
# `attempt_live` says whether a `running` record still has its session: after a reboot a task can
# read `running` with nothing behind it, and that is the bridge's cue to send the work on again.
task_show_json() {   # $1=task id
  local live=false
  task_exists "$1" || return 1
  task_busy "$1" && live=true
  jq -c --argjson live "$live" '{schema, task_id, state, state_reason, attempt_live: $live, created_at, updated_at, objective, source, author,
          project, branch, base_ref, base_sha, repos, question,
          attempts: [.attempts[] | {n, kind, dispatch_id, run_id, started_at, ended_at, result, review}],
          receipt: .last_receipt, outcome: .last_outcome}' "$(task_file "$1")"
}
