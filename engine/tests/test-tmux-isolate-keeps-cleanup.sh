#!/bin/bash
# A test's own cleanup survives `tmux_isolate`, and a run it forgot to stop does not outlive it.
#
# `tmux_isolate` used to set its own EXIT trap over whatever the test had set, so a test written as
#
#     cleanup() { tmux_cleanup; rm -rf "$TMP"; }
#     trap cleanup EXIT
#     tmux_isolate "$TMP/tmux"
#
# never deleted its fixture. The instance directory stayed, and the watchdog that waits for that
# directory to disappear kept polling a dead tmux for good: seven were found alive eighteen hours
# after a suite run, and Bulava refused to install its engine because of them.
set -u
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"

OUTER="$(mktemp -d)"
trap 'rm -rf "$OUTER"' EXIT

echo "===== the test's EXIT trap still runs after tmux_isolate ====="
INNER="$OUTER/fixture"; mkdir -p "$INNER"
bash -c '
  . "$1"
  TMP="$2"
  cleanup() { tmux_cleanup; rm -rf "$TMP"; }
  trap cleanup EXIT
  tmux_isolate "$TMP/tmux"
  exit 0
' _ "$LIB" "$INNER"
[ ! -d "$INNER" ] && ok "the fixture was deleted on exit" \
                  || bad "tmux_isolate replaced the test's trap — the fixture is still there"

echo "===== isolating twice does not run the test's cleanup twice over ====="
INNER2="$OUTER/twice"; mkdir -p "$INNER2"
COUNT="$OUTER/count"; : > "$COUNT"
bash -c '
  . "$1"
  TMP="$2"; COUNT="$3"
  cleanup() { echo x >> "$COUNT"; tmux_cleanup; rm -rf "$TMP"; }
  trap cleanup EXIT
  tmux_isolate "$TMP/tmux"
  tmux_isolate "$TMP/tmux2"
  exit 0
' _ "$LIB" "$INNER2" "$COUNT"
[ "$(wc -l < "$COUNT" | tr -d ' ')" = 1 ] && ok "cleanup ran exactly once" \
                                         || bad "cleanup ran $(wc -l < "$COUNT" | tr -d ' ') times"

echo "===== a watchdog the test left running is stopped with its server ====="
STATE="$OUTER/state"; SLUG="project-0000test"
mkdir -p "$STATE/instances/$SLUG" "$OUTER/bin"
cat > "$OUTER/bin/watchdog.sh" <<'EOS'
#!/bin/bash
while :; do sleep 1; done
EOS
chmod +x "$OUTER/bin/watchdog.sh"
nohup "$OUTER/bin/watchdog.sh" "$SLUG" >/dev/null 2>&1 &
WD=$!
disown "$WD" 2>/dev/null || true
echo "$WD" > "$STATE/instances/$SLUG/watchdog.pid"
sleep 0.3
kill -0 "$WD" 2>/dev/null && ok "the stand-in watchdog is running" || bad "the stand-in watchdog did not start"
SUPERVISOR_STATE_DIR="$STATE" bash -c '
  . "$1"
  tmux_isolate "$2/tmux"
  exit 0
' _ "$LIB" "$OUTER"
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$WD" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$WD" 2>/dev/null; then
  bad "the watchdog outlived the test"; kill "$WD" 2>/dev/null
else
  ok "the watchdog went with the test"
fi

echo "===== …and a state directory outside the temporary area is never touched ====="
# Only the decision is exercised: a state directory that is not temporary returns before any pid
# is read. The director's own runs live there.
out="$(SUPERVISOR_STATE_DIR="$HOME" bash -c '. "$1"; test_stop_watchdogs; echo done' _ "$LIB")"
[ "$out" = done ] && ok "a real state directory is left alone" || bad "unexpected: $out"

echo
[ "$fails" = 0 ] && { echo "OK"; exit 0; } || { echo "$fails failed"; exit 1; }
