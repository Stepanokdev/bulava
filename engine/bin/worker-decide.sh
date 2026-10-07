#!/bin/bash
#
# Ask the director to decide — in a report Bulava draws the choices beside, on the Mac and on the
# phone.
#
# A plan with ten forks used to end in "answer 1–10 in the chat", and he typed numbers from memory
# with the report in another window. Now the report carries its questions in a file beside it, and
# Bulava shows each one with its options, the agent's advice marked, a comment field and one
# "Send". His answer arrives in this run's chat as his message, as if he had typed it: every item
# with what he chose, or "not decided — do not start it, ask me".
#
# USAGE
#   decide <report.html | report.md>
#
#   Beside the report, a decisions.json:
#     {"title": "Що робимо далі",
#      "items": [
#        {"id": "leak", "title": "Закрити витік паролів", "detail": "одне-два речення контексту",
#         "options": ["Беремо", "Пізніше", "Ні"], "recommended": "Беремо", "comment": true},
#        ...]}
#   id: 1–40 letters, digits, - or _, unique. options: 2–6 short labels (default «Take it / Later /
#   No», shown in his language). recommended: one of the options — shown as advice, never
#   preselected; with the default options it may be named in English ("Take it").
#   comment: whether a comment field is offered (default true). At most 40 items.
#
#   The report must be inside this run's project and not hidden; a note (.md) gets a page made
#   beside it. Bulava puts the report into the chat of the run working in this project; the chat
#   must exist — an unattended run with no chat has nobody to ask this way.
#
#   Changing decisions.json later makes it a new set of questions: an answer to the old one is
#   refused, and he is asked again.
#
#   Exit 3: Bulava is not running. Exit 1: refused, with the reason (a bad decisions.json says
#   exactly what is wrong). Exit 4: Bulava did not answer in time.
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
# Called as $IDIR/decide: the run's own folder says which project it is.
IDIR_SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="$SUP_STATE/decision-requests"
SERVICE="$REQ_DIR/service.json"
TIMEOUT="${NS_DECIDE_TIMEOUT:-20}"
usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

target="${1:-}"
case "$target" in ""|-h|--help|help) usage; [ -n "$target" ]; exit $? ;; esac
[ $# -eq 1 ] || { echo "decide: один аргумент — шлях до звіту" >&2; exit 2; }
case "$target" in /*) ;; *) target="$(pwd -P)/$target" ;; esac
project="$(cat "$IDIR_SELF/project" 2>/dev/null || true)"
[ -n "$project" ] || project="$(pwd -P)"

[ -f "$target" ] || { echo "decide: немає файла $target" >&2; exit 1; }
questions="$(dirname "$target")/decisions.json"
[ -f "$questions" ] || { echo "decide: поруч зі звітом немає decisions.json ($questions)" >&2; exit 1; }
jq -e '(.items | type == "array" and length > 0)' "$questions" >/dev/null 2>&1 \
  || { echo "decide: decisions.json — не JSON або без непорожнього масиву \"items\"" >&2; exit 1; }

if [ ! -f "$SERVICE" ]; then
  echo "decide: додаток Bulava не запущений — спитай у чаті звичайним повідомленням." >&2
  exit 3
fi
svc_pid="$(jq -r '.pid // empty' "$SERVICE" 2>/dev/null)"
if [ -n "$svc_pid" ] && ! kill -0 "$svc_pid" 2>/dev/null; then
  echo "decide: Bulava більше не працює (pid $svc_pid) — спитай у чаті звичайним повідомленням." >&2
  exit 3
fi

id="$(date +%s)-$$-$RANDOM"
req="$REQ_DIR/$id.json"; done_file="$REQ_DIR/$id.done"
trap 'rm -f "$req" "$req.tmp" "$done_file"' EXIT
jq -n --arg path "$target" --arg project "$project" '{path:$path, project:$project}' > "$req.tmp" \
  && mv -f "$req.tmp" "$req" || { echo "decide: не вдалося записати запит у $REQ_DIR" >&2; exit 1; }

waited=0
while [ ! -f "$done_file" ]; do
  if [ "$waited" -ge $(( TIMEOUT * 10 )) ]; then
    echo "decide: Bulava не відповіла за ${TIMEOUT}с." >&2
    exit 4
  fi
  sleep 0.1; waited=$(( waited + 1 ))
done
if [ "$(jq -r '.ok' "$done_file" 2>/dev/null)" != true ]; then
  echo "decide: $(jq -r '.error // "Bulava відмовила."' "$done_file" 2>/dev/null)" >&2
  exit 1
fi
echo "Звіт у чаті «$(jq -r '.chat' "$done_file")»: $(jq -r '.report' "$done_file")"
echo "Його відповідь прийде в цей чат його повідомленням. Не починай того, що він лишив невирішеним."
