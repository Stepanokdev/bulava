#!/bin/bash
# Screenshots are taken by the APP, because the app is the process that is allowed to.
#
# Screen Recording is granted per RESPONSIBLE process. A worker runs under a tmux server — a daemon
# re-parented to launchd — so macOS attributes its capture to tmux, which holds no grant and cannot
# usefully be given one: its path carries a homebrew version, so the grant would die at the next
# upgrade. Routing through Terminal worked and was rejected: `do script` always opens a window and
# Terminal keeps it after the shell exits, so every capture left a dead window behind, and a window
# that flashes open and shut alarms whoever is watching.
#
# So the engine asks and Bulava answers, over a request file. This suite drives that contract with a
# stub service — no real screen, no real permission.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${SVC_PID:-}" ] && kill "$SVC_PID" 2>/dev/null' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
REQ="$SUPERVISOR_STATE_DIR/capture-requests"
mkdir -p "$REQ"

CAP="$BIN_DIR/worker-capture.sh"

echo "===== with no app running, it refuses and creates nothing ====="

rm -f "$REQ/service.json"
if "$CAP" "$TMP/a.png" >/dev/null 2>&1; then
  bad "claimed a capture with no service"
else
  ok "refuses when Bulava is not running"
fi
[ -e "$TMP/a.png" ] && bad "left a placeholder behind" || ok "and leaves no placeholder"

echo "===== a stale service file does not make it wait ====="

# A pid that cannot be alive: liveness is checked, not assumed.
jq -nc '{pid: 999999, since: 1}' > "$REQ/service.json"
start=$(date +%s)
"$CAP" "$TMP/b.png" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 5 ] && ok "a dead service is detected at once (${elapsed}s)" \
                     || bad "waited ${elapsed}s on a service that is not there"

echo "===== a served request produces the file ====="

# The stub stands in for the app: it answers requests the way CaptureService does.
jq -nc --argjson pid "$$" '{pid: $pid, since: 1}' > "$REQ/service.json"
( while true; do
    for f in "$REQ"/*.json; do
      case "$f" in *service.json|*'*'*) continue ;; esac
      id="$(basename "$f" .json)"
      [ -f "$REQ/$id.done" ] && continue
      out="$(jq -r '.out' "$f" 2>/dev/null)"
      region="$(jq -r '.region // ""' "$f" 2>/dev/null)"
      wpid="$(jq -r '.window_pid // ""' "$f" 2>/dev/null)"
      printf 'PNG:%s:%s' "$region" "$wpid" > "$out"
      jq -nc --arg p "$out" '{ok:true, path:$p}' > "$REQ/$id.done"
    done
    sleep 0.2
  done ) & SVC_PID=$!

out="$("$CAP" "$TMP/c.png" 2>&1)"
[ "$out" = "$TMP/c.png" ] && ok "prints the path it produced" || bad "printed '$out'"
[ -s "$TMP/c.png" ] && ok "and the file is there" || bad "no file"

echo "===== a region and a window reach the service intact ====="

"$CAP" "$TMP/d.png" "10,20,300,400" >/dev/null 2>&1
grep -q "PNG:10,20,300,400:" "$TMP/d.png" 2>/dev/null \
  && ok "the region is passed through" || bad "region lost: $(cat "$TMP/d.png" 2>/dev/null)"

"$CAP" "$TMP/e.png" --window 4242 >/dev/null 2>&1
grep -q "PNG::4242" "$TMP/e.png" 2>/dev/null \
  && ok "the window pid is passed through" || bad "pid lost: $(cat "$TMP/e.png" 2>/dev/null)"

echo "===== a refusal is reported, not swallowed ====="

kill "$SVC_PID" 2>/dev/null; wait "$SVC_PID" 2>/dev/null; SVC_PID=""
jq -nc --argjson pid "$$" '{pid: $pid, since: 1}' > "$REQ/service.json"
( while true; do
    for f in "$REQ"/*.json; do
      case "$f" in *service.json|*'*'*) continue ;; esac
      id="$(basename "$f" .json)"
      [ -f "$REQ/$id.done" ] && continue
      jq -nc '{ok:false, error:"Bulava is not allowed to record the screen"}' > "$REQ/$id.done"
    done
    sleep 0.2
  done ) & SVC_PID=$!

err="$("$CAP" "$TMP/f.png" 2>&1 >/dev/null)"
case "$err" in
  *"not allowed to record"*) ok "the service's own reason is shown" ;;
  *) bad "the reason was lost: $err" ;;
esac
[ -e "$TMP/f.png" ] && bad "a refused capture still left a file" || ok "and nothing was written"

echo "===== nothing routes through Terminal any more ====="

# Code, not comments: both files EXPLAIN why the Terminal route is gone, which is worth keeping.
code_only() { grep -v '^[[:space:]]*#' "$1"; }
code_only "$CAP" | grep -q 'do script' && bad "worker-capture still opens a Terminal window" \
                                       || ok "worker-capture does not touch Terminal"
code_only "$BIN_DIR/capture.sh" | grep -q 'do script' && bad "capture.sh still opens a Terminal window" \
                                                      || ok "capture.sh does not either"
code_only "$CAP" | grep -q 'screencapture' && bad "worker-capture still shells screencapture itself" \
                                           || ok "and never calls screencapture directly"
grep -q 'GRANTED_APP' "$BIN_DIR/capture.sh" && bad "the routing constant is still there" \
                                            || ok "the routing is gone entirely"

echo "===== the capture tool is wired into every run ====="

grep -q 'ln -sf "\$BIN_DIR/worker-capture.sh" "\$IDIR/capture"' "$BIN_DIR/night-shift.sh" \
  && ok "linked as \$IDIR/capture" || bad "a run cannot reach it"
[ "$(grep -c 'ln -sf "\$BIN_DIR/worker-capture.sh"' "$BIN_DIR/night-shift.sh")" = "2" ] \
  && ok "on start and on resume" || bad "a resumed worker has no capture tool"
grep -q 'IDIR/capture' "$BIN_DIR/../supervisor/STANDARDS.md" \
  && ok "and the standards point at it" || bad "nothing tells a worker to use it"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
