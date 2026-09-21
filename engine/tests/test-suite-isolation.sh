#!/bin/bash
# The suite runs side by side, so a test that reaches for something by NAME reaches into a sibling.
#
# One did. `test-task-continuity.sh` simulated the app being quit with `pkill -f message-pump.sh`
# — a suite that starts no pump of its own, so the pattern had nothing of its own to match and
# killed whichever pump `test-chat-pipeline.sh` happened to be running at that moment. It passed
# alone, it passed in most whole-suite runs, and it failed in the verifier's: the one invocation
# nobody watches interactively, reported as a flaky chat pipeline rather than as what it was.
#
# Three things are pinned, all the same shape: a process killed by name must be scoped to the run
# doing the killing, a tmux server torn down must be one the test started, and a suite writing
# under ~/.claude must have a HOME of its own.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

echo "===== nothing kills a process it does not own ====="
# This file is left out of its own scan: the only `pkill` in it is the pattern it searches FOR,
# and a scanner that reports itself is a scanner nobody keeps.
# A kill by pattern is only ever safe if the pattern names THIS run: its slug, its instance, its
# own temp tree, or a pid it captured itself.
offenders=""
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
  # Comments are prose, including the one at the top of this file.
  case "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')" in '#'*) continue ;; esac
  case "$text" in
    *'$SLUG'*|*'$IDIR'*|*'$TMP'*|*'$PROJ'*|*'$SESSION'*|*'$!'*|*'$VICTIM'*|*'$pid'*|*'$PID'*) continue ;;
  esac
  offenders="$offenders
  $file:$line $(printf '%s' "$text" | sed 's/^[[:space:]]*//' | cut -c1-90)"
done < <(grep -n -E '(^|[^a-zA-Z_-])(pkill|killall)' \
           $(ls ./*.sh | grep -v 'test-suite-isolation.sh') 2>/dev/null)

if [ -z "$offenders" ]; then
  ok "every kill-by-name in the suite is scoped to the run doing it"
else
  bad "a test kills processes by a name it does not own:$offenders"
fi

echo "===== and a tmux server torn down is one the test owns ====="
# This used to check only that the words TMUX_TMPDIR appeared in the file. That turned out not to
# be enough: in `test-workspace-container.sh` the `tmux kill-server` trap stood ONE LINE ABOVE
# `export TMUX_TMPDIR`, so any early exit fired on the default socket. Three of the director's
# sessions were severed that way in one day. So now it looks for a homeless command, not a mention.
unowned=""
for f in ./*.sh; do
  case "$(basename "$f")" in lib-tmux.sh|test-suite-isolation.sh) continue ;; esac
  grep -nE '(^|[^_a-zA-Z-])tmux +kill-server' "$f" 2>/dev/null | grep -qv '^\s*#' || continue
  unowned="$unowned $(basename "$f")"
done
if [ -z "$unowned" ]; then
  ok "no suite calls tmux kill-server directly — it goes through tmux_cleanup"
else
  bad "tears down a tmux server without the ownership check:$unowned"
fi

# …and the condition itself, shown at work. The control server lives on ANOTHER socket — exactly
# where the director's session lives — and it has to survive all three ways this test can end.
control_dir="$(mktemp -d)"
control_sock="$control_dir/control.sock"

# `-S <socket>`, not `TMUX_TMPDIR=`.
#
# TMUX_TMPDIR only chooses the socket's DIRECTORY, and when `$TMUX` is in the environment — and it
# always is, when the command is run from inside tmux — the client goes to the inherited server and
# ignores the directory. So the «control session on another socket» was being created on the
# director's working server, and the cleanup at the end of the loop tore down that one. This test
#
# `-S` names the socket file unambiguously, and `TMUX` is removed from the environment here so
# there is nothing left to inherit.
control_tmux() { env -u TMUX tmux -S "$control_sock" "$@"; }
control_up()    { control_tmux new-session -d -s guard "sleep 120" 2>/dev/null; }
control_alive() { control_tmux has-session -t guard 2>/dev/null; }

# Before starting anything — make sure the control socket is NOT the one we are working in.
# A cheap condition that would have saved a severed day, had it stood here earlier.
if [ -n "${TMUX:-}" ] && [ "$control_sock" = "${TMUX%%,*}" ]; then
  bad "the control socket is the working one — refusing to run the isolation cases"
  control_up() { :; }
  control_alive() { return 1; }
fi
probe_script() {   # $1=how the test ends
  cat <<PROBE
set -u
. "$PWD/lib-tmux.sh"
T="\$(mktemp -d)"
trap 'tmux_cleanup; rm -rf "\$T"' EXIT INT TERM
case "$1" in
  early) tmux_cleanup; exit 3 ;;                      # exit BEFORE isolation — the worst case
esac
mkdir -p "\$T/tmux"; tmux_isolate "\$T/tmux"
tmux new-session -d -s own "sleep 30" 2>/dev/null
case "$1" in
  normal) exit 0 ;;
  interrupt) kill -INT \$\$ ;;
esac
PROBE
}
for how in normal early interrupt; do
  control_up
  if ! control_alive; then bad "control server did not start (${how})"; continue; fi
  probe_script "$how" > "$control_dir/probe.sh"
  ( bash "$control_dir/probe.sh" ) >/dev/null 2>&1
  if control_alive; then
    ok "a test ending «${how}» leaves another socket's session alone"
  else
    bad "a test ending «${how}» killed a tmux server it does not own"
  fi
  control_tmux kill-server 2>/dev/null || true
done
rm -rf "$control_dir"

echo "===== and a test writing into ~/.claude writes into its OWN ====="
# The same hazard through a different door: three suites write a worker session file under
# ~/.claude/sessions, which `_turn_running` reads. Sharing the real one would have them answering
# each other's questions about whether a turn is running.
# Mentioning the path is not touching it: one suite passes it to a function that only builds a
# string. What matters is a WRITE — a redirect, a mkdir, a touch, a copy or a removal.
borrowed=""
for f in ./*.sh; do
  grep -qE '(>>?|mkdir -p|touch|rm -rf|rm -f|cp -f|mv -f)[^|]*"?\$HOME/\.claude' "$f" 2>/dev/null || continue
  grep -qE '^[[:space:]]*export HOME=' "$f" 2>/dev/null && continue
  borrowed="$borrowed $(basename "$f")"
done
if [ -z "$borrowed" ]; then
  ok "every suite that writes under ~/.claude has a HOME of its own"
else
  bad "writes into the real ~/.claude:$borrowed"
fi

echo "===== the check itself catches the thing it is for ====="
# A guard that cannot fail proves nothing, so it is shown a real offender.
probe="$(mktemp -d)/offender.sh"
printf '#!/bin/bash\npkill -f "message-pump.sh"\n' > "$probe"
if grep -n -E '(^|[^a-zA-Z_-])(pkill|killall)' "$probe" | grep -qv '\$'; then
  ok "an unscoped kill is recognised as one"
else
  bad "the scan would not notice an unscoped kill"
fi
rm -rf "$(dirname "$probe")"

echo "===== a variable name ends where the author thinks it ends ====="
# `«$dir»` looks like a quoted variable, and to bash 3.2 it is `$dir` plus the first byte of the
# «»» character in the name: the result is `dir\xC2`, which nobody set, and under `set -u` the
# script dies at runtime — only on the branch nobody ran. That is how `allow-git` fell, and an
mixed=""
for f in ../bin/*.sh ../hooks/*.sh ./*.sh; do
  [ -f "$f" ] || continue
  # The scan is done by perl, not grep: BSD grep does not understand `\x80` in a pattern and
  # flagged every file containing any Cyrillic at all. Here a byte is taken as a byte — it looks
  # for the start of a non-ASCII character IMMEDIATELY after a variable name. TAB and other control
  # characters end a name correctly and do not count; nor does a comment line, since it runs nothing.
  perl -ne 'next if /^\s*#/; if (/\$[A-Za-z_]\w*[\x80-\xFF]/) { print "hit\n"; last }' "$f" 2>/dev/null \
    | grep -q hit && mixed="$mixed $(basename "$f")"
done
if [ -z "$mixed" ]; then
  ok "no variable is left touching a non-ASCII character"
else
  bad "a variable runs into a multibyte character (use \${name}):$mixed"
fi

echo
[ "$fails" = 0 ] && { echo "✅ suite isolation: tests do not reach into each other"; exit 0; }
echo "❌ suite isolation: $fails failure(s)"; exit 1
