#!/bin/bash
# Handing a project between chats rests on one statement by the engine: when there is no live
# session, a stale run-id does NOT cause a conflict, and the message takes the resume-by-session-id path.
#
# This is not theory. The first version of the handover worked one way round precisely because the
# old chat with its own binding ran into another chat's live run and got a conflict. After the
# project is freed there is no live session — and here is what actually comes of that.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"
. "$BIN/supervisor-lib.sh"
PROJ="$TMP/proj"; mkdir -p "$PROJ"; PROJ="$(canon_path "$PROJ")"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"

echo "===== живий прогін чужого чату справді дає conflict ====="
mkdir -p "$IDIR"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf 'run-OTHER\n' > "$IDIR/run-id"
printf '%s\n' "$SESSION" > "$IDIR/session"
tmux new-session -d -s "$SESSION" "sleep 300" 2>/dev/null
if tmux has-session -t "$SESSION" 2>/dev/null; then
  out="$(bash "$BIN/worker-send.sh" "$PROJ" "claude-MINE" "-" "run-MINE" "привіт" 2>&1)"
  case "$out" in *"TIER=conflict"*) ok "чужий живий прогін не приймає чуже повідомлення" ;;
    *) bad "очікувався conflict, отримано: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" ;; esac
else
  bad "не вдалося підняти тестову tmux-сесію"
fi

echo "===== після звільнення проєкту конфлікту вже немає ====="
# Exactly what the takeover does: stop the instance and kill the session.
bash "$BIN/night-shift.sh" stop "$PROJ" >/dev/null 2>&1
tmux kill-session -t "$SESSION" 2>/dev/null
[ -d "$IDIR" ] && bad "тека прогону лишилась після stop" || ok "запис прогону зник"
tmux has-session -t "$SESSION" 2>/dev/null && bad "tmux-сесія лишилась" || ok "tmux-сесія зникла"

out="$(bash "$BIN/worker-send.sh" "$PROJ" "claude-MINE" "-" "run-MINE" "привіт" 2>&1)"
case "$out" in
  *"TIER=conflict"*) bad "застарілий run-id досі дає conflict без живої сесії — передача неможлива" ;;
  *) ok "застарілий run-id більше не блокує: шлях вибрано не конфліктний" ;;
esac
# Without a real Claude session the resume cannot finish — and that is an honest result: what
# matters is that the engine TOOK the resume path instead of refusing over another run.
case "$out" in
  *"TIER=none"*|*"resume"*) ok "обрано шлях відновлення за session id" ;;
  *) bad "неочікуваний шлях: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" ;;
esac
grep -q "resume" "$SUPERVISOR_STATE_DIR/supervisor.log" 2>/dev/null \
  && ok "спроба відновлення записана в лог" || ok "лог не обовʼязковий для цього твердження"

echo "===== stop лишає сесію живою — тому підміна вбиває її окремо ====="
mkdir -p "$IDIR"; printf '%s\n' "$PROJ" > "$IDIR/project"; printf 'r\n' > "$IDIR/run-id"
printf '%s\n' "$SESSION" > "$IDIR/session"
tmux new-session -d -s "$SESSION" "sleep 300" 2>/dev/null
bash "$BIN/night-shift.sh" stop "$PROJ" >/dev/null 2>&1
if tmux has-session -t "$SESSION" 2>/dev/null; then
  ok "stop навмисне лишає tmux-сесію — новий чат успадкував би чужий контекст, якби її не вбити"
  tmux kill-session -t "$SESSION" 2>/dev/null
else
  bad "stop убив сесію — тоді припущення підміни хибне"
fi

echo
if [ "$fails" -eq 0 ]; then echo "✅ передача проєкту спирається на справжню поведінку движка"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
