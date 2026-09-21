#!/bin/bash
# The decision gate: who answers a worker's question, and what happens when nobody does.
#
# The policy this locks down replaced the opposite one. Every question a worker asked used to be
# put to the director first, holding the worker for up to an hour before the Codex proxy was even
# consulted — so "which of these two file layouts" cost an hour of the night and an interruption,
# while the director's actual complaint was that he gets called constantly and nothing is decided
# without him. The proxy existed all along; it was wired behind the wait.
#
# Now: the proxy decides, and the director is reached only through one of five gates
# (missing_authority, irreversible, product_fork, scope_expansion, no_safe_probe). And when
# nobody answers, an authority or irreversible question must NOT be decided for him — the run
# finishes blocked with the one action that unblocks it.
#
# The proxy call is stubbed via SUPERVISOR_CODEX_BIN, so this suite costs no model calls.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"

PROJ="$TMP/repo"; mkdir -p "$PROJ"
. "$BIN_DIR/supervisor-lib.sh"
# The instance is matched by canonical path, and a temp dir lives behind a symlink
# (/var → /private/var) — storing the raw path would never match.
PROJ="$(canon_path "$PROJ")"

# A supervised instance for this repo: the hook only engages when the run-id in the environment
# matches the instance's, which is what makes an unsupervised session pass questions to the human.
SLUG="$(slug_for "$PROJ")"
IDIR="$(instance_dir "$SLUG")"
mkdir -p "$IDIR"
printf '%s' "$PROJ" > "$IDIR/project"
RUN_ID="11111111-2222-3333-4444-555555555555"
printf '%s' "$RUN_ID" > "$IDIR/run-id"
printf '%s' "test-session" > "$IDIR/session"
export ORCHESTRATOR_RUN_ID="$RUN_ID"
# How long an escalation holds the worker, per case. Most of these cases are about what happens
# when NOBODY answers, and there the whole wait is dead time — one second proves it as well as
# six. The one case where he does answer keeps a longer window, and the hook now notices the
# answer within a fifth of a second, so that window is margin rather than delay.
escalation_wait() { printf '%s\n' "$1" > "$SUPERVISOR_STATE_DIR/ask-user-wait"; }
export SUPERVISOR_ASK_USER_WAIT=1
escalation_wait 1
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"

payload() {  # $1 = question text
  jq -n --arg q "$1" --arg cwd "$PROJ" \
    '{cwd:$cwd, tool_use_id:"tool-test", tool_input:{questions:[{question:$q, header:"Q", multiSelect:false,
                                        options:[{label:"A",description:"Safe and reversible"},
                                                 {label:"B",description:"Changes the product"}]}]}}'
}

# A stub standing in for the Codex proxy: prints whatever decision the case needs.
stub() {  # $1 = the JSON line the proxy returns ("" = proxy unreachable)
  local out="$TMP/codex-stub.sh"
  { echo '#!/bin/bash'
    if [ -z "$1" ]; then echo 'exit 1'; else printf 'cat <<%s\n%s\n%s\n' 'JSONEOF' "$1" 'JSONEOF'; fi
  } > "$out"
  chmod +x "$out"
  export SUPERVISOR_CODEX_BIN="$out"
}

run_hook() { payload "$1" | bash "$HOOK_DIR/answer-question.sh" 2>/dev/null; }

echo "===== a technical question is decided by the proxy, not by the director ====="
stub '{"decision":"auto","reason_code":"","answer":"Take option A - reversible and testable."}'
rm -f "$IDIR/ask-user.json"
out="$(run_hook "Where should the new module live: src/export.py or src/io/export.py?")"
if printf '%s' "$out" | grep -q "Take option A"; then ok "the proxy decision reached the worker"
else bad "the proxy decision did not reach the worker"; fi
if [ -f "$IDIR/ask-user.json" ]; then bad "the director was asked about a reversible technical choice"
else ok "the director was not interrupted"; fi
if printf '%s' "$out" | grep -q "Codex"; then ok "the answer says who decided"
else bad "the answer does not say who decided"; fi
decision_line="$(tail -1 "$SUPERVISOR_STATE_DIR/decisions.jsonl")"
if printf '%s' "$decision_line" | jq -e \
  '.kind == "answer" and .decision == "auto" and .source == "codex"
   and .tool_use_id == "tool-test"
   and .answer == "Take option A - reversible and testable."
   and (.questions[0].question | contains("Where should"))' >/dev/null 2>&1; then
  ok "the journal keeps Codex's full choice, reasoning and original question"
else bad "the journal kept only a truncated/unattributed decision"; fi

echo "===== a missing access escalates, and is NOT decided for him ====="
stub '{"decision":"ask","reason_code":"missing_authority","headline":"Needs App Store Connect access","recommendation":"Grant access or hand to the team","default_action":"Do not do it; finish blocked","unblock_action":"Ivan: log in to ASC"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
out="$(run_hook "I need to upload a build to App Store Connect - grant access?")"
if printf '%s' "$out" | grep -q "blocked"; then ok "the worker is told to finish blocked rather than choose"
else bad "no blocked instruction"; fi
if printf '%s' "$out" | grep -q "Ivan: log in to ASC"; then ok "the unblocking action is carried to the worker"
else bad "the unblocking action was lost"; fi
if printf '%s' "$out" | grep -qi "most complete"; then bad "it still invents a choice for him"
else ok "nothing was chosen on his behalf"; fi

echo "===== the escalation reaches the app with everything needed to decide ====="
stub '{"decision":"ask","reason_code":"product_fork","headline":"Show price before or after signup?","recommendation":"Before signup","default_action":"Do not choose; finish blocked","unblock_action":"Ivan: pick one"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
( run_hook "Price before or after signup?" >/dev/null 2>&1 ) &
hook_pid=$!
found=0
for _ in $(seq 1 80); do [ -f "$IDIR/ask-user.json" ] && { found=1; break; }; sleep 0.1; done
if [ "$found" = 1 ]; then
  ask="$(cat "$IDIR/ask-user.json")"
  for field in reason_code headline recommendation default_action unblock_action; do
    if printf '%s' "$ask" | jq -e --arg f "$field" '.[$f] | select(. != null and . != "")' >/dev/null 2>&1; then
      ok "the card carries $field"
    else bad "the card is missing $field"; fi
  done
  if [ "$(printf '%s' "$ask" | jq -r '.tool_use_id')" = "tool-test" ]; then
    ok "the app card is tied to the exact Claude question"
  else bad "the app card lost the Claude question identity"; fi
  if [ "$(printf '%s' "$ask" | jq -r '.questions[0].optionDescriptions.A')" = "Safe and reversible" ]; then
    ok "the app card preserves Claude's option explanations"
  else bad "the option explanations were dropped"; fi
else bad "no ask-user.json was written - the director would see nothing"; fi
wait "$hook_pid" 2>/dev/null

echo "===== the director's own answer wins ====="
stub '{"decision":"ask","reason_code":"product_fork","headline":"h","recommendation":"r","default_action":"d","unblock_action":"u"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
escalation_wait 6   # he answers in this one, so leave room for the answer to be written
( run_hook "Price before or after signup?" > "$TMP/answered.out" 2>/dev/null ) &
hook_pid=$!
for _ in $(seq 1 80); do [ -f "$IDIR/ask-user.json" ] && break; sleep 0.1; done
answered_at="$(date +%s)"
printf '{"answer":"Show the price immediately, before signup."}' > "$IDIR/answer.json"
wait "$hook_pid" 2>/dev/null
picked_up=$(( $(date +%s) - answered_at ))
if grep -q "Show the price immediately" "$TMP/answered.out"; then ok "his words reached the worker"
else bad "his answer was ignored"; fi
# And reached it AT ONCE. The wait loop used to turn over once every five seconds, so an answer
# he had already given sat unread for up to five — on a card whose whole point is that he answers
# it with a button in the app instead of being sent somewhere.
if [ "$picked_up" -le 2 ]; then ok "and were picked up at once (${picked_up}s)"
else bad "his answer sat unread for ${picked_up}s"; fi
escalation_wait 1
if grep -q "Директор" "$TMP/answered.out"; then ok "and are attributed to him"
else bad "his answer is not attributed to him"; fi

echo "===== proxy unreachable: a dangerous question is refused, not guessed ====="
stub ""
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
out="$(run_hook "Drop the production users table and recreate it from the migration?")"
if printf '%s' "$out" | grep -q "blocked"; then ok "an irreversible question with no proxy is refused"
else bad "it proceeded without any authority"; fi
if printf '%s' "$out" | grep -qi "most complete"; then bad "the old standing order still fires"
else ok "the old 'pick the most complete option' order is gone"; fi

echo "===== output we cannot read is not a decision ====="

# Unparseable output used to be handed to the worker as if the proxy had decided — authorization by
# accident. A decision we cannot read is a decision we did not get. (The card file is removed when
# the hook returns, so the assertions read the hook's OUTPUT, like the escalation tests above.)
stub 'this is not json at all, just prose about file layouts'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
out="$(run_hook "Куди покласти новий модуль — src/ або lib/?")"
case "$out" in
  *"prose about file layouts"*) bad "unreadable output was handed to the worker as an answer" ;;
  *) ok "unreadable output does not become an answer" ;;
esac
case "$out" in
  *blocked*) ok "it refuses and finishes blocked instead" ;;
  *) bad "unreadable output neither decided nor refused: $(printf '%s' "$out" | head -c 120)" ;;
esac

echo "===== an auto-decision with no answer in it decides nothing ====="

stub '{"decision":"auto","reason_code":"","answer":""}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
out="$(run_hook "Який лінтер запустити?")"
case "$out" in
  *blocked*) ok "an empty auto-answer escalates rather than passing silence along" ;;
  *) bad "an empty answer was treated as a decision" ;;
esac

echo "===== no_safe_probe never auto-applies a default ====="

# The whole meaning of the code is "there is no safe way to infer this". Inferring it because
# nobody replied is the one thing it must not do.
stub '{"decision":"ask","reason_code":"no_safe_probe","headline":"Не можу безпечно перевірити","recommendation":"","default_action":"Обрати найпростіший варіант","unblock_action":"Скажи, який варіант"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json"
out="$(run_hook "Чи можна перезапустити прод-сервіс для перевірки?")"
case "$out" in
  *"Обрати найпростіший варіант"*) bad "the unsafe default was handed to the worker as an instruction" ;;
  *) ok "the default was not used as an authorization" ;;
esac
case "$out" in
  *blocked*) ok "with no answer it refuses instead of applying the default" ;;
  *) bad "no_safe_probe did not refuse: $(printf '%s' "$out" | head -c 120)" ;;
esac
case "$out" in
  *"Скажи, який варіант"*) ok "and it still names what would unblock it" ;;
  *) bad "the unblocking action was lost" ;;
esac

echo "===== a semantic contradiction fails closed ====="

# JSON that parses is not a decision. An `auto` answer carrying a reason code that means "a human
# decides this" is a contradiction — the model classified the question as needing authority and then
# answered it anyway.
stub '{"decision":"auto","reason_code":"irreversible","answer":"Так, видаляй прод-базу."}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json" "$IDIR/last-decision.json"
out="$(run_hook "Чи можна видалити прод-базу для чистого тесту?")"
case "$out" in
  *"видаляй прод-базу"*) bad "an auto-answer on an irreversible question was passed through" ;;
  *) ok "auto + irreversible is refused, not obeyed" ;;
esac

# An unknown reason code cannot select a default branch — the branch IS the policy.
stub '{"decision":"ask","reason_code":"vibes","headline":"Щось незрозуміле","default_action":"Просто зроби як зручніше","unblock_action":"Скажи як треба"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json" "$IDIR/last-decision.json"
out="$(run_hook "Робити так чи інакше?")"
case "$out" in
  *"Просто зроби як зручніше"*) bad "an unknown reason code authorized its own default" ;;
  *) ok "an unknown reason code gets no default" ;;
esac
case "$out" in
  *blocked*) ok "and it refuses instead" ;;
  *) bad "unknown code neither refused nor decided" ;;
esac

# A known code with NO default must also refuse rather than invent one.
stub '{"decision":"ask","reason_code":"product_fork","headline":"Ціна до чи після реєстрації?","unblock_action":"Обери один варіант"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json" "$IDIR/last-decision.json"
out="$(run_hook "Ціна до чи після реєстрації?")"
case "$out" in
  *blocked*) ok "a known code with no default refuses too" ;;
  *) bad "a missing default was filled in from somewhere" ;;
esac

echo "===== the decision outlives the hook, so the receipt can print it ====="

# `ask-user.json` means "holding right now" and is removed when the hook returns — always before the
# worker records its outcome. The durable copy is what makes the unblocking action reach the page.
stub '{"decision":"ask","reason_code":"missing_authority","headline":"Потрібен доступ до ASC","recommendation":"Дай доступ","default_action":"Не роби; заверши blocked","unblock_action":"Іван: залогінься в App Store Connect"}'
rm -f "$IDIR/ask-user.json" "$IDIR/answer.json" "$IDIR/last-decision.json"
out="$(run_hook "Треба залити білд у App Store Connect — дати доступ?")"
[ ! -f "$IDIR/ask-user.json" ] && ok "the holding marker is gone once the hook returns" \
                              || bad "ask-user.json was left behind"
[ -f "$IDIR/last-decision.json" ] && ok "the decision itself survived" \
                                  || bad "nothing durable was written — the receipt has nothing to print"
[ "$(jq -r '.unblock_action' "$IDIR/last-decision.json" 2>/dev/null)" = "Іван: залогінься в App Store Connect" ] \
  && ok "with the unblocking action intact" || bad "the unblocking action was lost"

echo "===== an unsupervised session still reaches the human ====="
stub '{"decision":"auto","answer":"x"}'
out="$(payload "anything?" | ORCHESTRATOR_RUN_ID=not-this-run bash "$HOOK_DIR/answer-question.sh" 2>/dev/null)"
if [ -z "$out" ]; then ok "day mode is a no-op - the question goes to the human"
else bad "it answered on the human behalf outside a supervised run"; fi

echo
[ "$fails" = 0 ] && { echo "✅ test-decision-gate PASSED"; exit 0; }
printf "❌ test-decision-gate FAILED (%s)\n" "$fails"; exit 1
