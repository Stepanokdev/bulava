#!/bin/bash
# Claude Code 2.1.327 asks about every --add-dir folder it has not trusted, and the engine's own
# runs folder is trusted before it can ask.
#
# Every start passes `--add-dir <instance dir>`, a folder made anew for each run. From 2.1.327 the
# start stopped on "Adding a new directory … This session hasn't worked here before › No, exit /
# Yes, add it": no hook runs there, so the handshake gave up after its wait and the blocker said
# only "screen". Trusting the parent folder (hasTrustDialogAccepted in ~/.claude.json) keeps the
# question away for every run under it.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

export SUPERVISOR_STATE_DIR="$TMP/state" CLAUDE_CONFIG_DIR="$TMP/claude-config"
mkdir -p "$SUPERVISOR_STATE_DIR" "$CLAUDE_CONFIG_DIR"
unset SUPERVISOR_CLAUDE_CMD
. "$BIN/supervisor-lib.sh"
printf '{"projects":{"/somewhere/else":{"hasTrustDialogAccepted":true,"allowedTools":["Read"]}},"numStartups":7}\n' \
  > "$CLAUDE_CONFIG_DIR/.claude.json"

echo "===== the runs folder is trusted before a start ====="
RUNS="$(canon_path "$SUP_INSTANCES" 2>/dev/null || echo "$SUP_INSTANCES")"
claude_folder_trusted "$RUNS" && bad "the runs folder was trusted before anything happened" || ok "not trusted to begin with"
trust_engine_runs_folder
RUNS="$(canon_path "$SUP_INSTANCES")"
claude_folder_trusted "$RUNS" && ok "after it, Claude Code's record trusts $RUNS" || bad "the runs folder is still untrusted: $(cat "$CLAUDE_CONFIG_DIR/.claude.json")"
python3 - "$CLAUDE_CONFIG_DIR/.claude.json" <<'PY' && ok "everything else in ~/.claude.json is kept" || bad "the rest of ~/.claude.json was lost"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["numStartups"] == 7
assert d["projects"]["/somewhere/else"] == {"hasTrustDialogAccepted": True, "allowedTools": ["Read"]}
PY
[ "$(stat -f %Lp "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null || stat -c %a "$CLAUDE_CONFIG_DIR/.claude.json")" = 600 ] \
  && ok "and the file stays private (600)" || bad "mode of ~/.claude.json changed"
before="$(cat "$CLAUDE_CONFIG_DIR/.claude.json")"
trust_engine_runs_folder
[ "$(cat "$CLAUDE_CONFIG_DIR/.claude.json")" = "$before" ] && ok "a second start writes nothing" || bad "a second start rewrote the file"

SUPERVISOR_CLAUDE_CMD="cat" trust_engine_runs_folder
ok "a stubbed worker (SUPERVISOR_CLAUDE_CMD) leaves Claude Code's record alone"

echo "===== every launch trusts it first ====="
n_launch="$(grep -c -- '--add-dir $(shq "$IDIR")' "$BIN/night-shift.sh")"
n_trust="$(awk '/trust_engine_runs_folder/{t=NR} /--add-dir \$\(shq "\$IDIR"\)/{ if (t && NR - t < 8) c++ } END{print c+0}' "$BIN/night-shift.sh")"
[ "$n_launch" -gt 0 ] && [ "$n_trust" = "$n_launch" ] \
  && ok "all $n_launch launch lines with --add-dir <instance dir> trust the runs folder just before" \
  || bad "$n_trust of $n_launch launch lines trust the runs folder first"

echo "===== the question is named when it does appear ====="
PANE='
 Adding a new directory: /srv/work/client-repo
 This session hasn'"'"'t worked here before. Claude will be able to read and edit files here.

 ❯ No, exit
   Yes, add it

 Enter to confirm · Esc to cancel'
handshake_screen_adddir "$PANE" && ok "the screen is recognised as the --add-dir question" || bad "the --add-dir question is not recognised"
[ -z "$(handshake_screen "$PANE")" ] && handshake_screen_asks "$PANE" \
  && ok "and, like any question, it is shown to a person while the start waits, not cut short" \
  || bad "the --add-dir question ends the wait instead of being shown: «$(handshake_screen "$PANE")»"
grep -q '\[ "$cause" = screen \] && handshake_screen_adddir "$pane" && cause=adddir' "$BIN/supervisor-lib.sh" \
  && ok "when nobody answered, the start names it adddir instead of «screen»" || bad "await_handshake does not name the question"
says="$(handshake_blocker_says adddir "$PANE" "")"
case "$says" in
  *"/srv/work/client-repo"*"--add-dir"*"night-shift trust"*) ok "and the start's message names the folder and what to do" ;;
  *) bad "message: $says" ;;
esac
[ "$(handshake_screen 'Do you trust the files in this folder? Is this a project you created')" = trust ] \
  && ok "the older trust screen is still read as trust" || bad "the trust screen lost its name"

echo
[ "$fails" -eq 0 ] && echo "✅ add-dir trust: all checks pass" || echo "❌ add-dir trust: $fails failed"
[ "$fails" -eq 0 ]
