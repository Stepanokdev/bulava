#!/bin/bash
# The final code review by a team of reviewers, each with a focus of its own, instead of one.
#
# Measured on a bench of planted defects (artifacts/2026-11-08-review-bench, Nov 8–9, 23 snapshots of
# the factory's own MRs, 17 known defects): one ordinary review found 61.8% of them on Astra medium,
# three ordinary reviews 64.7%, three specialists 72.5% — the same count of calls, the focus the only
# difference; on Sol high 67.1 / 69.7 / 72.4%. The specialists' instructions below are the ones that
# were measured, word for word. Their findings are joined, not voted on and not passed through a
# model that summarises: one reviewer that saw a defect is enough to send the work back.
#
#   SUPERVISOR_REVIEW_TEAM="contract security state"   the measured team; on by default only under
#                                                      SUPERVISOR_PROFILE=server, off on the Mac and in
#                                                      a terminal unless set. Empty, "off" or one
#                                                      member: the single reviewer, as before.
#
# Members (any order, unknown names ignored):
#   contract  requirements and business logic               — measured
#   security  security and data integrity                   — measured
#   state     state transitions and integrations            — measured
#   general   an ordinary reviewer, no focus                — measured as the baseline; on the bench it
#                                                              found three defects no specialist did
#   negative  business rules and negative paths             — proposed after the bench, not measured
#   legacy    old records, missing and invalid data         — proposed after the bench, not measured
#   outcome   what the person actually gets on screen       — proposed after the bench, not measured
#
# Each member is a full review of the same change with the same prompt and the same evidence; the
# calls run side by side, so a team takes the time of its slowest member, and costs one call each.
# Sourced by supervisor-lib.sh.

REVIEW_TEAM_ROLES="contract security state general negative legacy outcome"

review_team_title() {   # $1=role
  case "$1" in
    contract) printf 'Contract and business logic' ;;
    security) printf 'Security and data integrity' ;;
    state)    printf 'State transitions and integrations' ;;
    general)  printf 'General review' ;;
    negative) printf 'Business rules and negative paths' ;;
    legacy)   printf 'Old records and invalid data' ;;
    outcome)  printf 'What the person gets' ;;
  esac
}

review_team_focus() {   # $1=role → the instruction added to the shared prompt
  case "$1" in
    contract) printf 'Prioritize requirements and business correctness: derive expected behavior from the task, trace the implementation, and examine unmet acceptance criteria, boundary conditions and incorrect test assertions.' ;;
    security) printf 'Prioritize security and data integrity: trace trust boundaries, authorization, identity handling, untrusted input/output, persistence and consistency across related records.' ;;
    state)    printf 'Prioritize state transitions and integration behavior: trace lifecycle changes, retries and failures, repeated operations, cache invalidation, ordering and cross-component contracts.' ;;
    negative) printf 'Prioritize business rules and negative scenarios: inactive or expired entities, partially completed actions, exceptions to a rule, rejected and repeated requests — what the system must refuse or treat differently.' ;;
    legacy)   printf 'Prioritize compatibility with data that already exists: old records, missing or renamed fields, ids that no longer exist, empty and malformed values — what the change does with data it did not create.' ;;
    outcome)  printf 'Prioritize what the person actually gets: the language and content of what they receive, whether the element they need is there and reachable, and whether the layout holds — judged from the code and the evidence as the user would meet it.' ;;
    *)        printf '' ;;
  esac
}

# The team as configured: known members, each once, in the order given. Nothing when the team is
# off or has fewer than two members — one reviewer is the single review.
review_team_members() {
  local raw="${SUPERVISOR_REVIEW_TEAM:-}" m out="" seen=" "
  case "$raw" in ''|off|0|none) return 0 ;; esac
  for m in $raw; do
    case " $REVIEW_TEAM_ROLES " in *" $m "*) ;; *) continue ;; esac
    case "$seen" in *" $m "*) continue ;; esac
    seen="$seen$m "; out="$out $m"
  done
  set -- $out
  [ "$#" -ge 2 ] || return 0
  printf '%s\n' "$@"
}

# The prompt one member reads: the shared one, then its focus.
review_team_prompt() {   # $1=role $2=shared prompt $3=team size
  local focus; focus="$(review_team_focus "$1")"
  printf '%s\n\nREVIEW TEAM — you are one of %s independent reviewers of this same change; the others read it too, and every defect any of you reports goes back to the worker (no vote).\n' "$2" "$3"
  if [ -n "$focus" ]; then
    printf 'YOUR FOCUS: %s Report any other real defect you find as well; the focus sets your priority, not your limits.\n' "$focus"
  else
    printf 'You have no particular focus: review the change as a whole.\n'
  fi
  printf 'Answer in the OUTPUT FORMAT above, exactly as a single reviewer would.\n'
}
