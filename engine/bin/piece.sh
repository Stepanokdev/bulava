#!/bin/bash
#
# A long project, one piece at a time (bin/lib/pieces.sh has the why).
#
# USAGE
#   piece plan "Вхід: email, пароль, помилки" "Стрічка: картки, оновлення" …
#       Add pieces to the plan, in the order they are to be built: what the next one stands on
#       comes first. Titles already in the plan are skipped. Re-planning later is fine.
#   piece start ["назва"] -- "критерій 1" "критерій 2" …
#       Open a piece: the next planned one, or the one named (added if it is not in the plan).
#       Its criteria are what the review will hold it to, so write what a person must SEE — each
#       one checkable, 3 to 10 of them. Refused while another piece is open. When the project has a
#       specification, the review holds the piece to it as well: criteria cannot water it down.
#   piece status
#       The plan: ✓ accepted, ▶ open, · later.
#
#   Nothing here accepts a piece. The review does, when it passes the open piece; then it sends
#   you to the next one.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; . "$BIN_DIR/supervisor-lib.sh"; . "$BIN_DIR/lib/pieces.sh"
usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

op="${1:-}"
case "$op" in
  plan|start|status) shift ;;
  ""|-h|--help) usage; [ -n "$op" ]; exit $? ;;
  *) echo "piece: невідома дія «${op}» (plan, start або status)" >&2; exit 2 ;;
esac

# The run this process belongs to — the same lookup `add-check` makes.
scope="$(worker_scope "$PWD")"
if [ "${scope%%:*}" = instance ]; then
  IDIR="$(instance_dir "${scope#instance:}")"
elif [ ! -d "${IDIR:-}" ]; then
  if [ -n "${ORCHESTRATOR_RUN_ID:-}" ]; then
    echo "❌ нічого не записано — прогін $ORCHESTRATOR_RUN_ID більше не існує" >&2; exit 1
  fi
  IDIR="$(instance_dir "$(slug_for "$PWD")")"
fi
[ -d "$IDIR" ] || { echo "❌ нема теки прогону — запусти через night-shift" >&2; exit 1; }

case "$op" in
status)
  pieces_present "$IDIR" || { echo "плану ще немає: piece plan \"…\" \"…\""; exit 0; }
  pieces_ladder "$IDIR"
  exit 0 ;;

plan)
  [ "$#" -gt 0 ] || { echo "❌ назви шматків: piece plan \"перший\" \"другий\" …" >&2; exit 2; }
  titles="$(python3 -c 'import json,sys; print(json.dumps([t.strip() for t in sys.argv[1:] if t.strip()]))' "$@")" \
    || { echo "❌ не зміг прочитати назви" >&2; exit 1; }
  pieces_json "$IDIR" | jq --argjson t "$titles" '
      .pieces as $p
      | reduce $t[] as $title (.;
          if any(.pieces[]; .title == $title) then .
          else .pieces += [{n: ((.pieces | map(.n) | max // 0) + 1), title: $title, state: "planned", criteria: []}]
          end)' | pieces_write "$IDIR" || { echo "❌ не зміг записати план" >&2; exit 1; }
  pieces_ladder "$IDIR"
  exit 0 ;;

start)
  title=""
  if [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; then title="$1"; shift; fi
  [ "${1:-}" = "--" ] || { echo "❌ після назви потрібен -- і критерії: piece start \"назва\" -- \"критерій\" …" >&2; exit 2; }
  shift
  [ "$#" -ge 1 ] || { echo "❌ шматок без критеріїв не відкриваю: що має побачити людина, коли він готовий?" >&2; exit 2; }
  [ "$#" -le 10 ] || { echo "❌ більше 10 критеріїв — це не один шматок. Розбий його: piece plan \"…\" \"…\"" >&2; exit 2; }
  open="$(piece_open "$IDIR")"
  if [ -n "$open" ]; then
    echo "❌ шматок $(jq -r .n <<<"$open") «$(jq -r .title <<<"$open")» ще не прийнятий рев'ю. Доведи його до кінця й заяви результат — наступний відкриється після приймання." >&2
    exit 2
  fi
  [ -n "$title" ] || title="$(piece_next_planned_title "$IDIR")"
  [ -n "$title" ] || { echo "❌ у плані нічого не лишилось — назви шматок: piece start \"назва\" -- …" >&2; exit 2; }
  proj="$(cat "$IDIR/project" 2>/dev/null || printf '%s' "$PWD")"
  base="$(git -C "$proj" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$base" ] || { echo "❌ у $proj нема git-коміту, від якого міряти шматок" >&2; exit 1; }
  crit="$(python3 -c 'import json,sys; print(json.dumps([c.strip() for c in sys.argv[1:] if c.strip()]))' "$@")" \
    || { echo "❌ не зміг прочитати критерії" >&2; exit 1; }
  if pieces_json "$IDIR" | jq -e --arg t "$title" 'any(.pieces[]; .title == $t and .state == "accepted")' >/dev/null 2>&1; then
    echo "❌ «${title}» уже прийнятий. Якщо в ньому знайшовся дефект — назви новий шматок, наприклад «$title: виправити …»" >&2
    exit 2
  fi
  pieces_json "$IDIR" | jq --arg t "$title" --argjson c "$crit" --arg b "$base" --arg ts "$(date '+%F %T')" '
      (if any(.pieces[]; .title == $t) then .
       else .pieces += [{n: ((.pieces | map(.n) | max // 0) + 1), title: $t, state: "planned", criteria: []}] end)
      | .pieces |= map(if .title == $t then .state = "open" | .criteria = $c | .base_sha = $b | .started_at = $ts else . end)' \
    | pieces_write "$IDIR" || { echo "❌ не зміг відкрити шматок" >&2; exit 1; }
  p="$(piece_open "$IDIR")"
  echo "відкрив шматок $(jq -r .n <<<"$p") «${title}» від ${base:0:9}. Рев'ю оцінить його за цими критеріями й лише його diff:"
  jq -r '.criteria | to_entries[] | "  P\(.key + 1). \(.value)"' <<<"$p"
  note="$(piece_spec_note "$IDIR" "$proj")"
  [ -n "$note" ] && printf '\n%s\n' "$note"
  exit 0 ;;
esac
