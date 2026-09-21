#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

QUESTION="$*"
[ -n "$QUESTION" ] || { echo 'usage: consult-codex "precise engineering question"' >&2; exit 2; }
ASK_DIR="$(canon_path "$PWD")"
LOG="$SUP_STATE/supervisor.log"

# Which run is asking. This used to be decided by the FOLDER, and that is how the second engineer
# disappeared: a worker reading an allowed neighbouring repository — or simply standing in its own
# instance folder to run the handle that lives there — was told it was not in a supervised run, and
# wrote "I am deciding this myself" as if that were an engineering judgement rather than a broken pipe.
scope="$(worker_scope "$ASK_DIR")"
if [ "${scope%%:*}" != instance ]; then
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    note="консультацію відхилено: токен $ORCHESTRATOR_RUN_ID не належить жодному живому прогону (тека: $ASK_DIR)"
  else
    note="консультацію відхилено: немає токена прогону — Codex доступний лише всередині супервізованого прогону (тека: $ASK_DIR)"
  fi
  printf '%s\n' "$note" >&2
  # A refusal that leaves no trace is how this lived for five days: the only witness was a line of
  # Claude's own prose in the feed.
  printf '%s [consult-codex] %s\n' "$(date '+%F %T')" "$note" >> "$LOG" 2>/dev/null || true
  exit 2
fi
IDIR="$(instance_dir "${scope#instance:}")"
# Two different directories, and conflating them is what sent Codex to read a state folder.
#   PROJ    — the repository this RUN is about; the diff in the brief is its diff.
#   ASK_DIR — where Codex actually starts looking. The worker's own folder when that is real
#             product code, the project otherwise.
PROJ="$(canon_path "$(run_project_dir "$IDIR" "$ASK_DIR")")"
STATE_ROOT="$(canon_path "$SUP_INSTANCES")"
case "$ASK_DIR/" in
  "$STATE_ROOT"/*) ASK_DIR="$PROJ" ;;   # the run's notes, not anybody's source
esac
[ -d "$ASK_DIR" ] || ASK_DIR="$PROJ"
# The depth and model the composer is showing. A consultation started from inside the worker's
# tmux session inherits them from its launch line; one started by anything else did not, and
# quietly ran at the engine's default instead of the director's choice.
run_env_load "$IDIR"
RUN_ID="$(cat "$IDIR/run-id" 2>/dev/null || echo unknown)"
DISPATCH_ID="$(jq -r '.id // "unknown"' "$IDIR/dispatch.json" 2>/dev/null || echo unknown)"
CODEX_USAGE="${SUPERVISOR_CODEX_USAGE_CMD:-$BIN_DIR/codex-usage.sh}"
CODEX_BIN="${SUPERVISOR_CODEX_BIN:-codex}"
strip_paid_api_env "$LOG" >/dev/null 2>&1 || true
unset OPENAI_API_KEY CODEX_API_KEY 2>/dev/null || true

ROOT="$IDIR/consultations/$RUN_ID"; mkdir -p "$ROOT"
lock="$ROOT/.counter-lock"; tries=0
while ! mkdir "$lock" 2>/dev/null; do tries=$((tries + 1)); [ "$tries" -lt 200 ] || { echo "Could not allocate a consultation record." >&2; exit 1; }; sleep 0.05; done
n="$(cat "$ROOT/count" 2>/dev/null || echo 0)"; case "$n" in ''|*[!0-9]*) n=0;; esac
n=$((n + 1)); printf '%s\n' "$n" > "$ROOT/count"; rmdir "$lock" 2>/dev/null || true
CALL_DIR="$ROOT/$(printf '%04d' "$n")"; mkdir -p "$CALL_DIR"
printf '%s\n' "$QUESTION" > "$CALL_DIR/question.md"

# Is there a Codex to ask, right now?
#
# This used to read `.five_hour.used_percentage // 0` through a jq that turned an explicitly
# UNKNOWN reading into "0% used" — the most optimistic possible answer to "I could not find out".
#
# And when it did see an exhausted window it would WAIT for it, up to five and a half hours, with
# `sleep`. A consultation runs inside Claude's own turn: that is not a peer being patient, it is
# the implementer sitting frozen for a third of a day over one question. A short reset is worth
# waiting out; anything longer is answered honestly, and Claude goes on and asks again later.
"$CODEX_USAGE" >/dev/null 2>&1 || true
# The one thing the meter cannot see: it reads the last SUCCESSFUL measurement, so a login that
# died an hour ago still shows a half-full window. Costs sixty milliseconds and is asked every
# time — a reading that was fresh a minute ago proves the login worked THEN, not now.
if codex_signed_out "$CODEX_BIN"; then
  CODEX_SIGNED_OUT=1
else
  CODEX_SIGNED_OUT=0
fi
state_line="$(provider_state codex)"
state="${state_line%% *}"
reset="$(printf '%s' "$state_line" | awk '{print $2}')"
used="$(printf '%s' "$state_line" | awk '{print $3}')"
case "$used" in ''|*[!0-9]*) used=0 ;; esac
case "$reset" in ''|*[!0-9]*) reset=0 ;; esac

decline() {   # $1=human reason
  printf '%s\n' "$1" | tee "$CALL_DIR/final.md" >&2
  jq -n --argjson n "$n" --arg status unavailable --arg st "$state" --argjson used "$used" \
        --argjson reset "$reset" \
    '{call:$n, status:$status, provider_state:$st, codex_used_percent:$used, resets_at:$reset}' \
    > "$CALL_DIR/metrics.json"
  # Only if this is still our run. A consultation can outlive the run that started it, and the
  # journal stamps whichever run-id is on disk NOW — so a late entry would be filed as the new
  # run's business.
  if run_still_ours "$IDIR"; then
    journal_event "$IDIR" peer-consultation-unavailable "consultation $n: Codex unavailable ($state)" '{"source":"worker"}'
    # A consultation stays non-blocking on purpose — it runs inside Claude's own turn, and freezing
    # that for days over one question helps nobody. But the absence is recorded on the RUN, so the
    # review gate cannot later mistake an unreadable meter for a Codex that took part.
    codex_owe "$IDIR" consultation "$1"
    # And the question itself, so it is asked again when Codex comes back instead of depending on
    # Claude remembering it four hours and thirty messages later.
    codex_owe_consultation "$IDIR" "$n" "$QUESTION" "$1"
  fi
  exit 75
}

if [ "$CODEX_SIGNED_OUT" = 1 ]; then
  state=signed_out   # so the record says WHICH kind of unavailable, not the stale meter's opinion
  decline "Codex не авторизований — \`codex login status\` каже «Not logged in», тож викликати нема чим — облікових даних просто немає. Потрібен повторний вхід у Codex; лічильник цього не бачить, бо читає останнє вдале вимірювання. Працюй далі на доказах з репозиторію й повтори питання, коли вхід відновлять — прогін від цього не завершиться без Codex."
fi

# Only a POSITIVE reading that the window is gone stops the call. A meter that cannot be read is
# not a reason to refuse to ask — the call itself is the better test, and it fails in seconds.
if [ "$state" = exhausted ]; then
  wait=$(( reset - $(date +%s) ))
  max_wait="${SUPERVISOR_CONSULT_WAIT_MAX:-180}"
  if [ "$wait" -gt 0 ] && [ "$wait" -le "$max_wait" ]; then
    # Short enough to be worth standing still for, and the marker says WHO is waiting and for how
    # long, so nothing later mistakes an abandoned wait for one still in progress.
    jq -n --argjson at "$(( reset + 30 ))" --argjson pid "$$" --arg rid "$RUN_ID" \
       '{await_until:$at, pid:$pid, run_id:$rid,
         reason:"peer consultation waiting for the codex window to reset"}' > "$IDIR/awaiting-codex.tmp" \
      && mv -f "$IDIR/awaiting-codex.tmp" "$IDIR/awaiting-codex"
    # Only ever clear OUR marker. A consultation can outlive the run that started it, and a blind
    # `rm` on the way out would then delete the wait a NEW run is in the middle of.
    drop_wait_marker() {
      [ "$(jq -r '.pid // empty' "$IDIR/awaiting-codex" 2>/dev/null)" = "$$" ] \
        && rm -f "$IDIR/awaiting-codex" 2>/dev/null
      rm -f "$IDIR/awaiting-codex.tmp" 2>/dev/null
      return 0
    }
    trap drop_wait_marker EXIT
    sleep $(( wait + 20 ))
    drop_wait_marker; trap - EXIT
    "$CODEX_USAGE" >/dev/null 2>&1 || true
    state="$(provider_state codex)"; state="${state%% *}"
  fi
  if [ "$state" = exhausted ]; then
    if [ "$reset" -gt "$(date +%s)" ]; then
      decline "Codex недоступний зараз ($(provider_unavailable_note codex)). Працюй далі на доказах з репозиторію й постав це питання знову після $(date -r "$reset" '+%H:%M' 2>/dev/null || echo "скидання вікна"). Прогін від цього не завершиться без Codex: перевірка все одно його чекатиме, а якщо чекати задовго — директор вирішить сам."
    fi
    decline "Codex недоступний зараз ($(provider_unavailable_note codex)). Працюй далі на доказах з репозиторію й повтори питання пізніше. Прогін від цього не завершиться без Codex: перевірка все одно його чекатиме."
  fi
fi

task="$(jq -r '.task // empty' "$IDIR/dispatch.json" 2>/dev/null || true)"
context=""
for f in peer-claude.md peer-codex.md peer-alignment.md; do [ -s "$IDIR/$f" ] && context="$context
$f: $IDIR/$f"; done
# Codex arrives with no memory of this conversation, by design. What it needs is not a transcript
# but the operational picture of the ONE task in hand: the objective, what the tree looks like
# now, and anything the director has said since that the worker has not been given yet. Built
# fresh from live state on every call — it is a view, not a store.
brief="$(thread_brief "$IDIR" "$PROJ" "" 2>/dev/null || true)"
prompt="You are a read-only peer engineer advising Claude during an active autonomous implementation.
Claude remains the implementer and final technical decision maker. Answer the precise question;
do not restart the task, produce a generic plan, edit files, or merely reassure Claude.

TASK
$task

${brief:+WHERE THE WORK STANDS NOW
$brief
}
AVAILABLE PREFLIGHT CONTEXT
${context:-(none; inspect the repository and current diff directly)}

WHERE YOU ARE LOOKING
You start in $ASK_DIR. The run's own repository — the one the diff above belongs to — is $PROJ.$(
  [ "$ASK_DIR" = "$PROJ" ] || printf '\nThese differ: the question is about the folder you start in, while the state of the work above describes the run'"'"'s repository.'
)

PRECISE QUESTION
$QUESTION

Inspect the current repository and diff read-only. Separate requirements from optional polish.
For interactive behavior compare activation paths (tap/drag/combine/chain), visual orientation
against actual direction or footprint, animation order, target reachability, and post-use cleanup.
Reply with exactly these compact sections: RECOMMENDATION, MISSED RISKS, REPOSITORY EVIDENCE,
PROOF, CONFIDENCE. Name uncertainty honestly and make checks concrete."

TIMEOUT="${SUPERVISOR_CONSULT_TIMEOUT:-900}"
started="$(date +%s)"
( cd "$ASK_DIR" && perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
  "$CODEX_BIN" exec $(codex_effort_flags) --sandbox read-only --skip-git-repo-check --ephemeral --json \
  -o "$CALL_DIR/final.md" "$prompt" </dev/null > "$CALL_DIR/events.jsonl" 2> "$CALL_DIR/stderr.log" )
rc=$?; ended="$(date +%s)"; elapsed=$((ended - started))
usage="$(jq -sc '[.. | objects | .usage? // empty] | last // {}' "$CALL_DIR/events.jsonl" 2>/dev/null || echo '{}')"
[ -n "$usage" ] || usage='{}'

# What Codex actually said on its way out. The reason was always on disk and never reached anyone:
# the feed showed a bare "code 1" and the director was left guessing between a crash, an expired
# login and a subscription that had run out.
stderr_note() {
  [ -s "$CALL_DIR/stderr.log" ] || return 0
  grep -v -e '^[[:space:]]*$' -e 'Reading additional input from stdin' "$CALL_DIR/stderr.log" 2>/dev/null \
    | tail -3 | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g' | cut -c1-300
}

if [ "$rc" = 0 ] && [ -s "$CALL_DIR/final.md" ]; then
  status=ok
else
  # An empty answer with a clean exit used to be reported as a SUCCESSFUL consultation that
  # happened to say nothing: the script printed a failure to stderr and then exited 0. Claude read
  # the zero, believed it had asked, and moved on having been told nothing.
  case "$rc" in
    0)   status=empty;   reason="Codex завершився без помилки, але не сказав нічого" ;;
    142) status=timeout; reason="Codex не відповів за ${TIMEOUT}с — виклик зупинено за таймаутом" ;;
    *)   status=failed;  reason="Codex зупинився з помилкою (код $rc) через ${elapsed}с" ;;
  esac
  note="$(stderr_note)"
  [ -n "$note" ] && reason="$reason — $note"
  hint="$(auth_failure_hint "$note")"
  [ -n "$hint" ] && reason="$reason
$hint"
fi

jq -n --argjson n "$n" --arg run "$RUN_ID" --arg dispatch "$DISPATCH_ID" --argjson rc "$rc" \
  --argjson seconds "$elapsed" --argjson usage "$usage" --arg status "$status" \
  --arg reason "${reason:-}" \
  --arg effort "${SUPERVISOR_CODEX_EFFORT:-}" --arg model "${SUPERVISOR_CODEX_MODEL:-}" \
  '{call:$n,run_id:$run,dispatch_id:$dispatch,status:$status,exit_code:$rc,
    duration_seconds:$seconds,usage:$usage,codex_effort:$effort,codex_model:$model}
   + (if $reason == "" then {} else {reason:$reason} end)' > "$CALL_DIR/metrics.json"

if [ "$status" = ok ]; then
  # Codex answered, so the queue of questions he never saw is no longer owed: the worker is back in
  # touch with him and can ask the rest itself.
  run_still_ours "$IDIR" && codex_consultations_settled "$IDIR"
  run_still_ours "$IDIR" && journal_event "$IDIR" peer-consultation "consultation $n completed" "$(jq -nc --argjson n "$n" --arg q "$(printf '%s' "$QUESTION" | head -c 180)" '{source:"worker",call:$n,question:$q}')"
  cat "$CALL_DIR/final.md"
  exit 0
fi

printf '%s\n' "$reason" > "$CALL_DIR/final.md"
printf '%s\n' "$reason" >&2
echo "Працюй далі на доказах з репозиторію й повтори питання пізніше (запис: $CALL_DIR). Прогін від цього не завершиться без Codex." >&2
printf '%s [consult-codex] consultation %s %s — %s\n' "$(date '+%F %T')" "$n" "$status" "$reason" >> "$LOG" 2>/dev/null || true
run_still_ours "$IDIR" && journal_event "$IDIR" peer-consultation-failed "consultation $n: $reason" \
  "$(jq -nc --argjson n "$n" --arg s "$status" '{source:"worker",call:$n,status:$s}')"
case "$status" in
  empty)   exit 3 ;;
  timeout) exit 4 ;;
  *)       exit "$rc" ;;
esac
