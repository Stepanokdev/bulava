#!/bin/bash
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_DIR="$(cd "$HOOK_DIR/../supervisor" && pwd)"
BIN_DIR="$(cd "$HOOK_DIR/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
STATE_DIR="$SUP_STATE"
LOG="$STATE_DIR/supervisor.log"
strip_paid_api_env "$LOG" >/dev/null 2>&1 || true   # keep codex on the subscription
CODEX_USAGE="${SUPERVISOR_CODEX_USAGE_CMD:-$BIN_DIR/codex-usage.sh}"  # overridable for tests

input=$(cat)
questions=$(echo "$input" | jq -c '.tool_input.questions // empty')
[ -n "$questions" ] || exit 0
tool_use_id=$(echo "$input" | jq -r '.tool_use_id // empty')

cwd=$(echo "$input" | jq -r '.cwd // "."')
scope="$(supervision_scope "$cwd")"
[ -n "$scope" ] || exit 0
AWAITING=""; IDIR=""
if [ "${scope%%:*}" = "instance" ]; then
  IDIR="$(instance_dir "${scope#instance:}")"
  AWAITING="$IDIR/awaiting-codex"
fi

mkdir -p "$STATE_DIR"
rotate_log "$LOG"; rotate_log "$CODEX_LOG"
echo "$(date '+%F %T') QUESTION in $cwd: $(echo "$questions" | head -c 500)" >> "$LOG"
journal_event "${IDIR:--}" question "$(echo "$questions" | head -c 200)" \
  "$(jq -nc --arg tid "$tool_use_id" --argjson qs "$questions" \
    '{source:"worker", tool_use_id:$tid, questions:$qs}')"

# How long this hook may STAND STILL for a Codex window.
#
# It used to be five and a half hours. A question is asked from inside Claude's own turn, so that
# was not a proxy being patient — it was the implementer frozen solid for a third of a day over
# one decision, with the app showing a run that looked alive and was not. The consultation channel
# was bounded and this was not, which is the same freeze reached by a different door.
#
# The wait is now the same short one: worth standing still for a window about to turn over, and
# nothing more. Past that the question goes to the director, which is the honest degradation for
# something Claude explicitly asked to have decided — and it happens in seconds.
MAX_WAIT="${SUPERVISOR_CONSULT_WAIT_MAX:-180}"
"$CODEX_USAGE" >/dev/null 2>&1 || true
# Asked through the reader that knows what a reading is WORTH. Straight out of the file, an
# explicitly unknown reading became 0% (ask anyway, fine) but a two-hour-old 99% became a current
# one — and this hook would then hold a question for a window that had already turned over.
_cx="$(provider_state codex)"
codex_used="$(printf '%s' "$_cx" | awk '{print $3}')"
case "$codex_used" in ''|*[!0-9]*) codex_used=0 ;; esac
if [ "${_cx%% *}" = unknown ]; then
  echo "$(date '+%F %T') codex usage unknown — asking anyway; the call is the better test" >> "$LOG"
fi
codex_exhausted=0
if [ "${_cx%% *}" = exhausted ]; then
  codex_resets="$(printf '%s' "$_cx" | awk '{print $2}')"
  case "$codex_resets" in ''|*[!0-9]*) codex_resets=0 ;; esac
  wait=$(( codex_resets - $(date +%s) ))
  if [ "$wait" -gt 0 ] && [ "$wait" -le "$MAX_WAIT" ]; then
    if [ -n "$AWAITING" ]; then
      jq -n --argjson at "$(( codex_resets + 30 ))" \
        --argjson pid "$$" --arg rid "$(cat "$IDIR/run-id" 2>/dev/null || true)" \
        '{await_until:$at, pid:$pid, reason:"waiting for codex window reset"}
         + (if $rid == "" then {} else {run_id:$rid} end)' > "$AWAITING.tmp" 2>/dev/null \
        && mv -f "$AWAITING.tmp" "$AWAITING" 2>/dev/null
      trap 'rm -f "$AWAITING" "$AWAITING.tmp" 2>/dev/null' EXIT
    fi
    echo "$(date '+%F %T') codex window turns over in ${wait}s — holding the question that long" >> "$LOG"
    sleep $(( wait + 20 ))
    [ -n "$AWAITING" ] && rm -f "$AWAITING" 2>/dev/null
    trap - EXIT
    "$CODEX_USAGE" >/dev/null 2>&1 || true
    _cx="$(provider_state codex)"
    [ "${_cx%% *}" = exhausted ] && codex_exhausted=1 \
      || echo "$(date '+%F %T') codex window reset — asking for real" >> "$LOG"
  else
    codex_exhausted=1   # too long to stand still for; degrade rather than freeze
  fi
fi

persona="$(cat "$SUPERVISOR_DIR/SUPERVISOR.md" "$SUPERVISOR_DIR/STANDARDS.md" 2>/dev/null)"

prompt="$persona

---
Claude Code is working overnight in: $cwd
It paused to ask the user (Ivan) the following question(s). You are Ivan's proxy and you
decide unless the question genuinely belongs to him.
If SPEC.md, ROADMAP.md, DECISIONS.md or a requirements folder exists in the workspace,
read them before answering. You may inspect any files you need (read-only).

QUESTIONS (JSON, with the options Claude offers):
$questions

DECIDE YOURSELF — that is the default — for anything reversible and technical: approach
inside the agreed acceptance, order of work, file layout, internal APIs, a stack the repo
already fixed, depth of tests, any branch-local choice.

YOU ARE NOT LIMITED TO THE OPTIONS OFFERED. Claude writes the options, and Claude has a known
habit: it proposes a half of the work and calls the rest a later phase. Ivan\'s own words about
that are in the persona above, and they are not a preference — they are the standard you enforce.

So when EVERY option on offer leaves the job half-done — three locales of twenty-five with the
rest falling back to English, a feature behind a flag for now, tests for the happy path only,
we-can-do-the-hard-part-later — do NOT pick the least bad one. Answer with the COMPLETE work:
say plainly that none of the offered options is acceptable and state what finishing actually
means. That is still decision auto; refusing a bad menu is deciding, not escalating.

Escalate only if the complete work genuinely hits one of the five gates below — for instance if
finishing it needs an access we do not have. Being a lot of work is NOT a gate.

ESCALATE TO IVAN only if the question hits one of these five gates:
  missing_authority — needs an access, account, device or permission we do not have
  irreversible     — production write, publish/send, purchase, delete/migration, secret rotation
  product_fork     — the choice changes what the user sees as the product, privacy or data policy
  scope_expansion  — needs wider resources/write scope, or weakens the agreed acceptance
  no_safe_probe    — no safe reversible way to find out, and the options differ in what the
                     user would end up seeing

Answer with EXACTLY ONE line of JSON, no code fences, no prose around it:
{\"decision\":\"auto\"|\"ask\",\"reason_code\":\"\"|\"missing_authority\"|\"irreversible\"|\"product_fork\"|\"scope_expansion\"|\"no_safe_probe\",\"answer\":\"<for auto: the decision for each question — either the chosen option, or, when every option leaves the work half-done, an explicit refusal of the menu and a statement of the complete work to do instead — plus 1-3 sentences of reasoning in Ivan's voice, in the question's language>\",\"headline\":\"<for ask: one sentence Ivan can read in three seconds>\",\"recommendation\":\"<for ask: what you would do>\",\"default_action\":\"<for ask: what happens if he never answers — for missing_authority and irreversible this MUST be to not do it and finish blocked>\",\"unblock_action\":\"<for ask: the ONE concrete thing that unblocks it, and who does it>\"}"

raw=""
if [ "$codex_exhausted" = 0 ]; then
  CODEX_BIN="${SUPERVISOR_CODEX_BIN:-codex}"
  raw=$(cd "$cwd" 2>/dev/null && perl -e 'alarm shift; exec @ARGV' 240 \
    "$CODEX_BIN" exec $(codex_effort_flags) -c tools.web_search=true \
    --sandbox read-only --skip-git-repo-check \
    "$prompt" </dev/null 2>>"$CODEX_LOG")
else
  # Degraded, and said so. Claude is not left hanging: it gets an answer in seconds — "this one is
  # the director's" — instead of a hook that does not return until the window turns over.
  echo "$(date '+%F %T') codex unavailable ($(provider_unavailable_note codex)) — the question goes to the director instead of waiting it out" >> "$LOG"
  [ -n "$IDIR" ] && printf '%s\n' "$(provider_unavailable_note codex)" > "$IDIR/peer-codex.unavailable" 2>/dev/null || true
fi

json="$(printf '%s' "$raw" | grep -o '{.*}' | tail -1)"
decision="$(printf '%s' "$json" | jq -r '.decision // empty' 2>/dev/null)"
reason_code="$(printf '%s' "$json" | jq -r '.reason_code // empty' 2>/dev/null)"
answer="$(printf '%s' "$json" | jq -r '.answer // empty' 2>/dev/null)"
headline="$(printf '%s' "$json" | jq -r '.headline // empty' 2>/dev/null)"
recommendation="$(printf '%s' "$json" | jq -r '.recommendation // empty' 2>/dev/null)"
default_action="$(printf '%s' "$json" | jq -r '.default_action // empty' 2>/dev/null)"
unblock_action="$(printf '%s' "$json" | jq -r '.unblock_action // empty' 2>/dev/null)"
VALID_REASONS="missing_authority irreversible product_fork scope_expansion no_safe_probe"
_reason_known() {
  case " $VALID_REASONS " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac
}
_reason_needs_human() {
  case "${1:-}" in missing_authority|irreversible|product_fork|scope_expansion|no_safe_probe) return 0 ;;
                   *) return 1 ;; esac
}

_refuse_to_human() {  # $1 = why, for the log and the card
  decision="ask"; reason_code="no_safe_probe"
  headline="${1:-Не зміг прочитати рішення — вирішувати тобі.}"
  [ "$codex_exhausted" = 1 ] \
    && headline="Codex недоступний ($(provider_unavailable_note codex)), тому це питання до тебе."
  recommendation=""
  default_action=""
  unblock_action="${unblock_action:-Відповісти тут, у діалозі.}"
  answer=""
  echo "$(date '+%F %T') fail-closed: $1" >> "$LOG"
}

case "$decision" in
  auto)
    if _reason_needs_human "$reason_code"; then
      _refuse_to_human "Codex вирішив сам те, що позначив як «${reason_code}» — це суперечність."
    fi
    ;;
esac

case "$decision" in
  ask)
    if ! _reason_known "$reason_code"; then
      _refuse_to_human "невідомий reason_code «${reason_code:-порожній}» — жодного дефолту не застосовую."
    fi
    ;;
esac

case "$decision" in
  auto)
    if [ -z "$answer" ]; then
      decision="ask"; reason_code="no_safe_probe"
      headline="Codex відповів без рішення — вирішувати тобі."
      unblock_action="${unblock_action:-Відповісти тут, у діалозі.}"
    fi
    ;;
  ask) : ;;
  *)
    decision="ask"; reason_code="no_safe_probe"
    headline="${headline:-Не зміг прочитати рішення Codex — вирішувати тобі.}"
    recommendation=""
    default_action=""
    unblock_action="${unblock_action:-Відповісти тут, у діалозі.}"
    answer=""
    ;;
esac

# Whether the escalation is a JUDGEMENT or an ABSENCE.
#
# These are not the same thing, and treating them alike is how a temporary limit became an hour of
# silence. A reason_code from Codex means it read the question and decided this one belongs to the
# director. An empty answer means nobody read it at all — and one engine being out of window does
# not turn a reversible choice into something only Ivan may make.
degraded_escalation=0
if [ -z "$raw" ]; then
  degraded_escalation=1
  decision="ask"; reason_code="no_safe_probe"
  headline="Не зміг спитати Codex — рішення за тобою."
  recommendation=""
  default_action="Обрати найбезпечніший оборотний варіант і рухатись далі."
  unblock_action="Відповісти тут, у діалозі."
  if printf '%s' "$questions" | grep -qiE 'produc(tion|тив)|видали|delete|drop |migrat|міграц|secret|token|ключ|оплат|payment|purchase|publish|деплой|deploy|release|реліз'; then
    default_action="НЕ виконувати цю дію. Завершити роботу як blocked і назвати, що саме її розблокує."
    reason_code="irreversible"
  fi
fi

if [ "$decision" = "ask" ] && [ -n "$IDIR" ] && [ -d "$IDIR" ]; then
  ASK_ENABLE="$(cat "$STATE_DIR/ask-user-enabled" 2>/dev/null || echo "${SUPERVISOR_ASK_USER_ENABLE:-1}")"
  ASK_WAIT="$(cat "$STATE_DIR/ask-user-wait" 2>/dev/null || echo "${SUPERVISOR_ASK_USER_WAIT:-3600}")"
  case "$ASK_WAIT" in ''|*[!0-9]*) ASK_WAIT="${SUPERVISOR_ASK_USER_WAIT:-3600}";; esac
  # An hour is the right patience for a question Codex READ and judged to be the director's. It is
  # the wrong patience for one that reached him only because Codex had no window left — including
  # the ones a keyword flagged as risky, because that flag is a regex over the question text, not
  # a judgement, and an hour of frozen turn is a lot to spend on a guess.
  #
  # The wait shortens; what happens after it does NOT. A flagged question still ends in "do not do
  # this, finish blocked and name what unblocks it" — it just gets there in minutes.
  if [ "$degraded_escalation" = 1 ]; then
    _degraded_wait="${SUPERVISOR_ASK_USER_WAIT_DEGRADED:-180}"
    case "$_degraded_wait" in ''|*[!0-9]*) _degraded_wait=180 ;; esac
    [ "$_degraded_wait" -lt "$ASK_WAIT" ] && ASK_WAIT="$_degraded_wait"
  fi
  if [ "${ASK_ENABLE:-1}" = 1 ] && [ "${ASK_WAIT:-0}" -gt 0 ]; then
    ASKFILE="$IDIR/ask-user.json"; ANSFILE="$IDIR/answer.json"
    rm -f "$ANSFILE"
    ask_session="$(cat "$IDIR/session" 2>/dev/null || true)"
    shaped="$(echo "$questions" | jq -c '[.[] | {
      question:(.question//""), header:(.header//""), multiSelect:(.multiSelect//false),
      options:[((.options//[])[]) | (.label // .)],
      optionDescriptions:((.options//[]) | map(select(type == "object" and (.label//"") != "") |
        {key:.label, value:(.description//"")}) | from_entries)
    }]' 2>/dev/null)"
    jq -n --argjson qs "${shaped:-[]}" --arg s "$ask_session" --arg tid "$tool_use_id" \
      --argjson at "$(date +%s)" \
      --arg code "$reason_code" --arg head "$headline" --arg rec "$recommendation" \
      --arg def "$default_action" --arg unb "$unblock_action" \
      '{asked_at:$at, session:$s, tool_use_id:$tid, questions:$qs, reason_code:$code, headline:$head,
        recommendation:$rec, default_action:$def, unblock_action:$unb}' \
      > "$ASKFILE.tmp" 2>/dev/null && mv -f "$ASKFILE.tmp" "$ASKFILE"
    if [ -n "${IDIR:-}" ]; then
      jq -n --arg code "$reason_code" --arg head "$headline" --arg rec "$recommendation" \
            --arg def "$default_action" --arg unb "$unblock_action" --argjson at "$(date +%s)" \
        '{asked_at:$at, reason_code:$code, headline:$head, recommendation:$rec,
          default_action:$def, unblock_action:$unb}' \
        > "$IDIR/last-decision.json.tmp" 2>/dev/null \
        && mv -f "$IDIR/last-decision.json.tmp" "$IDIR/last-decision.json" 2>/dev/null || true
    fi
    jq -n --argjson at "$(( $(date +%s) + ASK_WAIT + 120 ))" \
      --argjson pid "$$" --arg rid "$(cat "$IDIR/run-id" 2>/dev/null || true)" \
      '{await_until:$at, pid:$pid, reason:"awaiting director decision"}
       + (if $rid == "" then {} else {run_id:$rid} end)' > "$AWAITING.tmp" 2>/dev/null \
      && mv -f "$AWAITING.tmp" "$AWAITING"
    trap 'rm -f "$ASKFILE" "$ASKFILE.tmp" "$AWAITING" "$AWAITING.tmp" "$ANSFILE" 2>/dev/null' EXIT
    echo "$(date '+%F %T') ESCALATED ($reason_code) — holding up to ${ASK_WAIT}s: $(printf '%s' "$headline" | head -c 160)" >> "$LOG"
    # Watched closely at first, then patiently.
    #
    # This used to be one `sleep 5` per turn of the loop, which cost the run up to five seconds of
    # doing nothing after he had already answered — the whole point of the card being a button in
    # the app rather than an errand. The first half-minute is polled five times a second, because
    # that is when an answer actually arrives; after that the wait can be measured in seconds
    # again without anybody noticing.
    started="$(date +%s)"
    deadline=$(( started + ASK_WAIT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if [ -f "$ANSFILE" ]; then
        user_answer="$(jq -r '.answer // empty' "$ANSFILE" 2>/dev/null)"
        rm -f "$ANSFILE" "$ASKFILE" "$AWAITING"; trap - EXIT
        if [ -n "$user_answer" ]; then
          echo "$(date '+%F %T') DIRECTOR DECIDED: $(echo "$user_answer" | head -c 300)" >> "$LOG"
          answer="🌙 Директор (Іван) вирішив особисто:

$user_answer

Продовжуй згідно з цією відповіддю — рішення фінальне, не перепитуй."
          decision="answered"
        fi
        break
      fi
      if [ $(( $(date +%s) - started )) -lt 30 ]; then sleep 0.2; else sleep 2; fi
    done
    rm -f "$ASKFILE" "$AWAITING" 2>/dev/null; trap - EXIT
  fi

  if [ "$decision" != "answered" ]; then
    echo "$(date '+%F %T') no director answer — applying default for $reason_code" >> "$LOG"
    # Nobody read the question, and it is not one of the irreversible ones. Control goes back to
    # the implementer, which is where the product says it belongs: Claude is the final technical
    # decision maker, and a reversible choice is exactly the kind it may make alone. Parking the
    # night on an absent reviewer is the failure this whole change exists to remove.
    if [ "$degraded_escalation" = 1 ] && [ "$reason_code" != irreversible ]; then
      _why_degraded="запит до Codex не повернув відповіді"
      [ "$codex_exhausted" = 1 ] && _why_degraded="$(provider_unavailable_note codex)"
      answer="🌙 Це питання ніхто за тебе не читав ($_why_degraded), і директор не відповів за ${ASK_WAIT}с.

Це оборотне рішення — воно твоє. Обери найбезпечніший оборотний варіант, коротко зафіксуй його в підсумку і рухайся далі; не зупиняй через це роботу.
Якщо, придивившись, воно виявиться незворотним або таким, що потребує чужих повноважень — не роби його, а заверши через report-outcome як blocked і назви рівно одну дію, яка його розблокує."
      decision="degraded-auto"
    else
    case "$reason_code" in
      missing_authority|irreversible|product_fork|scope_expansion|no_safe_probe)
        answer="🌙 Рішення за директором, а відповіді немає — і це рішення НЕ можна ухвалити за нього ($reason_code).

Питання: $(printf '%s' "$headline" | head -c 300)
Що розблокує: ${unblock_action:-відповідь директора}

НЕ виконуй цю дію і не обирай варіант замість нього. Зроби все інше, що не залежить від
цього рішення, а потім заверши роботу через report-outcome як blocked, і в підсумку назви
рівно одну дію, яка її розблокує. Часткову роботу опиши у звіті."
        ;;
      *)
        if [ -z "$default_action" ]; then
          answer="🌙 Відповіді від директора немає, і безпечного дефолту для цього питання теж немає.

Питання: $(printf '%s' "$headline" | head -c 300)
Що розблокує: ${unblock_action:-відповідь директора}

НЕ виконуй цю дію. Зроби все інше, що від неї не залежить, і заверши через report-outcome як
blocked, назвавши рівно одну дію, яка її розблокує."
        else
          answer="🌙 Відповіді від директора немає. Дію за безпечним дефолтом: ${default_action}.

${recommendation:+Рекомендація бригадира: $recommendation
}Продовжуй, зафіксуй це рішення в DECISIONS.md і не перепитуй."
        fi
        ;;
    esac
    fi
  fi
fi

[ -n "$answer" ] || answer="Обери найбезпечніший оборотний варіант, зафіксуй рішення в DECISIONS.md і продовжуй."

echo "$(date '+%F %T') ANSWER ($decision${reason_code:+/$reason_code}): $(echo "$answer" | head -c 400)" >> "$LOG"
journal_event "${IDIR:--}" answer "$(echo "$answer" | head -c 200)" \
  "$(jq -nc --arg d "$decision" --arg r "${reason_code:-}" --arg tid "$tool_use_id" \
      --arg a "$answer" --argjson qs "$questions" --arg head "$headline" \
      --arg rec "$recommendation" --arg def "$default_action" --arg unb "$unblock_action" \
      '{decision:$d, reason:$r,
        source:(if $d == "answered" then "director"
                elif $d == "auto" then "codex"
                elif $d == "degraded-auto" then "claude"
                else "gate" end),
        tool_use_id:$tid, answer:$a, questions:$qs, headline:$head,
        recommendation:$rec, default_action:$def, unblock_action:$unb}')"

prefix="🌙 Супервізор (Codex від імені Івана) вирішив:"
case "$decision" in
  answered) prefix="" ;;
  ask) prefix="" ;;
  degraded-auto) prefix="" ;;
esac

jq -n --arg reason "${prefix:+$prefix

}$answer${prefix:+

Продовжуй роботу згідно з цією відповіддю. Не зупиняйся, щоб перепитати — рішення фінальне.}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  },
  suppressOutput: true
}'
