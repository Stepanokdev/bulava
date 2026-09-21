#!/bin/bash
set -u
# Which contract this gate honours, read from the FILE by anything that needs to know whether the
# hook actually wired into the worker is the one shipped alongside the rest of the engine. Two
# checkouts on one machine is normal here, the worker's settings name this file by absolute path,
# and a gate from before protocol 2 does not park on a Codex limit — it finishes the run as debt
# and says nothing. Bump it whenever a promise made elsewhere depends on code in this file.
GATE_PROTOCOL=2
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_DIR="$(cd "$HOOK_DIR/../supervisor" && pwd)"
BIN_DIR="$(cd "$HOOK_DIR/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
STATE_DIR="$SUP_STATE"
LOG="$STATE_DIR/supervisor.log"
MAX_ROUNDS=$SUPERVISOR_MAX_ROUNDS               # from supervisor/config.sh
USAGE_GUARD_PCT=$SUPERVISOR_USAGE_GUARD         # "
used=0
strip_paid_api_env "$LOG" >/dev/null 2>&1 || true   # keep codex on the subscription

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')
transcript=$(echo "$input" | jq -r '.transcript_path // ""')
cwd=$(echo "$input" | jq -r '.cwd // "."')
mkdir -p "$STATE_DIR"

scope="$(supervision_scope "$cwd")"
[ -n "$scope" ] || exit 0
if [ "${scope%%:*}" = "instance" ]; then
  IDIR_SCOPE="$(instance_dir "${scope#instance:}")"
  # Which directory the work is IN, as opposed to where the worker happened to be standing when it
  # stopped. The scope question above is rightly asked of the folder — that is what decides whether
  # this run is supervised at all — but everything after it means "the repository under review",
  # and a SUBFOLDER is a perfectly ordinary place for a worker to end a turn.
  #
  # It is not a theoretical difference. A run that ended inside `engine/` had its registered checks
  # executed from there: `bash engine/tests/…` came back 127 and xcodebuild reported that the
  # project "does not exist". Both were recorded as FAILURES of the work, and the review then
  # argued with evidence gathered in the wrong folder.
  _proj="$(run_project_dir "$IDIR_SCOPE" "$cwd")"
  [ -d "$_proj" ] && cwd="$_proj"
  # The review runs on the Codex the composer names. Inheriting the session's launch line was
  # right until the director could change the choice mid-conversation; the run's own file is the
  # newer answer, and both are written from the same choices.
  run_env_load "$IDIR_SCOPE"
  PAUSED_FILE="$IDIR_SCOPE/paused-for-limit.json"
  DONE_FILE="$IDIR_SCOPE/done"
else
  PAUSED_FILE="$STATE_DIR/paused-for-limit.json"
  DONE_FILE=""
fi

RUN_KEY="$session_id"
if [ -n "${IDIR_SCOPE:-}" ]; then _rk="$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)"; [ -n "$_rk" ] && RUN_KEY="$_rk"; fi
if [ -n "${IDIR_SCOPE:-}" ]; then
  # With an OWNER in it. The marker used to be an empty file, so a Codex that died mid-review left
  # behind something with no timeout and nothing anywhere that cleared it: every later message in
  # the conversation then waited on a reviewer that had already gone.
  jq -nc --argjson pid "$$" --arg sid "$session_id" --argjson at "$(date +%s)" \
     '{pid:$pid, session_id:$sid, at:$at}' > "$IDIR_SCOPE/review-active.tmp" 2>/dev/null \
    && mv -f "$IDIR_SCOPE/review-active.tmp" "$IDIR_SCOPE/review-active" 2>/dev/null \
    || : > "$IDIR_SCOPE/review-active" 2>/dev/null || true
  printf '%s\n' preparing > "$IDIR_SCOPE/review-stage" 2>/dev/null || true
  trap 'rm -f "$IDIR_SCOPE/review-active" "$IDIR_SCOPE/review-active.tmp" "$IDIR_SCOPE/review-stage" 2>/dev/null || true' EXIT
fi
review_stage() { # $1=preparing|verifying|reviewing
  [ -n "${IDIR_SCOPE:-}" ] && printf '%s\n' "$1" > "$IDIR_SCOPE/review-stage" 2>/dev/null || true
}
BASE_SHA=""
BASE_SHA="$(read_base_sha "${IDIR_SCOPE:-}")"
PLAN_TEXT=""
[ -n "${IDIR_SCOPE:-}" ] && [ -f "$IDIR_SCOPE/plan.md" ] && PLAN_TEXT="$(head -c 6000 "$IDIR_SCOPE/plan.md" 2>/dev/null)"

CONTRACT_TEXT=""
CHALLENGES_TEXT=""
CRIT_CAP=0
if [ -n "${IDIR_SCOPE:-}" ] && runspec_present "$IDIR_SCOPE"; then
  _obj="$(runspec_objective "$IDIR_SCOPE")"
  _crit="$(runspec_acceptance "$IDIR_SCOPE" | sed 's/\t/  /')"
  CRIT_CAP="$(criteria_amendment_cap "$IDIR_SCOPE")"
  _decisions=""
  _crid_c="$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)"
  _dfile="$(run_dir "${_crid_c:-unknown}")/criteria-decisions.jsonl"
  [ -s "$_dfile" ] && _decisions="$(jq -r 'select(.decision=="superseded") | .criterion' "$_dfile" 2>/dev/null | tr '\n' ' ')"
  if [ -n "$_crit" ]; then
    if [ -n "$_decisions" ]; then
      _crit="$(printf '%s\n' "$_crit" | while IFS= read -r _l; do
        case " $_decisions " in
          *" ${_l%%  *} "*) printf '%s\n' "$_l  [SUPERSEDED by review — do not count as unmet]" ;;
          *) printf '%s\n' "$_l" ;;
        esac
      done)"
    fi
    CONTRACT_TEXT="OBJECTIVE: ${_obj:-(not stated)}

ACCEPTANCE CRITERIA (the agreed contract for this run — judge against THESE):
$_crit"
  fi
  if [ -s "$IDIR_SCOPE/challenges.jsonl" ]; then
    _crid="$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)"
    CHALLENGES_TEXT="$(jq -r --arg rid "$_crid" \
      'select((.run_id // "") == $rid) |
       "- \(.criterion) — причина: \(.reason)\n  заміна: \(.replacement // "(немає — критерій просто недійсний)")\n  доказ: \(.evidence)"' \
      "$IDIR_SCOPE/challenges.jsonl" 2>/dev/null)"
  fi
fi

# What Codex missed in this run, said to Codex.
#
# The note was being written and never read: `codex_owe` recorded that the second engineer had been
# out during preparation or during a consultation, and nothing anywhere used it. It belongs exactly
# here — a reviewer judging a run whose brief it never saw, or whose questions it never answered,
# is judging with a gap it cannot otherwise know about.
OWED_BLOCK=""
if [ -n "${IDIR_SCOPE:-}" ] && codex_owed "$IDIR_SCOPE"; then
  _owed_why="$(jq -r '.reason // ""' "$(codex_owed_file "$IDIR_SCOPE")" 2>/dev/null)"
  _owed_stage="$(jq -r '.stage // ""' "$(codex_owed_file "$IDIR_SCOPE")" 2>/dev/null)"
  _owed_qs="$(codex_unanswered_consultations "$IDIR_SCOPE" 2>/dev/null || true)"
  OWED_BLOCK="
WHAT YOU MISSED IN THIS RUN (you were unavailable at the time — this is not the worker's doing):
stage: ${_owed_stage:-?}${_owed_why:+ — $_owed_why}${_owed_qs:+
questions you were asked and never answered:
$_owed_qs}
Judge the work on its merits; where the gap plausibly explains a decision, say so rather than
counting it against the worker.
"
fi

CHALLENGE_BLOCK=""
CRITERIA_LINE_SPEC=""
if [ -n "$CHALLENGES_TEXT" ]; then
  CHALLENGE_BLOCK="STEP 2b — CHALLENGED CRITERIA. The run claims these were wrong when the work started.
It may propose; YOU decide. For each one:
  * Check the claim YOURSELF at the BASE commit ${BASE_SHA:-(base)} — read the file as it was there.
    Never judge it from the worker's current tree: otherwise breaking a feature would be a way to
    prove its criterion unreachable.
  * ACCEPT (superseded) only if the criterion was impossible or inapplicable AT THAT COMMIT and the
    replacement preserves the objective. Then judge the REPLACEMENT in its place.
  * REJECT (stands) if it was merely hard, inconvenient or untested. Inability to test is NOT
    grounds — that is unproven work, and unproven work is a review failure, not a void criterion.
  * Scope, behaviour, security, payments, or anything the director asked for explicitly is NOT yours
    to accept. Leave it standing and say it needs him.
You may accept at most ${CRIT_CAP:-1} in this run. If more than that are genuinely wrong then the
plan itself was wrong: say so and return STATE: BLOCKED.

$CHALLENGES_TEXT"
  CRITERIA_LINE_SPEC="CRITERIA: one decision per challenged criterion, space separated — e.g. CRITERIA: AC-005=superseded AC-007=stands"
fi

REPORTS_DIR=""
if [ -n "${IDIR_SCOPE:-}" ]; then REPORTS_DIR="$(run_reports_dir "${scope#instance:}")"; mkdir -p "$REPORTS_DIR" 2>/dev/null || true; fi
BLOCKED_OUT="${REPORTS_DIR:+$REPORTS_DIR/blocked.md}"
DEBT_OUT="${REPORTS_DIR:+$REPORTS_DIR/review-debt.md}"
REVIEW_JSON="${REPORTS_DIR:+$REPORTS_DIR/review.json}"
: "${BLOCKED_OUT:=$STATE_DIR/blocked-$session_id.md}"
: "${DEBT_OUT:=$STATE_DIR/review-debt-$session_id.md}"

legacy_note() {  # $1=dest-var-value  $2=repo-basename  (appends stdin to both)
  local body; body="$(cat)"
  printf '%s' "$body" >> "$1"
  if [ "${SUPERVISOR_LEGACY_REPO_NOTES:-0}" = 1 ]; then printf '%s' "$body" >> "$cwd/$2"; fi
}

emit_review_json() {
  [ -n "${REVIEW_JSON:-}" ] || return 0
  jq -n --arg sid "$session_id" --arg st "${1:-}" --arg vd "${2:-}" \
        --arg disp "${3:-}" --arg mode "$(runspec_mode "${IDIR_SCOPE:-}")" \
        --arg round "$(( ${rounds:-0} + 1 ))" --arg verify "${verify_status:-}" \
        --arg findings "${4:-}" --arg ts "$(date '+%F %T')" \
        --arg reviewer "${REVIEWER:-codex}" \
     '{session_id:$sid, ts:$ts, mode:$mode, round:($round|tonumber),
       state:$st, verdict:$vd, disposition:$disp, verify_status:$verify,
       reviewer:$reviewer, findings:$findings}' > "$REVIEW_JSON" 2>/dev/null || true
}

note_progress() {
  [ -n "${IDIR_SCOPE:-}" ] || return 0
  local kind="$1" n="$2" max="$3" f="${4:-}" prev="${5:-}" st="${6:-}" stmax="${7:-}"
  jq -n --arg kind "$kind" --argjson n "${n:-0}" --argjson max "${max:-0}" \
        --arg f "$f" --arg prev "$prev" --arg st "$st" --arg stmax "$stmax" \
        --arg ts "$(date '+%F %T')" \
    '{kind:$kind, round:$n, max:$max, ts:$ts}
     + (if $f    != "" then {findings:      ($f|tonumber)}    else {} end)
     + (if $prev != "" then {prev_findings: ($prev|tonumber)} else {} end)
     + (if $st   != "" then {stall:         ($st|tonumber)}   else {} end)
     + (if $stmax != "" then {stall_limit:  ($stmax|tonumber)} else {} end)' \
    > "$IDIR_SCOPE/review-progress.json.tmp" 2>/dev/null \
    && mv -f "$IDIR_SCOPE/review-progress.json.tmp" "$IDIR_SCOPE/review-progress.json" 2>/dev/null || true
}

clear_progress() {
  [ -n "${IDIR_SCOPE:-}" ] || return 0
  rm -f "$IDIR_SCOPE/review-progress.json" "$IDIR_SCOPE/review-progress.json.tmp" 2>/dev/null || true
}

rotate_log "$LOG"; rotate_log "$CODEX_LOG"
log() {
  local who=""
  [ -n "${IDIR_SCOPE:-}" ] && who="[$(basename "$IDIR_SCOPE")] "
  echo "$(date '+%F %T') [review-gate] ${who}$*" >> "$LOG"
}
mark_done() {
  local disposition="${1:-passed}"
  clear_progress
  [ -n "${DONE_FILE:-}" ] && printf '%s\n' "$disposition" > "$DONE_FILE"
  journal_event "${IDIR_SCOPE:--}" terminal "$disposition" "$(jq -nc --arg d "$disposition" '{disposition:$d, source:"gate"}')"
  if [ -n "${IDIR_SCOPE:-}" ] && [ -f "$IDIR_SCOPE/dispatch.json" ]; then
    _did="$(jq -r '.id // empty' "$IDIR_SCOPE/dispatch.json" 2>/dev/null || true)"
    if [ -n "$_did" ]; then
      mkdir -p "$IDIR_SCOPE/dispatches" 2>/dev/null || true
      printf '%s\n' "$disposition" > "$IDIR_SCOPE/dispatches/$_did.done" 2>/dev/null || true
    fi
  fi
  restamp_receipt "$disposition"
  if [ "$disposition" = passed ] && [ -n "${IDIR_SCOPE:-}" ] && [ -f "$IDIR_SCOPE/direct-chat" ]; then
    _accepted_head="$(resolve_base_sha "$cwd")"
    [ -n "$_accepted_head" ] && printf '%s\n' "$_accepted_head" > "$IDIR_SCOPE/base-sha"
  fi
  [ -n "${harness_file:-}" ] && rm -f "$harness_file" 2>/dev/null
  # A permission to go on without Codex belonged to this piece of work and dies with it. Left
  # behind, it would be the one thing in here capable of waving the next run past the reviewer.
  codex_decision_clear "${IDIR_SCOPE:-}"
  rm -f "$STATE_DIR/unreachable-$RUN_KEY" 2>/dev/null || true
  return 0
}

restamp_receipt() {  # $1 = passed | debt | needs-user | scope_violation
  local idir="${IDIR_SCOPE:-}" src review
  [ -n "$idir" ] || return 0
  src="$idir/report/receipt.json"
  [ -f "$src" ] || return 0
  case "${1:-}" in
    passed)          review=passed ;;
    debt)            review=debt ;;
    needs-user|scope_violation) review=failed ;;
    *)               review="" ;;
  esac
  [ -n "$review" ] || return 0

  local why=""
  if [ "$review" != passed ] && [ -f "$idir/reports/review.json" ]; then
    why="$(jq -r '.findings // ""' "$idir/reports/review.json" 2>/dev/null | head -c 4000)"
  fi

  local rid findings
  rid="$(cat "$idir/run-id" 2>/dev/null || true)"
  findings="$(findings_json "$idir" "$rid")"
  jq -c --arg rv "$review" --arg why "$why" --argjson f "${findings:-[]}" \
     '.review = $rv | .review_why = $why | .findings = $f' "$src" > "$src.tmp" 2>/dev/null \
    && mv -f "$src.tmp" "$src" 2>/dev/null || { rm -f "$src.tmp" 2>/dev/null; return 0; }
  python3 "$BIN_DIR/receipt-render.py" "$idir/report/report.html" < "$src" >/dev/null 2>&1 || true
}

if [ "${SUPERVISOR_OUTCOME_PROTOCOL:-1}" = 1 ] && [ -n "${IDIR_SCOPE:-}" ] && [ -s "$IDIR_SCOPE/outcome.json" ]; then
  oc_result="$(jq -r '.result // empty' "$IDIR_SCOPE/outcome.json" 2>/dev/null)"
  oc_rid="$(jq -r '.run_id // empty' "$IDIR_SCOPE/outcome.json" 2>/dev/null)"
  cur_rid="$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)"
  if outcome_valid "$oc_result" && outcome_short_circuit "$oc_result" \
     && [ -n "$oc_rid" ] && [ "$oc_rid" = "$cur_rid" ]; then
    rounds=0; oc_mode="$(runspec_mode "${IDIR_SCOPE:-}")"
    oc_reset="rm -f $STATE_DIR/rounds-$RUN_KEY $STATE_DIR/outcome-nudge-$RUN_KEY"
    case "$oc_result" in
      blocked|needs_input|blocked_by_harness)
        emit_review_json BLOCKED N/A needs-user "worker declared: $oc_result"; $oc_reset 2>/dev/null || true
        mark_done needs-user; log "outcome: $oc_result → needs-user (no review round)"; exit 0 ;;
      failed)
        emit_review_json COMPLETE FAIL needs-user "worker declared: failed"; $oc_reset 2>/dev/null || true
        mark_done needs-user; log "outcome: failed → needs-user (no review round)"; exit 0 ;;
      succeeded_no_change|succeeded_research)
        if [ -n "$BASE_SHA" ] && git -C "$cwd" cat-file -e "$BASE_SHA" 2>/dev/null \
           && oc_diff="$(git -C "$cwd" diff "$BASE_SHA" --stat 2>/dev/null)" \
           && oc_unt="$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null)"; then
          oc_changed="$oc_diff$oc_unt"
          if [ -n "$oc_changed" ]; then
            log "declared $oc_result but diff is NON-empty — NOT honoring, routing to normal review"
          elif [ "$oc_mode" = broad ]; then
            emit_review_json COMPLETE PASS debt "Declared '$oc_result' with an empty diff — no machine verification of a no-change/research claim is possible; needs human review."
            $oc_reset 2>/dev/null || true
            mark_done debt; log "outcome: $oc_result (broad, empty diff) → debt (human review, not auto-passed)"; exit 0
          else
            emit_review_json COMPLETE FAIL needs-user "Scoped run declared '$oc_result' with no diff — verify against acceptance."
            $oc_reset 2>/dev/null || true; mark_done needs-user
            log "outcome: $oc_result (scoped, empty diff) → needs-user"; exit 0
          fi
        else
          log "declared $oc_result but cannot CONFIRM empty diff (no valid base / git error) — NOT honoring, routing to review"
        fi ;;
    esac
  fi
fi

if [ -n "${IDIR_SCOPE:-}" ] && [ -s "$IDIR_SCOPE/findings.jsonl" ]; then
  _crid="$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)"
  _last="$(jq -rc --arg rid "$_crid" 'select((.class=="blocker" or .class=="blocker_resolved") and (.run_id // "")==$rid) | [.class, .text] | @tsv' "$IDIR_SCOPE/findings.jsonl" 2>/dev/null | tail -1)"
  _blk=""
  case "$_last" in blocker$'\t'*) _blk="${_last#*$'\t'}" ;; esac
  if [ -n "${_blk:-}" ] && [ -n "$_crid" ]; then
    emit_review_json BLOCKED N/A needs-user "worker blocker finding: $_blk"
    mark_done needs-user
    log "worker 'blocker' finding (fresh) — parked as needs-user (not a worker defect)"
    exit 0
  fi
fi

nudge_or_park_no_outcome() {
  [ "${SUPERVISOR_OUTCOME_PROTOCOL:-1}" = 1 ] && [ -n "${IDIR_SCOPE:-}" ] || { log "no diff, no outcome — legacy silent stop (protocol off / no instance)"; exit 0; }
  local nf n declared reason; nf="$STATE_DIR/outcome-nudge-$RUN_KEY"
  n=$(cat "$nf" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac      # a corrupted counter must not crash the hook (set -u arithmetic)
  n=$((n + 1)); echo "$n" > "$nf"
  declared=""; [ -s "$IDIR_SCOPE/outcome.json" ] && declared="$(jq -r '.result // empty' "$IDIR_SCOPE/outcome.json" 2>/dev/null)"
  if [ "$n" -gt "${SUPERVISOR_OUTCOME_NUDGE_MAX:-2}" ]; then
    emit_review_json HANDOFF N/A needs-user "No changes and no usable outcome after $n nudges (declared='${declared:-none}')."
    rm -f "$nf" 2>/dev/null || true   # resolved (parked) — don't let the count leak into a reused session
    mark_done needs-user
    log "no diff + no usable outcome after $n nudges (declared='${declared:-none}') — parked as needs-user"
    exit 0
  fi
  if [ "$declared" = succeeded_changes ]; then
    reason="🌙 Ти задекларував succeeded_changes, але діффу немає — зміни не збережено або не в git. Або зроби реальну зміну коду й заверши, або заяви інший результат: $IDIR_SCOPE/report-outcome succeeded_no_change|succeeded_research|blocked|needs_input \"підсумок\" (спроба $n/${SUPERVISOR_OUTCOME_NUDGE_MAX:-2})."
  else
    reason="🌙 Ти завершив хід, але НЕ залишив ні змін коду, ні задекларованого результату. Якщо задача завершена — заяви РЕЗУЛЬТАТ рівно один раз:
$IDIR_SCOPE/report-outcome <result> \"підсумок\"
(succeeded_no_change | succeeded_research | blocked | needs_input | failed; succeeded_changes лише якщо реально є зміни коду). Якщо ще НЕ готово — продовжуй роботу до завершення (спроба $n/${SUPERVISOR_OUTCOME_NUDGE_MAX:-2})."
  fi
  log "no diff + no usable outcome — nudging (attempt $n/${SUPERVISOR_OUTCOME_NUDGE_MAX:-2}, declared='${declared:-none}')"
  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
  exit 0
}

: "${SUPERVISOR_MAX_PAUSE_SECONDS:=21600}"   # 6h
: "${SUPERVISOR_RECHECK_SECONDS:=1800}"      # 30m when the reset time makes no sense
sane_resume_at() {  # $1 = claimed reset epoch → an epoch to actually wait for
  local at="${1:-0}" now; now="$(date +%s)"
  if [ "${at:-0}" -gt "$now" ] && [ $(( at - now )) -le "$SUPERVISOR_MAX_PAUSE_SECONDS" ]; then
    printf '%s' "$at"
  else
    printf '%s' $(( now + SUPERVISOR_RECHECK_SECONDS ))
  fi
}

# Asked through the one reader that knows what a reading is WORTH.
#
# These branches used to read the percentages straight out of the file, which meant they believed
# anything in it. Codex's own fallback scrapes a number out of a session log written hours ago and
# writes it down with the current timestamp: a long-gone 99% then looked like a current one. For
# the Claude branch that re-parked a run that was free; for the Codex branch below it did worse —
# it finished the run as review DEBT, telling the director a weekly limit was spent when it was
# not, and shipping the work unreviewed on the strength of it.
_claude_state="$(provider_state claude)"
used="$(printf '%s' "$_claude_state" | awk '{print $3}')"
case "$used" in ''|*[!0-9]*) used=0 ;; esac
if [ "${_claude_state%% *}" = exhausted ]; then
  resets_at="$(printf '%s' "$_claude_state" | awk '{print $2}')"
  resume_at="$(sane_resume_at "${resets_at:-0}")"
  # Whose limit, which run, which piece of work. Without those three the watchdog cannot tell a
  # pause that still applies from one left over by work that has since finished — and it used to
  # resume from either, into whatever happened to be running by then.
  if [ -n "${IDIR_SCOPE:-}" ]; then
    pause_record "$IDIR_SCOPE" claude "$resume_at" "usage guard" "$session_id"
  else
    jq -n --arg sid "$session_id" --argjson at "$resume_at" \
      '{provider:"claude", session_id:$sid, resume_after:$at, reason:"usage guard"}' \
      > "$PAUSED_FILE"
  fi
  log "Claude out (${used}%) — allowing stop, watchdog resumes at $(date -r "$resume_at" '+%F %H:%M' 2>/dev/null || echo "$resume_at")"
  exit 0
fi

# Through the same seam every other caller uses. Hard-coding the path meant a test could not stop
# the gate from reading the MACHINE's real Codex quota: with the window genuinely near its guard,
# suites about the gate's own logic started failing for a reason that had nothing to do with them.
"${SUPERVISOR_CODEX_USAGE_CMD:-$BIN_DIR/codex-usage.sh}" >/dev/null 2>&1 || true
codex_used=0
_codex_state="$(provider_state codex)"
codex_used="$(printf '%s' "$_codex_state" | awk '{print $3}')"
case "$codex_used" in ''|*[!0-9]*) codex_used=0 ;; esac
if [ "${_codex_state%% *}" = exhausted ]; then
  codex_resets="$(printf '%s' "$_codex_state" | awk '{print $2}')"
  case "$codex_resets" in ''|*[!0-9]*) codex_resets=0 ;; esac
  _codex_wait=$(( codex_resets - $(date +%s) ))
  # A window that ran out no longer decides anything by itself.
  #
  # This used to compare the wait against six hours and, finding it longer, finish the run as DEBT.
  # But the window that actually runs out is the WEEKLY one and its reset is days away, so the
  # comparison was never really a comparison: every real exhaustion took the debt branch, and a
  # night's work went out unreviewed. Waiting longer is not the fix either — five days of silence
  # is its own failure. What the reset time decides is WHO is asked, not whether to carry on:
  #
  #   back within the day  — waited out in silence, the watchdog resumes when the meter clears;
  #   longer, or unreadable — the director's call, and the run stands still until he makes it.
  #
  # Either way nothing here finishes the work. Only an answer naming this request does that.
  _fb="$(codex_fallback_choice "${IDIR_SCOPE:-}" 2>/dev/null || true)"
  if [ "$_fb" = claude ]; then
    REVIEWER=claude
    log "codex out (${codex_used}%) — the director chose Claude in its place"
  else
    resume_at="$(sane_resume_at "${codex_resets:-0}")"
    if [ -n "${IDIR_SCOPE:-}" ]; then
      # A CODEX pause, recorded as one: it stops the REVIEW, and must never read as "the worker is
      # busy" — that misreading once cost an hour of Claude's time to a limit that was not his.
      # The review then becomes OWED, and that has to outlive the pause; without `review-pending`,
      # a run whose Codex came back an hour later with no further messages would simply never be
      # reviewed, and would look for all the world as if it had.
      pause_record "$IDIR_SCOPE" codex "$resume_at" "codex usage guard" "$session_id"
      jq -n --arg sid "$session_id" --argjson at "$(date +%s)" \
         '{reason:"codex window ran out before the review", session_id:$sid, at:$at}' \
         > "$IDIR_SCOPE/review-pending.tmp" 2>/dev/null \
        && mv -f "$IDIR_SCOPE/review-pending.tmp" "$IDIR_SCOPE/review-pending" 2>/dev/null
      codex_owe "$IDIR_SCOPE" review "$(provider_unavailable_note codex)"
      # Silence is right for a wait that ends by itself. A wait measured in days, or one with no
      # believable end at all, is a question — and a question that is never asked is how a run
      # stands still all night with nobody able to tell it to go on.
      #
      # And a "wait" he gave recently is an answer, not a gap. Asking the same question again at
      # the next stop would make his decision look ignored, so it stands for as long as a fresh
      # question would have waited before being raised at all.
      _said="$(jq -r 'select(.choice == "wait") | .granted_at // 0' \
                "$(codex_grant_file "$IDIR_SCOPE")" 2>/dev/null)"
      case "$_said" in ''|*[!0-9]*) _said=0 ;; esac
      _ask_after="${SUPERVISOR_CODEX_ASK_AFTER:-86400}"
      if codex_decision_pending "$IDIR_SCOPE"; then
        # A question already on his screen, and the engine has since learned something truer about
        # why. Seen for real: a call that died with exit 1 raised a card saying "Codex stopped with
        # an error" and no time at all, and four minutes later the meter came back with the actual
        # answer — a spent five-hour window, back at 01:09. Nothing rewrote the card, so what he
        # would have decided from was the first guess. Refreshing costs nothing and never mints a
        # new request: the id he is answering stays the same.
        codex_decision_ask "$IDIR_SCOPE" review exhausted "$codex_resets" \
          "$(provider_unavailable_note codex)"
      elif [ "$_said" -gt 0 ] && [ $(( $(date +%s) - _said )) -lt "$_ask_after" ]; then
        log "already told to wait $(( ($(date +%s) - _said) / 60 ))m ago — parked without asking again"
      elif [ "$codex_resets" -le 0 ] || [ "$_codex_wait" -ge "$_ask_after" ]; then
        codex_decision_ask "$IDIR_SCOPE" review exhausted "$codex_resets" \
          "$(provider_unavailable_note codex)"
      fi
    else
      jq -n --arg sid "$session_id" --argjson at "$resume_at" \
        '{provider:"codex", session_id:$sid, resume_after:$at, reason:"codex usage guard"}' \
        > "$PAUSED_FILE"
    fi
    log "Codex out (${codex_used}%) — parked, the review is owed, watchdog asks again at $(date -r "$resume_at" '+%F %H:%M' 2>/dev/null || echo "$resume_at")"
    exit 0
  fi
fi

# The director turned the review off himself. That is debt BY CHOICE, and the only kind of debt
# this gate still writes on its own: every other way of reaching the end without a reviewer now
# parks instead. The two must stay distinguishable, or "unreviewed because he said so" and
# "unreviewed because nobody noticed" end up looking the same in the report.
if [ -n "${IDIR_SCOPE:-}" ] && review_off_authorised "$IDIR_SCOPE" "${scope#instance:}"; then
  if mv "$IDIR_SCOPE/review-off" "$IDIR_SCOPE/review-off.consumed" 2>/dev/null; then
    rm -f "$IDIR_SCOPE/review-off.consumed" 2>/dev/null || true
    { echo ""; echo "## $(date '+%F %T') — session $session_id"; \
      echo "Перевірку вимкнено в налаштуваннях (режим «тільки Claude») — це твій власний вибір, а не збій."; \
      echo "Роботу не перевіряв ніхто; увімкни перевірку, якщо хочеш, щоб її дивився Codex."; } \
      | legacy_note "$DEBT_OUT" REVIEW-DEBT.md
    journal_event "$IDIR_SCOPE" review-off "перевірку вимкнено налаштуванням — завершено без неї" \
      '{"source":"director"}' 2>/dev/null || true
    log "review gate OFF for THIS stop (explicit operator setting, marker consumed) — finishing unreviewed (debt)"
    mark_done debt
    exit 0
  fi
  log "review-off present but another stop consumed it — reviewing normally"
fi
# An unsigned marker has already been deleted by `review_off_authorised`, and the run carries on to
# a real review. Saying it out loud costs nothing and is the only trace anybody would get.
[ -n "${IDIR_SCOPE:-}" ] && [ -e "$IDIR_SCOPE/review-off" ] \
  && log "a review-off marker of unknown origin was ignored — reviewing normally" || true

rounds_file="$STATE_DIR/rounds-$RUN_KEY"
rounds=$(cat "$rounds_file" 2>/dev/null || echo 0)

RS_MODE="$(runspec_mode "${IDIR_SCOPE:-}")"     # broad (default) | patch | remediation | audit
BOUNDED=0
if [ "${SUPERVISOR_BOUNDED_REVIEW:-1}" = 1 ]; then
  case "$RS_MODE" in patch|remediation|audit) BOUNDED=1;; esac
  runspec_task_bound "${IDIR_SCOPE:-}" && BOUNDED=1
fi
remed_file="$STATE_DIR/remediations-$RUN_KEY"
harness_file="$STATE_DIR/harness-$RUN_KEY"
remediations=$(cat "$remed_file" 2>/dev/null || echo 0)
if [ "${SUPERVISOR_MAX_RUN_SECONDS:-0}" -gt 0 ] && [ -f "$IDIR_SCOPE/started-at" ]; then
  _started=$(stat -f %m "$IDIR_SCOPE/started-at" 2>/dev/null || stat -c %Y "$IDIR_SCOPE/started-at" 2>/dev/null || echo 0)
  if [ "$_started" -gt 0 ]; then
    _age=$(( $(date +%s) - _started ))
    if [ "$_age" -ge "$SUPERVISOR_MAX_RUN_SECONDS" ]; then
      { echo ""; echo "## $(date '+%F %T') — session $session_id"; \
        echo "⏱ Прогін ходить на рев'ю вже $(( _age / 3600 )) год. Далі не ганяю — потрібне твоє рішення."; \
        echo "Зроблене нікуди не зникло: гілка, коміти й звіт на місці."; } \
        | legacy_note "$BLOCKED_OUT" BLOCKED.md
      emit_review_json COMPLETE FAIL needs-user "run exceeded ${SUPERVISOR_MAX_RUN_SECONDS}s of review rounds"
      log "run age ${_age}s >= ${SUPERVISOR_MAX_RUN_SECONDS}s — parking for the operator"
      mark_done needs-user
      exit 0
    fi
  fi
fi

if [ "$rounds" -ge "$SUPERVISOR_MAX_ROUNDS_HARD" ]; then
  log "hard round ceiling ($SUPERVISOR_MAX_ROUNDS_HARD) reached for $session_id — allowing stop"
  mark_done debt
  exit 0
fi

last_msg=""
recent_user_turns=""
if [ -f "$transcript" ]; then
  last_msg=$(tail -r "$transcript" 2>/dev/null | jq -r 'select(.message.role=="assistant")
    | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | head -c 4000)
  recent_user_turns=$(jq -r '
      select(.type=="user")
      | .message.content as $content
      | select(($content | type)=="string")
      | select(($content | startswith("Stop hook feedback:")) | not)
      | $content' "$transcript" 2>/dev/null | tail -n 6 | head -c 8000)
fi

# The run's work is not only what is in `cwd`.
#
# A product can be several repositories, and the worker is handed all of them. A night that did its
# work in a sibling repository used to read as "nothing changed" here, get parked as a run with no
# outcome, and have that work neither reviewed nor reported. `extra_repos_changed` asks the
# repositories this run was actually given, each against what it looked like when the run started.
EXTRA_CHANGED=""
if [ -n "${IDIR_SCOPE:-}" ]; then
  EXTRA_CHANGED="$(extra_repos_changed "$IDIR_SCOPE" 2>/dev/null || true)"
  [ -n "$EXTRA_CHANGED" ] && log "changes outside the primary folder: $(printf '%s' "$EXTRA_CHANGED" | tr '\n' ' ')"
fi

if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$BASE_SHA" ] && git -C "$cwd" cat-file -e "$BASE_SHA" 2>/dev/null; then
    changed="$(git -C "$cwd" diff "$BASE_SHA" --stat 2>/dev/null)$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null)$EXTRA_CHANGED"
    if [ -z "$changed" ]; then
      if runspec_present "${IDIR_SCOPE:-}" && [ "${RS_MODE:-broad}" = audit ]; then
        emit_review_json "" N/A needs-user ""
        mark_done needs-user
        log "audit mode, no repo changes — resolved as needs-user (findings surfaced)"
        exit 0
      elif [ "$BOUNDED" = 1 ]; then
        : # bounded patch/remediation: fall through to the scope-gate empty-diff guard
      else
        nudge_or_park_no_outcome
      fi
    fi
  elif [ -z "$(git -C "$cwd" status --porcelain 2>/dev/null)$EXTRA_CHANGED" ]; then
    if runspec_present "${IDIR_SCOPE:-}" && [ "${RS_MODE:-broad}" = audit ]; then
      emit_review_json "" N/A needs-user ""
      mark_done needs-user
      log "audit mode, no repo changes — resolved as needs-user (findings surfaced)"
      exit 0
    elif [ "$BOUNDED" = 1 ]; then
      : # bounded patch/remediation: fall through to the scope-gate empty-diff guard
    else
      nudge_or_park_no_outcome
    fi
  fi
fi

rm -f "$STATE_DIR/outcome-nudge-$RUN_KEY" 2>/dev/null || true

if [ -n "${IDIR_SCOPE:-}" ]; then
  "$BIN_DIR/scope-gate.sh" "$cwd" "$IDIR_SCOPE" "$BASE_SHA" >/dev/null 2>&1 || true

  if [ "$(runspec_mode "$IDIR_SCOPE")" != broad ]; then
    post="$(git -C "$cwd" diff "$BASE_SHA" --stat 2>/dev/null)$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null)"
    if [ -z "$post" ]; then
      log "no in-scope changes remain after scope-gate — returning to operator (scope_violation)"
      emit_review_json COMPLETE FAIL scope_violation "All worker changes were outside the RunSpec write_paths and were quarantined; nothing in scope was accomplished."
      mark_done needs-user
      exit 0
    fi
  fi
fi

if [ -n "$BASE_SHA" ] && git -C "$cwd" cat-file -e "$BASE_SHA" 2>/dev/null; then
  diff_summary=$(git -C "$cwd" diff "$BASE_SHA" --stat 2>/dev/null | tail -40)
else
  diff_summary=$(git -C "$cwd" diff HEAD --stat 2>/dev/null | tail -40)
fi
# Work done in the product's other repositories goes to the reviewer too, labelled as what it is.
# Without this the review is handed an empty diff and asked to judge a night that wrote code.
if [ -n "${IDIR_SCOPE:-}" ] && [ -n "$EXTRA_CHANGED" ]; then
  diff_summary="$diff_summary
$(extra_repos_diffstat "$IDIR_SCOPE" 2>/dev/null || true)"
fi

verify_json=""; verify_status="skipped"; verify_fail_logs=""
review_stage verifying
if [ "${SUPERVISOR_VERIFIER_ENABLED:-1}" = 1 ] && [ -x "$BIN_DIR/verify.sh" ] && [ "${used:-0}" -lt "${SUPERVISOR_VERIFY_GUARD:-100}" ]; then
  ev="$("$BIN_DIR/verify.sh" "$cwd" "$session_id" "${IDIR_SCOPE:-}" "$BASE_SHA" 2>>"$CODEX_LOG")"
  if [ -n "$ev" ] && [ -f "$ev" ]; then
    verify_json="$(cat "$ev")"
    verify_status="$(jq -r '.overall_status // "inconclusive"' "$ev" 2>/dev/null)"
    verify_fail_logs="$(jq -r '.criteria[]? | select(.status=="fail") | .artifact' "$ev" 2>/dev/null \
      | while read -r f; do [ -f "$f" ] && { echo "----- $f -----"; tail -n 40 "$f"; }; done)"
    log "verifier: $verify_status ($ev)"
  else
    verify_status="inconclusive"; log "verifier produced no evidence"
  fi
fi

finding_classes=""
if [ -n "${IDIR_SCOPE:-}" ] && runspec_present "$IDIR_SCOPE" && [ "${RS_MODE:-broad}" != broad ]; then
  finding_classes="FINDING CLASSES — tag EVERY numbered defect with exactly one:
 [acceptance_failure]   — a RunSpec acceptance criterion is not met. May reopen work.
 [regression_from_patch]— this change broke something that worked at base-sha. May reopen work.
 [scope_violation]      — a change OUTSIDE the RunSpec write_paths/objective. Do NOT ask the
                          worker to extend the change; this is quarantined by the harness.
 [related_improvement]  — a real but out-of-scope improvement. Goes to the backlog, NEVER reopens.
 [pre_existing]         — a defect that already existed at base-sha, untouched by this task. Note only.
 [harness_failure]      — the review tooling itself failed (verifier crashed, evidence unreadable).
Only [acceptance_failure] and [regression_from_patch] may cause VERDICT: FAIL. A change consisting
ONLY of [scope_violation] items is VERDICT: FAIL with disposition scope_violation (quarantine),
never a remediation request. related_improvement / pre_existing NEVER cause FAIL.

"
else
  finding_classes="FINDING CLASSES — tag EVERY numbered defect with exactly one:
 [acceptance_failure]   — the task this run was given is not fulfilled: the objective recorded for
                          it, or the current request in RECENT HUMAN TURNS. May reopen.
 [regression_from_patch]— work for that request broke behavior that worked before it. May reopen.
 [related_improvement]  — a real but unrequested improvement. Advisory only; NEVER reopens work.
 [pre_existing]         — a defect not introduced by the current request. Advisory only; NEVER reopens.
 [harness_failure]      — the review tooling itself failed (verifier crashed, evidence unreadable).
Only [acceptance_failure] and [regression_from_patch] may cause VERDICT: FAIL. The product's general
release readiness, old backlog and unrelated files are not acceptance criteria. If you notice them,
mention them only as related_improvement/pre_existing and return PASS when the requested work passes.

"
fi

persona="$(cat "$SUPERVISOR_DIR/SUPERVISOR.md" "$SUPERVISOR_DIR/STANDARDS.md" 2>/dev/null)"

prompt="$persona

---
You are reviewing what Claude Code just did in: $cwd. Round $((rounds + 1)) (the gate keeps iterating while the worker makes real progress, up to $SUPERVISOR_MAX_ROUNDS_HARD).

TASK AUTHORITY AND BOUNDARY:
If an acceptance contract is present below, it is authoritative. Otherwise the latest human turns
below define the current request. Resolve short replies such as yes/do it from those nearby turns.
Review ONLY whether that request was fulfilled and whether its implementation introduced a regression.
Do not turn a repository-wide concern, a pre-existing defect, or a feature the user did not request
into a failure. The whole product is in scope only when the human explicitly asked for a full product
audit in these turns.

RECENT HUMAN TURNS (newest request is last):
${recent_user_turns:-(not available; use the RunSpec and final report)}

STEP 0 — GOAL CHECK (Ф7): if Claude executed the LITERAL task in a way that harms its real
goal (mass-produced near-duplicate content, gold-plated far beyond the spec, or took a path
the spec/plan warned against) WITHOUT recording a \"## PROPOSED REDIRECTION\" in DECISIONS.md,
that is a FAIL — name the better path.

STEP 1 — CLASSIFY Claude's stop into a lifecycle STATE (read its final report below):
 • COMPLETE — Claude states an implementation task/feature is actually finished.
 • HANDOFF  — Claude paused / handed the turn back (a question it could resolve itself, a
   planning or validation checkpoint, «зробив 30%, може досить?»), but the work CAN proceed
   autonomously per the standard overnight rule. NOT a real blocker.
 • BLOCKED  — Claude genuinely cannot proceed without a human or external access: a login /
   credential, a decision only the owner can make, or a missing external resource.

STEP 2 — for COMPLETE only, AUDIT for a quality VERDICT (PASS/FAIL):
WHAT YOU JUDGE BY: the current request or contract, the repository's own instruction files
(CLAUDE.md, AGENTS.md, README, specs) and the operating standards above. Those instructions and
standards apply WITHIN the boundary of the current task — they are how this work is judged, never
a longer list of work it owed. Nothing else is an acceptance criterion. You are given no history
of what was decided on earlier nights, and you must not invent one: a preference you infer from
the codebase is [related_improvement] at most.
Enforce the QUALITY BAR: AI-looking design, un-humanized copy, skipped design
skills, placeholders or fakes are grounds for FAIL. Inspect the workspace yourself
(read-only): read SPEC.md / ROADMAP.md / requirements if present, read the changed files,
run read-only checks. Judge completeness vs the spec; claims must be verified, not trusted.
Never invent work the user deferred or did not ask for at this step.

\"It compiles\" is not the audit. Within the boundary of THIS task, go through each of these and
say nothing about the ones that do not apply to it:
 • COMPLETENESS — every part of what was asked, not the easy parts. Work quietly narrowed to fit
   is a defect even when what shipped is correct.
 • REGRESSION — behaviour that worked at the base commit and does not now.
 • EDGE CASES — empty, first run, concurrent, cancelled, restarted, offline, out of quota; the
   states in which a feature looks finished and is broken.
 • INTERFACE BEHAVIOUR — what a person actually sees and can reach: states, error and empty
   cases, whether the screen tells the truth about what the system is doing.
 • PLATFORMS — the ones this change genuinely touches, and only those.
 • SECURITY — untrusted input, secrets, permissions, anything that leaves the machine.
 • DOES IT ACTUALLY WORK — end to end, on the real path a user takes, not only in a unit test.

CLAUDE'S FINAL REPORT:
${last_msg:-（no final message captured)}

CHANGED FILES (git stat since the run's base, if any):
${diff_summary:-(not a git repo or no changes)}

${CONTRACT_TEXT:-(no acceptance contract recorded for this run)}

AGREED PLAN (pre-flight notes, if any — context, not the contract):
${PLAN_TEXT:-(no plan)}
${OWED_BLOCK}${CHALLENGE_BLOCK}

VERIFIER EVIDENCE (machine-collected by running real build/test/lint — this OUTRANKS any
claim in the report; opinion is not evidence):
${verify_json:-(verifier did not run)}

Truncated logs for FAILING criteria:
${verify_fail_logs:-(none)}

STEP 3 — EVIDENCE GATE (applies when STATE: COMPLETE): a criterion counts as MET only if
the evidence has an entry with \"status\":\"pass\" and \"exit_code\":0. If Claude's report
claims something builds / passes tests / lints clean and there is NO matching \"status\":\"pass\"
entry (or the entry is \"fail\"/\"inconclusive\"), you MUST return VERDICT: FAIL and list that
criterion as UNPROVEN — judge by the evidence, not Claude's word. If the evidence is empty
because nothing buildable changed (\"skipped\"), judge the change normally.

If the REVIEW TOOLING itself failed — the verifier could not run the project's real build/test
(wrong package manager, missing toolchain), or a package broken at base-sha UNRELATED to this
change fails the build — tag that defect [harness_failure]. It is NOT the worker's fault and must
not loop the worker; the harness parks it for the operator.

${finding_classes}OUTPUT FORMAT — STRICT (header lines, in this order):
STATE: COMPLETE | HANDOFF | BLOCKED
VERDICT: PASS | FAIL | N/A
${CRITERIA_LINE_SPEC}
Rules: give VERDICT: PASS or FAIL only when STATE: COMPLETE; use VERDICT: N/A for HANDOFF
and BLOCKED. If VERDICT: FAIL — a numbered list of concrete defects (file, what's missing,
what 'done' looks like), most important first, max 10, which Claude will fix verbatim.
If STATE: BLOCKED — one line stating exactly what human action / access is required."

review_stage reviewing
# Past every guard: the review is happening, so it is no longer owed — and neither is the question
# that was asked because it could not happen. A card still asking whether to wait for Codex, while
# Codex is reading the diff, is a decision about nothing.
[ -n "${IDIR_SCOPE:-}" ] && rm -f "$IDIR_SCOPE/review-pending" 2>/dev/null || true
[ -n "${IDIR_SCOPE:-}" ] && rm -f "$(codex_decision_file "$IDIR_SCOPE")" 2>/dev/null || true

# WHO is reading it, and whether the reading changed anything.
#
# The exit code used to be thrown away entirely. A 480-second timeout, a login that had expired and
# a window that ran out mid-call all arrived below as the same empty string, three of them in a row
# finished the run as debt, and the reason was never written down anywhere. It is captured here and
# classified below, because "the reviewer failed" and "the work failed review" are not the same
# event and only one of them is the worker's business.
#
# The stand-in is held to read-only by what it is given — no Bash, no Edit, no MCP — and then
# checked against the tree rather than believed. A reviewer that wrote a byte has stopped being a
# reviewer, and its verdict is thrown away rather than argued with.
#
# The decision outlives the reading that prompted it. A window that runs out INSIDE a call leaves
# the meter reading `unknown`, not `exhausted`, so a grant checked only in the quota branch above
# would be invisible on exactly the path where it is needed most: the director would choose Claude
# and then watch every round go back to a Codex that cannot answer.
if [ "${REVIEWER:-codex}" != claude ] \
   && [ "$(codex_fallback_choice "${IDIR_SCOPE:-}" 2>/dev/null || true)" = claude ]; then
  REVIEWER=claude
fi
review_rc=0
_tree_token="$(tree_guard_begin "$cwd")"
if [ "${REVIEWER:-codex}" = claude ]; then
  log "reviewing with Claude in Codex's place (director's decision)"
  review="$(claude_peer_readonly 480 "$cwd" "$prompt" 2>>"$CODEX_LOG")"; review_rc=$?
  if tree_guard_touched "$cwd" "$_tree_token"; then
    log "the Claude stand-in TOUCHED the working tree — its review is void"
    review=""; review_rc=99
  fi
else
  review=$(cd "$cwd" 2>/dev/null && perl -e 'alarm shift; exec @ARGV' 480 \
    codex exec $(codex_effort_flags) --sandbox read-only --skip-git-repo-check \
    "$prompt" </dev/null 2>>"$CODEX_LOG"); review_rc=$?
fi

# A call that failed has no verdict, whatever it managed to print on the way down.
#
# The exit code was only consulted when the output was empty or unreadable, so a reviewer that
# printed STATE: COMPLETE / VERDICT: PASS and then died — killed at the 480-second alarm, refused
# mid-stream for want of quota, or cut off by an expired login — was accepted as a clean pass. A
# partial answer is the most dangerous shape this failure takes, because it is the one that looks
# like success. So the output is discarded here rather than parsed, and the run takes the
# unreachable path below exactly as it would for a call that said nothing at all.
if [ "$review_rc" != 0 ] && [ -n "$review" ]; then
  log "reviewer exited $review_rc after printing $(printf '%s' "$review" | wc -c | tr -d ' ') bytes — the verdict is void"
  review=""
fi

review_head="$(printf '%s\n' "$review" | head -8)"
state=$(printf '%s\n' "$review_head" | grep -m1 -oE 'STATE: *(COMPLETE|HANDOFF|BLOCKED)' | grep -oE 'COMPLETE|HANDOFF|BLOCKED' || echo "")
verdict=$(printf '%s\n' "$review_head" | grep -m1 -oE 'VERDICT: *(PASS|FAIL)' | grep -oE 'PASS|FAIL' || echo "")
# A reviewer that answered is a reviewer that was reachable, whatever it then said about the work.
[ -n "$state" ] && rm -f "$STATE_DIR/unreachable-$RUN_KEY" 2>/dev/null || true
# Who actually read it. A substitution nobody was told about is worse than the wall it went round,
# and this line is what the worker, the report and the receipt all end up quoting.
if [ "${REVIEWER:-codex}" = claude ] && [ -n "$review" ]; then
  review="🌙 Перевіряв Claude замість Codex — ти сам це дозволив, бо в Codex не було вікна.

$review"
fi

if [ -n "$CHALLENGES_TEXT" ] && [ -n "${IDIR_SCOPE:-}" ]; then
  _crid="$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)"
  _rundir="$(run_dir "${_crid:-unknown}")"; mkdir -p "$_rundir" 2>/dev/null || true
  _line="$(printf '%s\n' "$review_head" | grep -m1 -oE 'CRITERIA:.*' || echo "")"
  _accepted=0
  : > "$_rundir/criteria-decisions.jsonl.tmp" 2>/dev/null || true
  for _pair in $(printf '%s' "${_line#CRITERIA:}"); do
    case "$_pair" in
      AC-[0-9][0-9][0-9]=superseded)
        if [ "$_accepted" -lt "${CRIT_CAP:-1}" ]; then
          _accepted=$((_accepted + 1)); _dec=superseded
        else
          _dec=stands_over_cap
        fi ;;
      AC-[0-9][0-9][0-9]=stands) _dec=stands ;;
      *) continue ;;
    esac
    jq -nc --arg id "${_pair%%=*}" --arg d "$_dec" --arg rid "$_crid" --arg ts "$(date '+%F %T')" \
       --arg round "$((rounds + 1))" \
       '{ts:$ts, run_id:$rid, criterion:$id, decision:$d, adjudicator:"review-gate", round:($round|tonumber)}' \
       >> "$_rundir/criteria-decisions.jsonl.tmp" 2>/dev/null || true
  done
  mv -f "$_rundir/criteria-decisions.jsonl.tmp" "$_rundir/criteria-decisions.jsonl" 2>/dev/null || true
  log "criteria: $(grep -c . "$_rundir/criteria-decisions.jsonl" 2>/dev/null || echo 0) decided, $_accepted superseded (cap ${CRIT_CAP:-1})"
fi
log "round $((rounds + 1)) state=${state:-?} verdict=${verdict:-?} verify=${verify_status}"

if [ -n "${IDIR_SCOPE:-}" ] && runspec_present "$IDIR_SCOPE" && [ "${RS_MODE:-broad}" != broad ]; then
  printf '%s\n' "$review" | grep -oE '\[(related_improvement|pre_existing)\].*' 2>/dev/null \
    | while IFS= read -r fl; do jq -nc --arg t "$fl" --arg ts "$(date '+%F %T')" \
        --arg rid "$(cat "$IDIR_SCOPE/run-id" 2>/dev/null || true)" \
        '{ts:$ts, class:"reviewer", text:$t, run_id:$rid}' >> "$IDIR_SCOPE/findings.jsonl" 2>/dev/null; done
fi

if [ "$verify_status" = "fail" ] && [ "$state" = "COMPLETE" ] && [ "$verdict" = "PASS" ]; then
  log "VERIFIER OVERRIDE: evidence=fail but Codex said COMPLETE/PASS → forcing FAIL"
  verdict="FAIL"
  review="$review

[VERIFIER OVERRIDE] Обʼєктивна перевірка ПРОВАЛИЛАСЬ — заявлений критерій не збирається / не проходить тести. Це машинне свідчення, не думка. Логи збоїв:
${verify_fail_logs:-(див. evidence.json)}"
fi

if [ -z "$review" ] || [ -z "$state" ]; then
  # Two very different failures used to be one.
  #
  # "The reviewer never answered" is not "the work is bad", and counting it as a review round was
  # how three unanswered calls added up to REVIEW-DEBT.md and a finished run. Worse, the commonest
  # cause — a window that ran out inside the call — never reached the quota branch above at all,
  # because the meter had gone `unknown` by then and `unknown` is deliberately not `exhausted`.
  #
  # So the exit code decides. A reviewer that could not be reached parks the run and asks; only a
  # reviewer that actually replied with something unreadable counts as a round against the work.
  _who_reviewed="${REVIEWER:-codex}"
  unreachable=0
  case "$review_rc" in
    # A clean exit means the call itself worked. Saying nothing through it is a poor answer, not a
    # missing reviewer, and treating the two the same would park a run over a blank verdict.
    0)   if [ -z "$review" ]; then why="рецензент ($_who_reviewed) не сказав нічого"
         else why="відповідь є, але стан у ній нечитабельний"; fi ;;
    99)  unreachable=1; why="рецензент змінив робоче дерево — перевірку відкинуто як недійсну" ;;
    142) unreachable=1; why="рецензент ($_who_reviewed) не відповів за 480 с" ;;
    *)   unreachable=1; why="рецензент ($_who_reviewed) зупинився з кодом $review_rc" ;;
  esac

  if [ "$unreachable" = 0 ]; then
    echo $((rounds + 1)) > "$rounds_file"
    log "review inconclusive ($why), round $((rounds + 1))"
    if [ $((rounds + 1)) -lt "$MAX_ROUNDS" ]; then
      jq -n --arg reason "🌙 Супервізор НЕ зміг перевірити роботу ($why, спроба $((rounds + 1))/$MAX_ROUNDS). Роботу НЕ прийнято. Переконайся, що все зроблено за специфікацією без заглушок, і спробуй завершити знову." \
        '{decision: "block", reason: $reason}'
      exit 0
    fi
    # Three answers and not one of them a verdict. Whatever is wrong is not the work — asking the
    # worker a fourth time only spends another turn on it — so this joins the path below rather
    # than being written off as debt, which is what it used to become.
    unreachable=1
    why="$why (${MAX_ROUNDS} спроби поспіль)"
  fi

  if [ -n "${IDIR_SCOPE:-}" ]; then
    # WHICH kind of unavailable, because the card says it out loud and a wrong word there sends the
    # reader to wait out a window that is not the problem. `exhausted` used to be the default for
    # every failure, so a timeout and a dead login both came up as "Codex has no window left".
    case "$review_rc" in
      142) _state=timeout ;;
      0)   _state=silent ;;
      99)  _state=tampered ;;
      *)   _state=failed ;;
    esac
    if [ "$_who_reviewed" = codex ] && codex_signed_out "${SUPERVISOR_CODEX_BIN:-codex}"; then
      _state=signed_out
      why="$why — codex login status каже «Not logged in»"
    elif [ "$_who_reviewed" = codex ] && provider_exhausted codex; then
      _state=exhausted
    fi
    _uf="$STATE_DIR/unreachable-$RUN_KEY"
    _un=$(cat "$_uf" 2>/dev/null || echo 0); case "$_un" in ''|*[!0-9]*) _un=0 ;; esac
    _un=$((_un + 1)); echo "$_un" > "$_uf"
    # Parking is the right answer to a reviewer that is merely out; it is the wrong answer for
    # ever. After enough attempts that each ran straight back into the same wall, this stops being
    # something waiting can fix and becomes something a person has to look at — and it is parked
    # as NEEDS-USER, never as debt, because nobody chose to ship this unreviewed.
    if [ "$_un" -ge "${SUPERVISOR_MAX_UNREACHABLE:-5}" ]; then
      { echo ""; echo "## $(date '+%F %T') — session $session_id"; \
        echo "Рецензента не вдалося дістати $_un разів поспіль ($why)."; \
        echo "Роботу НЕ перевірено. Гілка, коміти і звіт на місці — потрібне твоє рішення."; } \
        | legacy_note "$BLOCKED_OUT" BLOCKED.md
      emit_review_json COMPLETE FAIL needs-user "reviewer unreachable ${_un}x: $why"
      log "reviewer unreachable ${_un}x — parking for the operator (needs-user), NOT debt"
      mark_done needs-user
      exit 0
    fi
    pause_record "$IDIR_SCOPE" codex "$(sane_resume_at 0)" "reviewer unreachable" "$session_id"
    jq -n --arg sid "$session_id" --argjson at "$(date +%s)" \
       '{reason:"the reviewer could not be reached", session_id:$sid, at:$at}' \
       > "$IDIR_SCOPE/review-pending.tmp" 2>/dev/null \
      && mv -f "$IDIR_SCOPE/review-pending.tmp" "$IDIR_SCOPE/review-pending" 2>/dev/null
    codex_owe "$IDIR_SCOPE" review "$why"
    codex_decision_ask "$IDIR_SCOPE" review "$_state" 0 "$why"
    log "review not reached (attempt $_un, $why) — parked and asked the director, no round counted"
    exit 0
  fi

  # No instance directory, so there is nowhere to record a pause and nobody to ask: this is a
  # session outside a supervised run. It still must not end as debt — an unreviewed piece of work
  # is a thing for a person to look at, not a thing to write off.
  { echo ""; echo "## $(date '+%F %T') — session $session_id"; \
    echo "Рецензента не вдалося дістати ($why), і цей сеанс не належить жодному прогону."; \
    echo "Роботу НЕ перевірено — потрібне твоє рішення."; } \
    | legacy_note "$BLOCKED_OUT" BLOCKED.md
  emit_review_json COMPLETE FAIL needs-user "reviewer unreachable outside a run: $why"
  log "reviewer unreachable and no instance to park in — needs-user"
  mark_done needs-user
  exit 0
fi

if [ "$BOUNDED" = 1 ] && [ "$RS_MODE" = audit ]; then
  emit_review_json "$state" "${verdict:-N/A}" "needs-user" "$review"
  log "audit mode — findings recorded, no code reopen"
  mark_done needs-user   # operator reviews findings; audit never auto-merges
  exit 0
fi

if [ "$state" = "BLOCKED" ]; then
  { echo ""; echo "## $(date '+%F %T') — session $session_id — BLOCKED"; echo "$review"; } | legacy_note "$BLOCKED_OUT" BLOCKED.md
  log "BLOCKED — needs user/access; parked as needs-user"
  mark_done needs-user
  exit 0
fi

if [ "$state" = "HANDOFF" ]; then
  echo $((rounds + 1)) > "$rounds_file"
  if [ $((rounds + 1)) -ge "$MAX_ROUNDS" ]; then
    { echo ""; echo "## $(date '+%F %T') — session $session_id — repeated handoff"; \
      echo "Claude неодноразово передавав хід користувачу вночі — припиняю підштовхувати, потрібна людина."; \
      echo "$review"; } | legacy_note "$BLOCKED_OUT" BLOCKED.md
    log "repeated HANDOFF at round cap — parked as needs-user"
    journal_event "${IDIR_SCOPE:--}" escalation "repeated handoff — needs the director" '{"source":"gate"}'
    mark_done needs-user
    exit 0
  fi
  journal_event "${IDIR_SCOPE:--}" nudge "handoff → keep working (round $((rounds + 1))/$MAX_ROUNDS)" '{"source":"gate"}'
  note_progress nudge "$((rounds + 1))" "$MAX_ROUNDS"
  jq -n --arg reason "🌙 Вночі користувача нема — не передавай хід. Працюй автономно за стандартним правилом: обери найповніший шлях до завершеного результату без заглушок; якщо потрібне рішення — прийми розумне й занотуй у $IDIR/decisions.md; продовжуй, поки задача реально не готова (спроба $((rounds + 1))/$MAX_ROUNDS)." \
    '{decision: "block", reason: $reason}'
  exit 0
fi

if [ "$verdict" = "FAIL" ]; then
  acc=$(printf '%s\n' "$review" | grep -cE '\[acceptance_failure\]|\[regression_from_patch\]')
  scope=$(printf '%s\n' "$review" | grep -cE '\[scope_violation\]')
  harness=$(printf '%s\n' "$review" | grep -cE '\[harness_failure\]')

  nonharness=$(printf '%s\n' "$review" | grep -E '^[[:space:]]*[0-9]+[.)]' | grep -vcE '\[harness_failure\]')
  if [ "$harness" -gt 0 ] && [ "${nonharness:-0}" -eq 0 ] && [ "$BOUNDED" != 1 ]; then
    emit_review_json COMPLETE FAIL debt "$review"
    log "harness_failure is the sole finding (broad) — banking debt, not looping (not a worker defect)"
    mark_done debt; exit 0
  fi

  if [ "$harness" -gt 0 ] && [ "$BOUNDED" != 1 ]; then
    harness_rounds=$(( $(cat "$harness_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$harness_rounds" > "$harness_file"
    if [ "$harness_rounds" -ge "${SUPERVISOR_HARNESS_LIMIT:-2}" ]; then
      { echo ""; echo "## $(date '+%F %T') — session $session_id"; \
        echo "🔧 Рев'ю $harness_rounds раунди поспіль уперлось у САМ ІНСТРУМЕНТ перевірки, а не в роботу."; \
        echo "Воркер це виправити не може. Далі не ганяю — потрібне рішення людини."; \
        echo ""; echo "$review"; } | legacy_note "$BLOCKED_OUT" BLOCKED.md
      emit_review_json COMPLETE FAIL needs-user "$review"
      log "harness_failure persisted $harness_rounds rounds — parking for the operator, not looping"
      mark_done needs-user; exit 0
    fi
    log "harness_failure round $harness_rounds/${SUPERVISOR_HARNESS_LIMIT:-2} — one more chance to produce evidence"
  else
    rm -f "$harness_file" 2>/dev/null || true
  fi

  tagged=$(printf '%s\n' "$review" | grep -E '^[[:space:]]*[0-9]+[.)]' \
    | grep -cE '\[(acceptance_failure|regression_from_patch|scope_violation|related_improvement|pre_existing)\]')
  if [ "${tagged:-0}" -gt 0 ] && [ "${harness:-0}" -eq 0 ]; then
    if [ "$scope" -gt 0 ] && [ "$acc" -eq 0 ]; then
      emit_review_json COMPLETE FAIL scope_violation "$review"
      log "scope_violation only — quarantined, not reopening"
      mark_done needs-user; exit 0
    fi
    _numbered=$(printf '%s\n' "$review" | grep -cE '^[[:space:]]*[0-9]+[.)]' 2>/dev/null || true)
    _advisory=$(printf '%s\n' "$review" | grep -E '^[[:space:]]*[0-9]+[.)]' 2>/dev/null \
      | grep -cE '\[(related_improvement|pre_existing)\]' || true)
    if [ "$acc" -eq 0 ] && [ "${verify_status:-}" != fail ] \
       && [ "${_numbered:-0}" -gt 0 ] && [ "${_numbered:-0}" -eq "${_advisory:-0}" ]; then
      review="$review

[GATE OVERRIDE] Усі зауваження поза межами поточного запиту й не блокують його приймання."
      emit_review_json COMPLETE PASS passed "$review"
      log "advisory-only FAIL overridden to task PASS"
      mark_done passed; exit 0
    fi
  fi

  if [ "$BOUNDED" = 1 ]; then
    if [ "$harness" -gt 0 ] && [ "$acc" -eq 0 ]; then
      emit_review_json COMPLETE FAIL debt "$review"
      log "harness_failure in bounded review — stopping gate (not a worker defect)"
      mark_done debt; exit 0
    fi
    if [ "${acc:-0}" -eq 0 ]; then
      emit_review_json COMPLETE FAIL needs-user "$review"
      log "bounded FAIL, no reopenable class — parking as needs-user"
      mark_done needs-user
      exit 0
    fi
    if [ "$remediations" -lt "${SUPERVISOR_MAX_REMEDIATIONS:-1}" ]; then
      echo $((remediations + 1)) > "$remed_file"
      note_progress remediation "$((remediations + 1))" "${SUPERVISOR_MAX_REMEDIATIONS:-1}"
      emit_review_json COMPLETE FAIL "remediation" "$review"
      jq -n --arg reason "🌙 Рев'ю не прийняло (єдина ітерація виправлень). Виправ САМЕ ці пункти в межах RunSpec (не розширюй обсяг):

$review

Після виправлення заверши знову — це остання ітерація." \
        '{decision: "block", reason: $reason}'
      exit 0
    fi
    emit_review_json COMPLETE FAIL needs-user "$review"
    log "bounded: remediation spent, returning to operator"
    mark_done needs-user; exit 0
  fi

  next=$((rounds + 1)); echo "$next" > "$rounds_file"

  findings=$(printf '%s\n' "$review" | grep -cE '^[[:space:]]*[0-9]+[.)]' 2>/dev/null || echo 1)
  [ "${findings:-0}" -lt 1 ] && findings=1
  meta_file="$STATE_DIR/rounds-meta-$RUN_KEY"
  prev_findings=$(cut -d' ' -f1 "$meta_file" 2>/dev/null); [ -n "$prev_findings" ] || prev_findings=999999
  stall=$(cut -d' ' -f2 "$meta_file" 2>/dev/null); [ -n "$stall" ] || stall=0
  if [ "$findings" -lt "$prev_findings" ]; then stall=0; else stall=$((stall + 1)); fi
  printf '%s %s\n' "$findings" "$stall" > "$meta_file"
  _prev="$prev_findings"; [ "$_prev" -ge 999999 ] 2>/dev/null && _prev=""
  note_progress review "$next" "$MAX_ROUNDS" "$findings" "$_prev" "$stall" "$SUPERVISOR_STALL_LIMIT"
  log "round $next FAIL: findings=$findings prev=$prev_findings stall=$stall/$SUPERVISOR_STALL_LIMIT"

  stalled=0
  [ "$stall" -ge "$SUPERVISOR_STALL_LIMIT" ] && [ "$next" -ge "$SUPERVISOR_MAX_ROUNDS" ] && stalled=1

  if [ "$stalled" = 1 ]; then
    { echo ""; echo "## $(date '+%F %T') — session $session_id (stalled: $findings findings, no progress for $stall rounds)"; \
      echo "$review"; } | legacy_note "$BLOCKED_OUT" BLOCKED.md
    log "FAIL stalled at round $next ($stall no-progress rounds) — parking as needs-user"
    mark_done needs-user
    exit 0
  fi
  if [ "$next" -ge "$SUPERVISOR_MAX_ROUNDS_HARD" ]; then
    { echo ""; echo "## $(date '+%F %T') — session $session_id (hard ceiling $SUPERVISOR_MAX_ROUNDS_HARD, still progressing)"; \
      echo "$review"; } | legacy_note "$DEBT_OUT" REVIEW-DEBT.md
    log "FAIL at hard ceiling ($next) while progressing — banking debt"
    mark_done debt
    exit 0
  fi
  jq -n --arg reason "🌙 Codex-супервізор НЕ приймає роботу (раунд $next, ще $((SUPERVISOR_MAX_ROUNDS_HARD - next)) можливих):

$review

Виправ усі пункти повністю — без заглушок і 'на потім'. Роби відчутний прогрес щораунду (менше зауважень), інакше зупинюсь і покличу людину. Потім завершуй знову." \
    '{decision: "block", reason: $reason}'
  exit 0
fi

if [ "$verdict" != "PASS" ]; then
  echo $((rounds + 1)) > "$rounds_file"
  log "COMPLETE but verdict unreadable — inconclusive, round $((rounds + 1))"
  if [ $((rounds + 1)) -ge "$MAX_ROUNDS" ]; then
    { echo ""; echo "## $(date '+%F %T') — session $session_id"; \
      echo "⚠️ COMPLETE, але вердикт нечитабельний після $MAX_ROUNDS спроб — переглянь вручну."; } \
      | legacy_note "$DEBT_OUT" REVIEW-DEBT.md
    mark_done debt
    exit 0
  fi
  jq -n --arg reason "🌙 Вердикт супервізора нечитабельний (спроба $((rounds + 1))/$MAX_ROUNDS). Роботу НЕ прийнято — заверши знову." \
    '{decision: "block", reason: $reason}'
  exit 0
fi

if [ "$BOUNDED" = 1 ]; then
  if [ "${verify_status:-}" = inconclusive ]; then
    emit_review_json COMPLETE FAIL debt "$review"
    log "bounded PASS but verifier inconclusive — banking debt, not a clean pass"
    mark_done debt
    exit 0
  fi
  emit_review_json COMPLETE PASS passed "$review"
  rm -f "$rounds_file" "$remed_file" "$harness_file" 2>/dev/null || true
  log "bounded PASS — task accepted"
  mark_done passed
  exit 0
fi

rm -f "$rounds_file" "$STATE_DIR/rounds-meta-$RUN_KEY" "$remed_file" "$harness_file"
log "targeted review PASS (state=COMPLETE); verify=$verify_status"
if [ "${verify_status:-}" = inconclusive ]; then
  emit_review_json COMPLETE FAIL debt "$review"
  log "targeted PASS but verifier inconclusive — banking review debt"
  mark_done debt
  exit 0
fi

emit_review_json COMPLETE PASS passed "$review"
log "work accepted by task-scoped review"
mark_done passed
exit 0
