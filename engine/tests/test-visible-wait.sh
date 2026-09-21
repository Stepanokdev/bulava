#!/bin/bash
# A parked run must say what it is waiting for — and the two waits are not the same wait.
#
# «Would codex tell you to carry on anyway, but with a timer? If so, that timer probably has to
# be shown somehow.»
#
# `awaiting-codex` is written in two places in the question hook. One is Codex's own 5h window
# running out mid-question: the hook sleeps and asks again, and nobody is needed. The other is a
# question that cleared the escalation gates and is genuinely the director's. Both carry a
# deadline; only one of them is about him.
#
# The app now tells them apart by the marker's `reason`, so this pins the engine half of that
# contract: the deadline is real and in the future, the two reasons stay distinguishable, and the
# marker does not outlive the wait — a leftover deadline would leave the app showing a countdown
# over a run that is not waiting for anything.
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
RUN_ID="11111111-2222-3333-4444-555555555555"
printf '%s' "$RUN_ID" > "$IDIR/run-id"; printf '%s' "test-session" > "$IDIR/session"
export ORCHESTRATOR_RUN_ID="$RUN_ID"
export SUPERVISOR_ASK_USER_WAIT=6
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"

payload() {
  jq -n --arg cwd "$PROJ" '{cwd:$cwd, tool_use_id:"tool-wait", tool_input:{questions:[
    {question:"Чи публікувати білд у TestFlight?", header:"Реліз", multiSelect:false,
     options:[{label:"Так",description:""},{label:"Ні",description:""}]}]}}'
}
stub() {
  local out="$TMP/codex-stub.sh"
  { echo '#!/bin/bash'; printf 'cat <<%s\n%s\n%s\n' 'JSONEOF' "$1" 'JSONEOF'; } > "$out"
  chmod +x "$out"; export SUPERVISOR_CODEX_BIN="$out"
}

echo "===== a question held for the director is marked as HIS wait ====="
stub '{"decision":"ask","reason_code":"irreversible","headline":"Публікація у TestFlight","recommendation":"Публікувати","default_action":"Не публікувати","unblock_action":"Підтвердити"}'
rm -f "$IDIR/awaiting-codex" "$IDIR/ask-user.json"
# The marker lives only while the hook holds, so it has to be read from underneath a running hook.
payload | bash "$HOOK_DIR/answer-question.sh" >/dev/null 2>&1 &
hook_pid=$!
snapshot=""
for _ in 1 2 3 4 5 6 7 8; do
  [ -f "$IDIR/awaiting-codex" ] && { snapshot="$(cat "$IDIR/awaiting-codex" 2>/dev/null)"; break; }
  sleep 1
done

if [ -n "$snapshot" ]; then ok "the wait is marked while it holds"
else bad "no awaiting marker — the app has nothing to count down"; fi

reason="$(printf '%s' "$snapshot" | jq -r '.reason // empty' 2>/dev/null)"
case "$reason" in
  *director*) ok "the reason names the director, so the app can say it is his call" ;;
  "") bad "the marker carries no reason — both waits collapse into one silent pause" ;;
  *) bad "unexpected reason: $reason" ;;
esac
# The app reads "window"/"reset" as «resumes by itself». A director wait matching either of those
# would be shown as needing nobody — the one misclassification that actually costs him something.
case "$reason" in
  *window*|*reset*) bad "a director wait reads as a self-resuming one: $reason" ;;
  *) ok "it cannot be mistaken for the self-resuming wait" ;;
esac

until_at="$(printf '%s' "$snapshot" | jq -r '.await_until // empty' 2>/dev/null)"
now="$(date +%s)"
if printf '%s' "$until_at" | grep -qE '^[0-9]+$' && [ "$until_at" -gt "$now" ]; then
  ok "the deadline is a real timestamp in the future"
else bad "deadline unusable ($until_at) — a countdown needs something to count to"; fi

wait "$hook_pid" 2>/dev/null || true
if [ -f "$IDIR/awaiting-codex" ]; then
  bad "the marker outlived the wait — the app would count down over a run that is not waiting"
else ok "the marker is gone once the wait is over"; fi

echo "===== a decided question never claims to be waiting ====="
stub '{"decision":"auto","reason_code":"","answer":"Публікуй."}'
rm -f "$IDIR/awaiting-codex"
payload | bash "$HOOK_DIR/answer-question.sh" >/dev/null 2>&1
if [ -f "$IDIR/awaiting-codex" ]; then bad "an answered question left a deadline behind"
else ok "deciding leaves no wait to show"; fi

echo "===== the other wait keeps its own wording ====="
# The window-reset pause needs Codex's usage to be spent, which this suite does not simulate.
# What must hold is the wording the app classifies on — pinned at the source.
hook="$(cat "$HOOK_DIR/answer-question.sh")"
case "$hook" in *'reason:"waiting for codex window reset"'*)
    ok "the self-resuming wait still says window/reset" ;;
  *) bad "the window-reset reason was reworded — the app would read it as needing the director" ;;
esac
case "$hook" in *'reason:"awaiting director decision"'*)
    ok "the director wait still says director" ;;
  *) bad "the director reason was reworded" ;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ waits are marked, distinguishable and cleaned up"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
