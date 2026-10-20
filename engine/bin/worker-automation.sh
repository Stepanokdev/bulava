#!/bin/bash
#
# The product's automations, from a run in one of his chats: what there is, and making a new one
# when he asks for it — through Bulava, which alone writes them.
#
# An automation is a job Bulava starts by itself, on a schedule: each run is a new chat with no
# memory of this one, given only the brief. Work on code runs in a fresh copy of the product's
# folder: it changes code on a branch of its own for him to merge, or (--check-only) only reads,
# checks and reports. A job that is not about code (--job) runs in a plain folder of its own, with
# no git, reading his folders and using the services it is allowed.
#
# USAGE
#   automation list
#   automation create --name "Weekly SEO check" --when "weekly mon 09:00" --brief-file brief.md \
#                     [--check-only | --job [--reads FOLDER]… [--tools memex,…]] \
#                     [--report | --no-report] [--confirm-first]
#
#   --when      manual | hourly N (1–12) | daily HH:MM | weekdays HH:MM |
#               weekly mon,thu HH:MM | monthly D HH:MM — any schedule may end in "away": it then
#               starts once he has stepped away from the Mac. His own time zone.
#   --brief-file  what every run is told, whole: it is all a run will know. Up to 20,000 characters.
#   --check-only  runs read, build, check and report; nothing is left to merge.
#   --job       not about code: turn meeting notes into tasks, sum up a folder. Each run works in a
#               plain folder of its own (no git, no branch, no review) and only reads his folders.
#               For a folder with no git this is the only way: work on code needs git.
#   --reads FOLDER  a folder a job reads besides the product's own (repeat for more). Absolute.
#   --tools a,b  MCP servers a job may use with nobody there to approve a call (`memex`). Only
#               these: any other tool that would ask him is declined.
#   --report / --no-report  a written report after a run that did something. Default: yes for
#               work on code, no for a job — its run says in one line what it did.
#   --confirm-first  each run waits for his "Run" instead of starting.
#
#   Made at once, switched on, in this chat's product and folder; Bulava says so in this chat and
#   gives him "Turn off". Only from a chat he is in — an automation's own run makes none — and never
#   a second one with the same name. Exit 3: Bulava is not running. Exit 1: refused, with the reason.
#   Exit 2: a missing or unknown argument.
#
#   A run's chat is the one whose run folder it is called from ($IDIR/automation). A Codex chat has
#   none: it calls this by its full path, and Bulava names the chat with BULAVA_CHAT_TURN.
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
# Called as $IDIR/automation: the run's own folder says which project it is.
IDIR_SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="$SUP_STATE/automation-requests"
SERVICE="$REQ_DIR/service.json"
TIMEOUT="${NS_AUTOMATION_TIMEOUT:-20}"
usage() { sed -n '/^# USAGE/,/^set -u/p' "$SELF" | sed 's/^# \{0,1\}//; $d'; }

op="${1:-}"
case "$op" in
  list|create) shift ;;
  ""|-h|--help|help) usage; [ -n "$op" ]; exit $? ;;
  *) echo "automation: невідома дія «${op}» (list або create)" >&2; exit 2 ;;
esac

name=""; when=""; brief_file=""; mode="branch"; confirm=false; report=""; tools=""
reads=()
if [ "$op" = create ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --name|--when|--brief-file|--reads|--tools)
        # A flag at the very end has nothing to take: say so, never shift past the end.
        if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then
          echo "automation: $1 потребує значення" >&2; exit 2
        fi
        case "$1" in
          --name) name="$2" ;;
          --when) when="$2" ;;
          --brief-file) brief_file="$2" ;;
          --reads) reads+=("$2") ;;
          --tools) tools="${tools:+$tools,}$2" ;;
        esac
        shift 2 ;;
      --check-only) mode="check"; shift ;;
      --job) mode="job"; shift ;;
      --report) report=true; shift ;;
      --no-report) report=false; shift ;;
      --confirm-first) confirm=true; shift ;;
      *) echo "automation: невідомий параметр «$1»" >&2; exit 2 ;;
    esac
  done
  [ -n "$name" ] || { echo "automation: потрібна --name" >&2; exit 2; }
  [ -n "$when" ] || { echo "automation: потрібна --when (наприклад \"weekly mon 09:00\")" >&2; exit 2; }
  [ -n "$brief_file" ] && [ -s "$brief_file" ] || { echo "automation: потрібна --brief-file з текстом завдання" >&2; exit 2; }
  if [ "$mode" != job ] && { [ "${#reads[@]}" -gt 0 ] || [ -n "$tools" ]; }; then
    echo "automation: --reads і --tools — для завдання без коду (--job)" >&2; exit 2
  fi
fi

project="$(cat "$IDIR_SELF/project" 2>/dev/null || true)"
[ -n "$project" ] || project="$(pwd -P)"

if [ ! -f "$SERVICE" ]; then
  echo "automation: додаток Bulava не запущений." >&2
  exit 3
fi
svc_pid="$(jq -r '.pid // empty' "$SERVICE" 2>/dev/null)"
bulava_alive() {
  [ -n "$svc_pid" ] || return 0
  local err
  err="$(kill -0 "$svc_pid" 2>&1)" && return 0
  case "$err" in *"No such process"*) return 1 ;; esac
  # Not ours to signal — a Codex chat runs this in a sandbox that may not touch other processes.
  # Bulava says it is there again every few seconds; a stale word means it is gone.
  local mtime now
  mtime="$(stat -f %m "$SERVICE" 2>/dev/null || stat -c %Y "$SERVICE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [ $(( now - mtime )) -le 30 ]
}
if ! bulava_alive; then
  echo "automation: Bulava більше не працює (pid $svc_pid)." >&2
  exit 3
fi

id="$(date +%s)-$$-$RANDOM"
req="$REQ_DIR/$id.json"; done_file="$REQ_DIR/$id.done"
trap 'rm -f "$req" "$req.tmp" "$done_file"' EXIT
# A Codex chat has no run folder to say which chat it is: Bulava gives each of its turns a word in
# the environment instead, good for that turn only.
turn="${BULAVA_CHAT_TURN:-}"
# A run says which run it is, so Bulava answers that run's chat and no other in the same folder.
run="$(cat "$IDIR_SELF/run-id" 2>/dev/null || true)"
who='(if $turn != "" then {turn:$turn} elif $run != "" then {run:$run} else {} end)'
if [ "$op" = create ]; then
  reads_json="$(printf '%s\n' ${reads[@]+"${reads[@]}"} | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  tools_json="$(printf '%s\n' "$tools" | tr ',' '\n' | jq -R -s -c 'split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"
  jq -n --arg op "$op" --arg project "$project" --arg turn "$turn" --arg run "$run" --arg name "$name" --arg when "$when" \
        --rawfile brief "$brief_file" --arg mode "$mode" --argjson confirm "$confirm" \
        --argjson reads "$reads_json" --argjson tools "$tools_json" --arg report "$report" \
        '{op:$op, project:$project, name:$name, when:$when, brief:$brief, mode:$mode, confirmFirst:$confirm}
         + (if ($reads | length) > 0 then {reads:$reads} else {} end)
         + (if ($tools | length) > 0 then {tools:$tools} else {} end)
         + (if $report == "" then {} else {report:($report == "true")} end) + '"$who" > "$req.tmp"
else
  jq -n --arg op "$op" --arg project "$project" --arg turn "$turn" --arg run "$run" \
        '{op:$op, project:$project} + '"$who" > "$req.tmp"
fi
[ -s "$req.tmp" ] && mv -f "$req.tmp" "$req" || { echo "automation: не вдалося записати запит у $REQ_DIR" >&2; exit 1; }

waited=0
while [ ! -f "$done_file" ]; do
  if [ "$waited" -ge $(( TIMEOUT * 10 )) ]; then
    echo "automation: Bulava не відповіла за ${TIMEOUT}с." >&2
    exit 4
  fi
  sleep 0.1; waited=$(( waited + 1 ))
done
if [ "$(jq -r '.ok' "$done_file" 2>/dev/null)" != true ]; then
  echo "automation: $(jq -r '.error // "Bulava відмовила."' "$done_file" 2>/dev/null)" >&2
  exit 1
fi
case "$op" in
  list)
    jq -r '
      "\(.product): " + (if (.automations | length) == 0 then "no automations yet" else "\(.automations | length) automation(s)" end),
      (.automations[] | "- \(.name) · \(.when) · " + (if .on then "on" else "off" end)
         + (if .paused then " (\(.paused))" else "" end)
         + " · " + (if .mode == "check" then "only checks and reports" elif .mode == "job" then "does a job in a folder of its own, no code" else "changes code on a branch" end)
         + (if .lastRun then " · last run \(.lastRun | strflocaltime("%Y-%m-%d %H:%M"))" else "" end))' "$done_file" ;;
  create)
    jq -r '"made: «\(.name)» — \(.when), " + (if .mode == "job" then "a job in a folder of its own, reading \(.folder)" else "in \(.folder)" end) + ". Bulava said so in this chat and offers him “Turn off”; tell him what it will do."' "$done_file" ;;
esac
