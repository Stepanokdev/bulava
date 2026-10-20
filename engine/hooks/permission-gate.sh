#!/bin/bash
# What happens when Claude Code would ask a person for permission.
#
# One script, three of Claude Code's events (`hook_event_name` says which):
#
#   PermissionRequest — fires where a dialog would be shown, after the permission rules and the
#     auto-mode classifier have had their say. Chats approve Bash commands by default, declining
#     dynamic or critical-path rm/rmdir targets with a hint to use a precise literal path. Other
#     tools stay with the person: questions, plans and MCP interactions are not command permissions.
#     An automation (SUPERVISOR_UNATTENDED=1) keeps its existing policy: allow its own browser,
#     decline everything else so it can find another way or report the access it needs.
#   PermissionDenied  — the auto-mode classifier declined something. Written down, never retried.
#   Notification (permission_prompt) — a dialog is on screen right now. Written down with its
#     time, so the app can show "waiting for your permission" and the watchdog can see one that
#     nobody answers.
#
# Every automatic decision goes to permission-decisions.jsonl in the run's folder. Invalid input
# or a failed command check leaves Claude Code's own permission flow in place.
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
    if [ "${SUPERVISOR_UNATTENDED:-}" != 1 ]; then
      # Only command permissions are ours to answer. In particular, do not invent answers for
      # AskUserQuestion/ExitPlanMode or grant an MCP tool's user interaction. The hook input
      # does not include the rule that caused a prompt; check managed Bash asks separately:
      # https://code.claude.com/docs/en/hooks#permissionrequest-decision-control
      [ "$tool" = Bash ] || exit 0
      printf '%s' "$input" | jq -e '.tool_input.command | type == "string" and length > 0' >/dev/null 2>&1 || exit 0
      managed="$(printf '%s' "$input" | python3 "$BIN_DIR/lib/permission-policy.py" 2>/dev/null)" || exit 0
      [ -z "$managed" ] || exit 0
      unsafe="$(printf '%s' "$input" | python3 "$BIN_DIR/lib/permission-command.py" 2>/dev/null)" || exit 0
      if [ -n "$unsafe" ]; then
        why="Bulava declined this removal: $unsafe. Resolve variables or substitutions in a separate command, then rewrite the removal with an exact, literal path to the intended file or subdirectory, without globs. Do not remove a critical directory itself; choose a narrower target."
        record deny "$why"
        jq -nc --arg m "$why" \
          '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:$m}}}'
      else
        record allow "Bulava automatically approved this chat's command permission"
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
      fi
      exit 0
    fi
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
