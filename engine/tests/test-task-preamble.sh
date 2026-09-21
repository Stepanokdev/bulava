#!/bin/bash
# A preamble that fences must actually fence.
#
# `compose_task_prompt` used to print "STRICTLY within the RunSpec (write_paths, acceptance,
# non-goals)" whenever a runspec existed at all — including the common case of mode=broad with an
# empty write_paths, where nothing is fenced. A worker obeyed that sentence by shrinking a six-step
# job to the two steps its (truncated) acceptance list described, and deleting the rest off the
# branch. The wording and the condition are both under test.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

spec() {  # $1=mode  $2=write_paths json array
  jq -nc --arg m "$1" --argjson p "$2" \
    '{schema:1, task_id:"t", mode:$m, objective:"o", acceptance:["a"], non_goals:[],
      surface:{visual:true}, write_paths:$p, verification_profile:"standard"}' > "$TMP/runspec.json"
}

echo "===== broad with no paths fences nothing, and must not claim to ====="
spec broad '[]'
out="$(compose_task_prompt "$TMP" "зроби X")"
case "$out" in *"СУВОРО"*|*"write_paths"*) bad "a broad run is still told it is fenced" ;;
  *) ok "no fence language on a broad run" ;; esac
case "$out" in *"зроби X"*) ok "the task itself is passed through" ;; *) bad "the task text was lost" ;; esac

echo
echo "===== real write_paths DO fence, and say so ====="
spec broad '["server/**"]'
out="$(compose_task_prompt "$TMP" "зроби X")"
case "$out" in *"write_paths"*) ok "a run with paths is told where it may write" ;;
  *) bad "a fenced run was not told" ;; esac
case "$out" in *"acceptance"*) ok "and that acceptance is how it will be CHECKED" ;;
  *) bad "acceptance is not explained" ;; esac
# The sentence that caused the loss must not come back: acceptance as a smaller task.
case "$out" in *"в межах наданого RunSpec (write_paths, acceptance"*) bad "the old fence sentence is back" ;;
  *) ok "acceptance is not presented as the fence" ;; esac

echo
echo "===== a narrowing mode fences even with no paths ====="
spec patch '[]'
out="$(compose_task_prompt "$TMP" "зроби X")"
case "$out" in *"write_paths"*) ok "patch mode keeps its fence" ;; *) bad "patch mode lost its fence" ;; esac

echo
echo "===== no runspec at all ====="
rm -f "$TMP/runspec.json"
out="$(compose_task_prompt "$TMP" "зроби X")"
case "$out" in *"RunSpec"*|*"write_paths"*) bad "an unscoped run mentions a spec it does not have" ;;
  *) ok "an unscoped run says nothing about specs" ;; esac

echo
[ "$fails" = 0 ] && echo "✅ task preamble: fences only when it fences" || echo "❌ task preamble: $fails problem(s)"
exit "$fails"
