#!/bin/bash
# What happens when Claude Code would ask a person for permission.
#
# A worker runs in a tmux pane nobody watches. When Claude Code stopped on one of its dialogs —
# a tool outside the allowed set, a browser tool nobody had clicked "always allow" on — the run
# waited for a click that could not come, and the engine counted the unanswered tool call as
# waiting, not frozen, so nothing ever moved it. His settings had collected 605 such clicks.
#
# One script, three of Claude Code's events (`hook_event_name` says which):
#
#   PermissionRequest — fires where a dialog would be shown, after the permission rules and the
#     auto-mode classifier have had their say. In an automation's run (SUPERVISOR_UNATTENDED=1)
#     nobody is there, so the answer is given here: its own browser (mcp__browser__*, headless, a
#     throwaway profile) is allowed; anything else is declined with the reason, so the model goes
#     another way or ends the run as blocked and names what it needs. With a person there this
#     says nothing and the dialog appears as it always has.
#   PermissionDenied  — the auto-mode classifier declined something. Written down, never retried.
#   Notification (permission_prompt) — a dialog is on screen right now. Written down with its
#     time, so the app can show "waiting for your permission" and the watchdog can see one that
#     nobody answers.
#
# Every decision goes to permission-decisions.jsonl in the run's folder: the morning report says
# what a night run was refused. The script never blocks a tool by failing — exit code 2 means
# nothing to this event, and a script that breaks must leave Claude Code's own flow as it was.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$HOOK_DIR/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || exit 0

input="$(perl -e 'alarm 5; local $/; print <STDIN>' 2>/dev/null || true)"
[ -n "$input" ] || exit 0
field() { printf '%s' "$input" | jq -r "$1 // \"\"" 2>/dev/null; }

event="$(field '.hook_event_name')"
tool="$(field '.tool_name')"
cwd="$(field '.cwd')"
slug="$(active_instance_for_cwd "$cwd" 2>/dev/null)"
idir=""; [ -n "$slug" ] && idir="$(instance_dir "$slug")"

# What the tool was asked to do, in one short line: a command, a path, a URL.
what="$(printf '%s' "$input" | jq -r '
  (.tool_input // {}) as $i
  | ($i.command // $i.file_path // $i.path // $i.url // $i.pattern // ($i | tostring))
  | tostring | gsub("[\\n\\r]+"; " ") | .[0:240]' 2>/dev/null)"

record() {  # $1=decision $2=why
  [ -n "$idir" ] && [ -d "$idir" ] || return 0
  jq -nc --arg at "$(date '+%F %T')" --arg ev "$event" --arg tool "$tool" --arg what "$what" \
     --arg decision "$1" --arg why "$2" \
     '{at:$at, event:$ev, tool:$tool, what:$what, decision:$decision, why:$why}' \
     >> "$idir/permission-decisions.jsonl" 2>/dev/null || true
}

case "$event" in
  PermissionRequest)
    [ "${SUPERVISOR_UNATTENDED:-}" = 1 ] || exit 0
    case "$tool" in
      mcp__browser__*)
        record allow "the automation's own browser: no window, a throwaway profile"
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        ;;
      mcp__accounts__*)
        record allow "Bulava's browser: lent to this run alone, the director's own sites closed to it"
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        ;;
      *)
        why="Nobody is at the computer to approve this: it is an automation's unattended run. Do the work without it. If the task cannot be finished without it, end the run with report-outcome blocked and name exactly the access that is needed, so it can be given during the day."
        record deny "nobody there to approve it"
        jq -nc --arg m "$why" \
          '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
        ;;
    esac
    ;;
  PermissionDenied)
    record auto-denied "declined by Claude Code's auto mode"
    ;;
  Notification)
    kind="$(field '.notification_type')"
    case "$kind" in
      permission_prompt|"")
        [ -n "$idir" ] && [ -d "$idir" ] || exit 0
        msg="$(field '.message')"
        jq -nc --arg at "$(date +%s)" --arg msg "$msg" --arg kind "${kind:-permission_prompt}" \
          '{at:($at|tonumber), message:$msg, kind:$kind}' > "$idir/permission-wait.json.tmp" 2>/dev/null \
          && mv -f "$idir/permission-wait.json.tmp" "$idir/permission-wait.json" 2>/dev/null
        record waiting "${msg:-a permission dialog is on screen}"
        ;;
    esac
    ;;
esac
exit 0
