#!/bin/bash
# A test tmux that physically cannot reach the server you are working in.
#
# This cost three severed sessions in one day. The test set a trap
#
#     TMP="$(mktemp -d)"
#     cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$TMP"; }
#     trap cleanup EXIT
#     export TMUX_TMPDIR="$TMP/tmux"      # ← one line BELOW
#
# and between those two lines any exit — a failing `mktemp`, `set -e`, Ctrl-C — ran
# `tmux kill-server` with NO isolation at all: on the default socket, meaning the director's own
# session and every night shift alive at that moment. The isolation existed, but it came on one
# line later than the danger.
#
# There is one socket here — the one `TMUX_TMPDIR` points at. There cannot be another: the engine
# starts tmux itself and never sees a `-L` flag, so any «label of our own» for test commands
# would split the test's sessions and the engine's across two servers. Instead of a second socket
# there is a **condition on the kill**: `kill-server` runs only if `TMUX_TMPDIR` leads into a
# directory this very test created. Before isolation that condition is false and the command

TEST_TMUX_DIR=""

# The run a test started and never stopped, ended along with its server.
#
# A watchdog leaves only when its instance directory goes, and a test that forgets `night-shift
# stop` — or whose `rm -rf "$TMP"` never runs — leaves it polling a dead tmux every 45 seconds,
# forever. Seven of them were found alive eighteen hours after a suite run, and because their
# command line read `…/engine/bin/watchdog.sh`, Bulava refused to install its engine for them.
#
# Only a state directory this test made is touched: it has to sit in a temporary directory, and the
# pid has to be a watchdog of an instance inside it. The director's own runs live elsewhere.
test_stop_watchdogs() {
  local state="${SUPERVISOR_STATE_DIR:-}" real tmp pidfile pid slug cmd
  [ -n "$state" ] && [ -d "$state/instances" ] || return 0
  real="$(cd "$state" 2>/dev/null && pwd -P)" || return 0
  tmp="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)"
  case "$real/" in
    "$tmp"/*|/private/tmp/*|/tmp/*|/private/var/folders/*) ;;
    *) return 0 ;;
  esac
  for pidfile in "$real"/instances/*/watchdog.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(tr -dc '0-9' < "$pidfile" 2>/dev/null)"; [ -n "$pid" ] || continue
    slug="$(basename "$(dirname "$pidfile")")"
    cmd="$(ps -p "$pid" -o command= 2>/dev/null)" || continue
    case "$cmd" in *watchdog.sh*"$slug"*|*watchdog*"$slug"*) kill "$pid" 2>/dev/null || true ;; esac
  done
}

# Remove the server — and only if it is definitely ours.
#
# What is checked is not the intent but the fact: does TMUX_TMPDIR point at the directory we
# isolated. Called before `tmux_isolate`, with an empty or substituted TMUX_TMPDIR, it silently
# does nothing — which is exactly how the trap stops being a trap.
tmux_cleanup() {
  test_stop_watchdogs
  [ -n "${TEST_TMUX_DIR:-}" ] || return 0
  [ "${TMUX_TMPDIR:-}" = "$TEST_TMUX_DIR" ] || return 0
  # …and no inherited `$TMUX`. It outranks TMUX_TMPDIR: the client goes to the server written in
  # it, so matching directories guarantee nothing while the variable is alive. `tmux_isolate`
  # removes it, and here that is checked again — because that path is how sessions died.
  [ -z "${TMUX:-}" ] || return 0
  tmux kill-server 2>/dev/null || true
}

# $1 — the directory for the socket (normally an mktemp of our own).
tmux_isolate() {
  TEST_TMUX_DIR="${1:-$(mktemp -d)}"
  mkdir -p "$TEST_TMUX_DIR" 2>/dev/null || true
  # First leave the other session and name our own directory, and only then set the trap.
  unset TMUX
  export TMUX_TMPDIR="$TEST_TMUX_DIR"
  export TEST_TMUX_DIR
  # A test that set its own EXIT trap first — `cleanup() { tmux_cleanup; rm -rf "$TMP"; }` — keeps
  # it. This used to REPLACE it, so the fixture was never deleted, the instance directory outlived
  # the test, and so did the watchdog that waits for that directory to go.
  local previous=""
  eval "set -- $(trap -p EXIT)"
  [ "${1:-}" = trap ] && previous="${3:-}"
  case "$previous" in
    ""|tmux_cleanup) trap 'tmux_cleanup' EXIT ;;
    "tmux_cleanup; "*) ;;   # isolated twice: already chained
    *) trap "tmux_cleanup; $previous" EXIT ;;
  esac
  trap 'tmux_cleanup' INT TERM
}

# Whether we are isolated right now — something a test can check instead of guessing.
tmux_is_isolated() {
  [ -n "${TEST_TMUX_DIR:-}" ] && [ "${TMUX_TMPDIR:-}" = "$TEST_TMUX_DIR" ]
}
