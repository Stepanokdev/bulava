#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
QDIR="$SUP_STATE/queue"; PEND="$QDIR/pending"; DONE="$QDIR/done"
RUNNER_PID="$QDIR/runner.pid"; STOP_FLAG="$QDIR/stop"; CURRENT="$QDIR/current"
mkdir -p "$PEND" "$DONE"

runner_alive() { [ -f "$RUNNER_PID" ] && kill -0 "$(cat "$RUNNER_PID" 2>/dev/null)" 2>/dev/null; }
next_num() {
  local max=0 n d
  for d in "$PEND"/*/; do [ -d "$d" ] || continue; n="${d%/}"; n="${n##*/}"; n="${n%%-*}"; n=$((10#$n)); [ "$n" -gt "$max" ] && max=$n; done
  printf '%03d' $((max + 10))
}

cmd="${1:-status}"; [ $# -gt 0 ] && shift

case "$cmd" in
  add)
    PROJ="$(canon_path "${1:-$PWD}")"
    [ -d "$PROJ" ] || { echo "❌ Нема такої теки: ${1:-$PWD}" >&2; exit 1; }
    [ $# -gt 0 ] && shift
    TASK="$*"
    [ -n "$TASK" ] || TASK="Виконай задачу цього проєкту повністю за SPEC.md (а якщо його нема — за вмістом репозиторію). Доведи до кінця, без заглушок і 'на потім'."
    entry="$PEND/$(next_num)-$(slug_for "$PROJ")"
    mkdir -p "$entry"
    printf '%s\n' "$PROJ" > "$entry/project"
    printf '%s\n' "$TASK" > "$entry/task"
    echo "➕ У чергу ($(basename "$entry")): $PROJ"
    echo "   задача: $TASK"
    runner_alive || echo "   (черга не запущена — стартуй: night-queue run)"
    ;;

  list)
    n=0
    for d in $(ls -1d "$PEND"/*/ 2>/dev/null | sort); do
      n=$((n+1)); d="${d%/}"
      echo "$(basename "$d" | cut -d- -f1).  $(cat "$d/project")"
      echo "      → $(clip_utf8 100 < "$d/task")"
    done
    [ "$n" = 0 ] && echo "(черга порожня)"
    if runner_alive; then
      echo "▶ зараз виконується: $(cat "$CURRENT" 2>/dev/null || echo '?')  (runner pid $(cat "$RUNNER_PID"))"
    else
      echo "⏸ runner не запущено (night-queue run)"
    fi
    dc=$(ls -1d "$DONE"/*/ 2>/dev/null | wc -l | tr -d ' ')
    [ "$dc" != 0 ] && echo "✓ завершено в історії: $dc (див. $DONE)"
    ;;

  remove)
    num="${1:?usage: night-queue remove <number>}"
    target="$(ls -1d "$PEND"/*/ 2>/dev/null | grep -E "/0*${num}-" | head -1)"
    [ -n "$target" ] || { echo "Не знайдено запис №$num"; exit 1; }
    rm -rf "${target%/}"; echo "🗑  прибрано №$num"
    ;;

  clear)
    rm -rf "$PEND"/*/ 2>/dev/null; echo "🗑  чергу очищено (поточний проєкт, якщо є, не чіпаю)"
    ;;

  run)
    if runner_alive; then echo "▶ runner вже працює (pid $(cat "$RUNNER_PID"))"; exit 0; fi
    if _legacy_present && ! _any_instance; then
      echo "⚠️ Активні залишки старої (легасі) нічної зміни. Спершу мігруй:" >&2
      echo "      night-shift stop --all && tmux kill-session -t night" >&2
      exit 1
    fi
    [ -n "$(ls -1d "$PEND"/*/ 2>/dev/null)" ] || { echo "Черга порожня — спершу night-queue add <dir> [task]"; exit 1; }
    rm -f "$STOP_FLAG"
    nohup "$BIN_DIR/queue-runner.sh" >/dev/null 2>&1 &
    echo $! > "$RUNNER_PID"
    sleep 1
    runner_alive && echo "▶ Черга запущена (pid $(cat "$RUNNER_PID")). Проєкти підуть по одному." \
                  || { echo "❌ runner не піднявся (див. $QDIR/runner.log)"; exit 1; }
    ;;

  stop)
    if runner_alive; then
      touch "$STOP_FLAG"
      echo "⏹ Сигнал зупинки надіслано — runner завершиться після поточного проєкту."
      echo "   (негайно: kill $(cat "$RUNNER_PID"))"
    else
      echo "runner не працює."
    fi
    ;;

  status)
    if runner_alive; then
      echo "runner: ▶ працює (pid $(cat "$RUNNER_PID"))"
      echo "поточний: $(cat "$CURRENT" 2>/dev/null || echo '—')"
    else
      echo "runner: ⏸ не запущено"
    fi
    echo "у черзі: $(ls -1d "$PEND"/*/ 2>/dev/null | wc -l | tr -d ' ')  ·  завершено: $(ls -1d "$DONE"/*/ 2>/dev/null | wc -l | tr -d ' ')"
    [ -f "$QDIR/runner.log" ] && { echo "--- останні події:"; tail -5 "$QDIR/runner.log"; }
    ;;

  *)
    echo "usage: night-queue add <dir> [task] | list | remove <n> | clear | run | stop | status"
    exit 1
    ;;
esac
