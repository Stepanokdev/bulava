#!/bin/bash

# The product this engine belongs to. Its own name is expected all over its own source, so the
# publication audit must not read it as a client's name — and that answer cannot come from the
# parent directory, which is whatever folder the engine was exported into.
: "${SUPERVISOR_PRODUCT_NAME:=Night Shift}"

: "${SUPERVISOR_MAX_ROUNDS:=3}"          # base patience: always allow at least this many FAIL rounds
: "${SUPERVISOR_MAX_ROUNDS_HARD:=12}"    # absolute ceiling per session (runaway protection)
: "${SUPERVISOR_STALL_LIMIT:=2}"         # consecutive no-progress FAIL rounds → park as genuinely stuck
: "${SUPERVISOR_MAX_RUN_SECONDS:=28800}" # 8h of review rounds → park for a person (0 disables)
# Quota is bought to be used, and these two numbers are how much of it the engine used to refuse to
# touch. A reserve sounds prudent and costs a whole capability: at 90 the last half hour of every
# five-hour window went unused, and the weekly guard cost days — Codex stood down at 91% with five
# days left to run. The director's instruction is to burn them to the end, so the only thing that
# stops the work now is the provider actually saying no, which the pane detector and the mid-turn
# refusal both already handle.
# How long a peer call may say NOTHING before it is treated as hung. Not a ceiling on thinking:
# both CLIs stream events while they work, so a model on max effort can take as long as the question
# needs, and only real silence ends the call. The old fixed 360s cut live work in half.
#
# Two numbers, because the two CLIs stream differently and it was measured rather than assumed.
# Claude, with --include-partial-messages, writes token deltas as they arrive — its gaps are
# seconds, so three minutes of nothing means it is hung. Codex emits four events for an entire turn
# (thread.started, turn.started, the answer, turn.completed) and nothing at all while it reasons,
# and its own rollout file grows at exactly the same moments — so for Codex this is NOT a liveness
# check. It is how long a silent reasoning phase may last before we give up on it, and it is the one
# place a clock still bounds live work. Fifteen minutes, and said out loud rather than dressed up.
: "${SUPERVISOR_PEER_IDLE_TIMEOUT:=180}"       # s of silence from Claude before it is stopped
: "${SUPERVISOR_PEER_IDLE_TIMEOUT_CODEX:=900}" # s of silence from Codex — see above, not liveness
: "${SUPERVISOR_PEER_POLL:=5}"           # how often that silence is measured

: "${SUPERVISOR_USAGE_GUARD:=100}"       # % of a 5h window after which we pause (Claude & Codex)
: "${SUPERVISOR_USAGE_WEEK_GUARD:=100}"  # % of the 7d window after which we pause

: "${SUPERVISOR_SCOPE_GATE:=1}"            # 1 = enforce RunSpec write_paths (write-gate + scope-gate); 0 = off (kill switch)
: "${SUPERVISOR_BLOCK_DECISIONS:=0}"       # 1 = also block worker writes to DECISIONS.md (enable once the findings channel replaces it)
: "${SUPERVISOR_BOUNDED_REVIEW:=1}"        # 1 = scoped runs (mode patch/remediation/audit) use the bounded 1-remediation machine; 0 = force legacy loop
: "${SUPERVISOR_MAX_REMEDIATIONS:=1}"      # scoped runs: max reopen cycles for acceptance/regression findings
: "${SUPERVISOR_LEGACY_REPO_NOTES:=0}"     # 1 = also dual-write blocked/debt into the repo during the §10.2 transition (#6)

: "${SUPERVISOR_OUTCOME_PROTOCOL:=1}"      # 1 = honor a worker-declared outcome + nudge/park a no-outcome stop; 0 = legacy silent-stop
: "${SUPERVISOR_OUTCOME_NUDGE_MAX:=2}"     # no-diff stops with no declared outcome: nudges to declare before parking as needs-user
: "${SUPERVISOR_STALL_PARK_SECS:=900}"     # watchdog: idle-at-prompt seconds with no outcome before parking (stalled.json); NOT a teardown

: "${SUPERVISOR_MAX_CODEX_WAIT:=19800}"  # max seconds to hold a question until Codex 5h reset (5.5h)

: "${SUPERVISOR_IDLE_KILL_HOURS:=4}"
: "${SUPERVISOR_STALE_DISABLE_HOURS:=10}"
if [ -n "${SUPERVISOR_STALE_HOURS:-}" ]; then
  SUPERVISOR_IDLE_KILL_HOURS="$SUPERVISOR_STALE_HOURS"
  SUPERVISOR_STALE_DISABLE_HOURS="$SUPERVISOR_STALE_HOURS"
fi
: "${SUPERVISOR_WATCHDOG_POLL:=45}"      # watchdog poll interval (s); tests set this small
: "${SUPERVISOR_IDLE_KILL_SECS:=}"       # optional EXACT idle-kill threshold (s); empty = hours*3600

: "${SUPERVISOR_QUEUE_POLL:=30}"
: "${SUPERVISOR_PROMPT_WAIT:=90}"
: "${SUPERVISOR_MAX_PROJECT_SECONDS:=28800}"   # 8h per-project safety cap
: "${SUPERVISOR_INJECT_CONFIRM_WAIT:=20}"      # s to confirm a task injection landed (fail-fast)

: "${SUPERVISOR_HANDSHAKE_WAIT:=5}"            # s the launcher waits for the SessionStart run-id handshake
: "${SUPERVISOR_REQUIRE_HANDSHAKE:=1}"         # 1 = abort/rollback the start when the hooks do not

: "${SUPERVISOR_VERIFIER_ENABLED:=1}"
: "${SUPERVISOR_VERIFY_STEP_TIMEOUT:=600}"     # per verification step (s)
: "${SUPERVISOR_VERIFY_TOTAL_TIMEOUT:=1500}"   # whole verifier wall-clock (s)
# Skipping the check that proves the work is the last thing to trade for quota: it turns a verified
# night into an unverified one to save something nobody asked to save.
: "${SUPERVISOR_VERIFY_GUARD:=100}"             # skip verify above this % window

: "${SUPERVISOR_PREFLIGHT_ENABLE:=1}"
: "${SUPERVISOR_COLLABORATION_MODE:=adaptive_peer}" # adaptive_peer | legacy
: "${SUPERVISOR_PLAN_MODE:=critique}"    # critique (default) | dual
: "${SUPERVISOR_PLAN_TIMEOUT:=360}"      # per planning/critique call (s)
: "${SUPERVISOR_RESEARCH_TIMEOUT:=720}"  # research call (s)
: "${SUPERVISOR_CONSULT_TIMEOUT:=900}"   # one precise peer consultation; number of calls is unlimited
: "${SUPERVISOR_PREFLIGHT_TOTAL_TIMEOUT:=2400}" # ceiling over the WHOLE preparation of one message
: "${SUPERVISOR_FOLLOWUP_TOTAL_TIMEOUT:=420}"   # …and over a follow-up to a task already open
: "${SUPERVISOR_TASK_IDLE_NEW_SECS:=21600}"     # silence after which an open task stops claiming the next message
: "${SUPERVISOR_CONSULT_WAIT_MAX:=180}"         # how long a consultation may STAND STILL for Codex's window
: "${SUPERVISOR_ASK_USER_WAIT_DEGRADED:=180}"   # …and how long a question NOBODY read waits for the director
: "${SUPERVISOR_USAGE_FRESH_SECS:=300}"         # a usage reading older than this is re-taken
: "${SUPERVISOR_USAGE_STALE_SECS:=1800}"        # …and older than this it cannot say "free"
: "${SUPERVISOR_PAUSE_RECHECK_SECS:=1800}"      # how far ahead to re-arm a pause with no believable reset
: "${SUPERVISOR_PAUSE_PROBE_BACKOFF:=600}"      # wait after a blind attempt runs back into the wall; doubles
: "${SUPERVISOR_PAUSE_PROBE_BACKOFF_MAX:=3600}"
: "${SUPERVISOR_REVIEW_ORPHAN_SECS:=5400}"      # a review marker whose owner is gone is stale after this
: "${SUPERVISOR_PREFLIGHT_LOCK_WAIT:=1800}"     # legacy name for the one below
: "${SUPERVISOR_PIPELINE_LOCK_WAIT:=3600}"      # how long a message waits for the run to be free (s)
: "${SUPERVISOR_PUMP_POLL:=5}"                  # message pump: how often it re-checks for an idle worker (s)
: "${SUPERVISOR_PUMP_IDLE_WAIT:=28800}"         # message pump: max wait for an idle worker (s)
: "${SUPERVISOR_KEEP_MESSAGE_ARTIFACTS:=12}"    # per-message artifact folders kept on an instance

: "${SUPERVISOR_SKILL_SCOPE:=project}"   # project (default) | user
: "${SUPERVISOR_SKILL_AUTONOMOUS:=1}"    # 1 = decide-and-act after audit; 0 = propose only
: "${SUPERVISOR_SKILL_AUDIT_TIMEOUT:=300}"
: "${SUPERVISOR_SKILL_INDEX_TTL:=86400}"   # how long a cached marketplace manifest stays fresh (s)
: "${SUPERVISOR_SKILL_INDEX_MAX:=2000000}" # a manifest larger than this is not a manifest (bytes)

: "${SUPERVISOR_BRANCH_MODE:=current}"
: "${SUPERVISOR_WORK_BRANCH:=}"          # "" = work in place; a name = use it, create if missing
: "${SUPERVISOR_PROTECTED_BRANCHES:=main master}"  # only consulted by mode=new / an explicit ask

: "${SUPERVISOR_PERMISSION_MODE:=auto}"  # auto | bypassPermissions | acceptEdits | plan | default

: "${SUPERVISOR_CLAUDE_EFFORT:=high}"     # Claude: low | medium | high | xhigh | max | ultracode
                                         # "none" = the model takes no depth, send no --effort at all.
                                         # An EMPTY value is not that: it becomes `high` on the line above.
: "${SUPERVISOR_CODEX_EFFORT:=high}"     # Codex:  low | medium | high | xhigh | max | ultra  (ultra: newest models only)

: "${SUPERVISOR_CLAUDE_MODEL:=}"         # "" = the CLI's own default
: "${SUPERVISOR_CODEX_MODEL:=}"          # "" = the CLI's own default

: "${SUPERVISOR_REPORT_LANGUAGE:=Ukrainian}"   # Ukrainian | Russian | English

: "${SUPERVISOR_RESUME_MAX_ATTEMPTS:=3}"
: "${SUPERVISOR_LIMIT_RECHECK_COOLDOWN:=600}"

export SUPERVISOR_MAX_ROUNDS SUPERVISOR_MAX_ROUNDS_HARD SUPERVISOR_STALL_LIMIT \
       SUPERVISOR_MAX_RUN_SECONDS \
  SUPERVISOR_USAGE_GUARD SUPERVISOR_USAGE_WEEK_GUARD \
  SUPERVISOR_PEER_IDLE_TIMEOUT SUPERVISOR_PEER_IDLE_TIMEOUT_CODEX SUPERVISOR_PEER_POLL \
  SUPERVISOR_MAX_CODEX_WAIT SUPERVISOR_IDLE_KILL_HOURS SUPERVISOR_STALE_DISABLE_HOURS \
  SUPERVISOR_WATCHDOG_POLL SUPERVISOR_IDLE_KILL_SECS SUPERVISOR_QUEUE_POLL \
  SUPERVISOR_PROMPT_WAIT SUPERVISOR_MAX_PROJECT_SECONDS SUPERVISOR_INJECT_CONFIRM_WAIT \
  SUPERVISOR_HANDSHAKE_WAIT SUPERVISOR_REQUIRE_HANDSHAKE \
  SUPERVISOR_SCOPE_GATE SUPERVISOR_BLOCK_DECISIONS SUPERVISOR_BOUNDED_REVIEW \
  SUPERVISOR_MAX_REMEDIATIONS SUPERVISOR_LEGACY_REPO_NOTES \
  SUPERVISOR_OUTCOME_PROTOCOL SUPERVISOR_OUTCOME_NUDGE_MAX SUPERVISOR_STALL_PARK_SECS \
  SUPERVISOR_VERIFIER_ENABLED SUPERVISOR_VERIFY_STEP_TIMEOUT SUPERVISOR_VERIFY_TOTAL_TIMEOUT \
  SUPERVISOR_VERIFY_GUARD SUPERVISOR_PREFLIGHT_ENABLE SUPERVISOR_PLAN_MODE \
  SUPERVISOR_COLLABORATION_MODE SUPERVISOR_PLAN_TIMEOUT SUPERVISOR_RESEARCH_TIMEOUT \
  SUPERVISOR_CONSULT_TIMEOUT SUPERVISOR_PREFLIGHT_TOTAL_TIMEOUT \
  SUPERVISOR_FOLLOWUP_TOTAL_TIMEOUT SUPERVISOR_CONSULT_WAIT_MAX \
  SUPERVISOR_ASK_USER_WAIT_DEGRADED \
  SUPERVISOR_TASK_IDLE_NEW_SECS \
  SUPERVISOR_USAGE_FRESH_SECS SUPERVISOR_USAGE_STALE_SECS \
  SUPERVISOR_PAUSE_RECHECK_SECS SUPERVISOR_PAUSE_PROBE_BACKOFF \
  SUPERVISOR_PAUSE_PROBE_BACKOFF_MAX SUPERVISOR_REVIEW_ORPHAN_SECS \
  SUPERVISOR_PREFLIGHT_LOCK_WAIT SUPERVISOR_PIPELINE_LOCK_WAIT \
  SUPERVISOR_PUMP_POLL SUPERVISOR_PUMP_IDLE_WAIT \
  SUPERVISOR_KEEP_MESSAGE_ARTIFACTS SUPERVISOR_SKILL_SCOPE \
  SUPERVISOR_SKILL_AUTONOMOUS SUPERVISOR_SKILL_AUDIT_TIMEOUT \
  SUPERVISOR_SKILL_INDEX_TTL SUPERVISOR_SKILL_INDEX_MAX \
  SUPERVISOR_BRANCH_MODE SUPERVISOR_WORK_BRANCH SUPERVISOR_PROTECTED_BRANCHES \
  SUPERVISOR_PERMISSION_MODE \
  SUPERVISOR_CLAUDE_EFFORT SUPERVISOR_CODEX_EFFORT \
  SUPERVISOR_CLAUDE_MODEL SUPERVISOR_CODEX_MODEL SUPERVISOR_REPORT_LANGUAGE \
  SUPERVISOR_RESUME_MAX_ATTEMPTS SUPERVISOR_LIMIT_RECHECK_COOLDOWN
