#!/bin/bash
# Did the key that verifies the director's decisions change while a worker had a shell open?
#
# Everything else in this handshake defends itself. A permission carries a signature that is
# re-checked on every use, so who wrote that file, and when, stopped mattering — a forgery cannot
# prove itself at any hour, and a background process writing one after this hook has run gains
# nothing. What a forger would go for instead is the key the signatures are checked against: swap
# the public half, and anything can be signed.
#
# So this watches exactly that one file, and nothing else. An earlier version hashed the whole
# control folder and was a regression rather than a fence — `$IDIR/report-outcome` is a handle the
# worker is REQUIRED to run, it writes `outcome.json`, and the ordinary mandatory end of a run was
# therefore reported as forgery, taking the director's permission with it. The app answering a
# question during a long command was punished the same way. Neither is tampering.
#
# The key is written once, by the app, at launch. It has no business changing in the middle of
# somebody's shell command, and when it does, no permission is trusted until the app publishes it
# again and the director answers again.
#
# PreToolUse writes the fingerprint; PostToolUse compares it. Both are this file.
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$HOOK_DIR/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""')
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')
[ "$tool" = Bash ] || exit 0

scope="$(supervision_scope "$cwd")"
[ "${scope%%:*}" = "instance" ] || exit 0
IDIR="$(instance_dir "${scope#instance:}")"
[ -d "$IDIR" ] || exit 0

FP="$IDIR/.control-fp"

case "$event" in
  PreToolUse)
    # Two files, so that removing the fingerprint is itself detectable: the second one says a Pre
    # ran at all, and PostToolUse treats "armed but no fingerprint" as tampering rather than as
    # nothing to do.
    control_fingerprint "$IDIR" > "$FP.tmp" 2>/dev/null && mv -f "$FP.tmp" "$FP" 2>/dev/null
    : > "$IDIR/.control-armed" 2>/dev/null || true
    exit 0 ;;
  PostToolUse) ;;
  *) exit 0 ;;
esac

now="$(control_fingerprint "$IDIR")"
# A missing fingerprint is not a quiet pass.
#
# PreToolUse writes one before every Bash call, so by the time this runs there is always supposed
# to be one. Exiting 0 when it was absent turned deleting the file into the whole bypass: swap the
# key, remove `.control-fp`, and the comparison that would have caught it simply did not happen.
# Absent now means somebody removed it, and that is exactly as suspicious as a changed key.
if [ ! -s "$FP" ]; then
  if [ -e "$IDIR/.control-armed" ]; then
    before="(відбиток зник)"
  else
    exit 0     # genuinely no Pre for this call — a hook installed mid-session, nothing to compare
  fi
else
  before="$(cat "$FP" 2>/dev/null)"
fi
rm -f "$FP" "$IDIR/.control-armed" 2>/dev/null || true
[ "$now" = "$before" ] && exit 0

# The trusted key moved while a worker had a shell open. Nothing signed against it can be believed
# to have been signed by the app, so nothing is — until the app publishes its key again and the
# director answers again.
control_tamper_record "$IDIR" "ключ перевірки рішень змінився або відбиток зник під час виклику Bash"
rm -f "$(codex_grant_file "$IDIR")" "$(codex_answer_file "$IDIR")" 2>/dev/null || true
journal_event "$IDIR" control-tamper "ключ перевірки рішень змінився під час Bash — дозвіл на заміну Codex анульовано" \
  '{"source":"control-guard"}' 2>/dev/null || true
printf '%s [control-guard] the decision key changed across a Bash call (%s) — grants revoked\n' \
  "$(date '+%F %T')" "$IDIR" >> "$SUP_STATE/supervisor.log" 2>/dev/null || true

jq -n --arg r "🌙 Ключ, яким перевіряються рішення директора, змінився під час цієї команди. Дозвіл на заміну Codex анульовано, поки застосунок не опублікує ключ знову й директор не відповість наново." \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $r}}'
exit 0
