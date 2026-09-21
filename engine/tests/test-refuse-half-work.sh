#!/bin/bash
# Claude offers a menu of half-measures. The proxy is allowed to refuse the whole menu.
#
# «Codex should say here that all 25 localisations have to be done, because it is the controller
# that does not accept work done halfway.»
#
# The persona always carried the rule — Ivan's own words about half-options are in SUPERVISOR.md.
# What did not carry it was the CONTRACT: the answer field asked Codex to name "the chosen option",
# which quietly assumed one of the offered options was acceptable. When Claude offers "defer to
# phase 2", "do ten of twenty-five", and "your own answer", picking the least bad one is picking
# a half-finished product.
#
# So the contract now says the proxy is not limited to the options, and that refusing the menu is
# still deciding — `auto`, not an escalation, because "it is a lot of work" is not a gate. This
# test locks the plumbing: a refusal reaches the worker intact and does NOT wake the director.
#
# The proxy call is stubbed, so this suite costs no model calls. The judgement itself was verified
# once against the live model on Ivan's exact localisation example.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
PROJ="$TMP/repo"; mkdir -p "$PROJ"
. "$BIN_DIR/supervisor-lib.sh"
PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; mkdir -p "$IDIR"
printf '%s' "$PROJ" > "$IDIR/project"
RUN_ID="99999999-8888-7777-6666-555555555555"
printf '%s' "$RUN_ID" > "$IDIR/run-id"; printf '%s' "test-session" > "$IDIR/session"
export ORCHESTRATOR_RUN_ID="$RUN_ID"
export SUPERVISOR_ASK_USER_WAIT=6
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"

# Ivan's example, in the shape Claude actually asks it.
payload() {
  jq -n --arg cwd "$PROJ" '{cwd:$cwd, tool_use_id:"tool-locales", tool_input:{questions:[
    {question:"У проєкті 25 локалізацій. Зроблено 3, решта фолбек на англійську. Що робимо?",
     header:"Локалізація", multiSelect:false,
     options:[{label:"Окей, перенесемо в фазу 2",description:"Лишаємо 3"},
              {label:"Зроби ще 10 локалізацій",description:"Буде 13 із 25"},
              {label:"Свій варіант",description:"Опиши інакше"}]}]}}'
}
stub() {
  local out="$TMP/codex-stub.sh"
  { echo '#!/bin/bash'; printf 'cat <<%s\n%s\n%s\n' 'JSONEOF' "$1" 'JSONEOF'; } > "$out"
  chmod +x "$out"; export SUPERVISOR_CODEX_BIN="$out"
}

echo "===== a menu of half-measures is refused, not chosen from ====="
stub '{"decision":"auto","reason_code":"","answer":"Жоден із варіантів не прийнятний. Зроби всі 25 локалізацій повністю, без англомовного фолбеку для заявлених мов."}'
rm -f "$IDIR/ask-user.json"
out="$(payload | bash "$HOOK_DIR/answer-question.sh" 2>/dev/null)"

case "$out" in *"Жоден із варіантів не прийнятний"*) ok "the refusal reached the worker intact" ;;
                *) bad "the refusal did not reach the worker: $out" ;; esac
case "$out" in *"всі 25 локалізацій"*) ok "the complete work reached the worker" ;;
                *) bad "the complete work was lost on the way" ;; esac
if [ -f "$IDIR/ask-user.json" ]; then bad "the director was woken for work that is merely large"
else ok "refusing a menu did not escalate — it is a decision, not a gate" ;fi

line="$(tail -1 "$SUPERVISOR_STATE_DIR/decisions.jsonl" 2>/dev/null)"
if printf '%s' "$line" | jq -e '.decision == "auto" and .source == "codex"' >/dev/null 2>&1; then
  ok "journalled as an automatic decision by the proxy"
else bad "not journalled correctly: $line"; fi

echo "===== the contract itself allows it ====="
hook="$(cat "$HOOK_DIR/answer-question.sh")"
case "$hook" in *"NOT LIMITED TO THE OPTIONS OFFERED"*) ok "the prompt says the options are not a fence" ;;
                *) bad "the prompt still implies one of the options must be chosen" ;; esac
case "$hook" in *"Being a lot of work is NOT a gate"*) ok "size alone cannot become an escalation" ;;
                *) bad "nothing stops size being treated as a gate" ;; esac
case "$hook" in *"tools.web_search=true"*) ok "the proxy may look up how the world solved it" ;;
                *) bad "the proxy decides from first principles only" ;; esac

echo "===== and a genuine gate still reaches the director ====="
stub '{"decision":"ask","reason_code":"missing_authority","headline":"Треба доступ до App Store Connect","recommendation":"Видати ключ","default_action":"Не робити і завершити blocked","unblock_action":"Дати ключ"}'
rm -f "$IDIR/ask-user.json"
# `ask-user.json` means "holding for an answer RIGHT NOW" and is removed when the hold ends, so it
# has to be observed while the hook is still running — the same way test-decision-gate does it.
payload | bash "$HOOK_DIR/answer-question.sh" >/dev/null 2>&1 &
hook_pid=$!
found=0
for _ in 1 2 3 4 5 6 7 8; do [ -f "$IDIR/ask-user.json" ] && { found=1; break; }; sleep 1; done
wait "$hook_pid" 2>/dev/null || true
if [ "$found" = 1 ]; then ok "a real gate still escalates"
else bad "the gate stopped escalating — refusing menus must not disable the gates"; fi

echo
if [ "$fails" -eq 0 ]; then echo "✅ half-work menus are refused, gates still hold"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
