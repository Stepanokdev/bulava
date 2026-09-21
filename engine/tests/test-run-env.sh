#!/bin/bash
# What the app chooses must reach the run — all of it.
#
# A tmux session inherits the tmux SERVER's environment, not the environment of whoever asked for the
# session. A server started hours ago carries none of the run's configuration, so anything not written
# into the launch command line is simply absent. Only the Codex pair used to be written; the worker's
# Claude effort and model arrived as flags (enough for the worker itself) and every script the worker
# then spawned — report.sh, verify.sh, the skill resolver — read the variables and found
# config defaults instead of the director's choice. The report language was the plainest case: set the
# app to English and the receipt still came out Ukrainian.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

echo "===== every choice is stamped into the launch line ====="

stamp="$(SUPERVISOR_CODEX_EFFORT=low SUPERVISOR_CODEX_MODEL=gpt-5-codex \
         SUPERVISOR_CLAUDE_EFFORT=xhigh SUPERVISOR_CLAUDE_MODEL=claude-opus-5 \
         SUPERVISOR_REPORT_LANGUAGE=English SUPERVISOR_REPORT_WRITER=codex \
         SUPERVISOR_COLLABORATION_MODE=adaptive_peer SUPERVISOR_CONSULT_TIMEOUT=777 run_env_stamp)"

for pair in "SUPERVISOR_CODEX_EFFORT='low'" "SUPERVISOR_CODEX_MODEL='gpt-5-codex'" \
            "SUPERVISOR_CLAUDE_EFFORT='xhigh'" "SUPERVISOR_CLAUDE_MODEL='claude-opus-5'" \
            "SUPERVISOR_REPORT_LANGUAGE='English'" "SUPERVISOR_REPORT_WRITER='codex'" \
            "SUPERVISOR_COLLABORATION_MODE='adaptive_peer'" "SUPERVISOR_CONSULT_TIMEOUT='777'"; do
  case "$stamp" in
    *"$pair"*) ok "carries ${pair%%=*}" ;;
    *) bad "MISSING ${pair%%=*} (stamp: $stamp)" ;;
  esac
done

echo "===== an unmade choice is stamped as the engine's resolved default ====="

# Never omitted: a missing variable would let whatever the long-lived tmux server happens to carry
# win instead. Sourcing the library resolves config.sh's defaults, so the stamp states them
# explicitly and the child never has to re-derive anything.
bare="$(env -u SUPERVISOR_CODEX_EFFORT -u SUPERVISOR_CLAUDE_EFFORT -u SUPERVISOR_REPORT_LANGUAGE \
        -u SUPERVISOR_CODEX_MODEL -u SUPERVISOR_CLAUDE_MODEL -u SUPERVISOR_REPORT_WRITER \
        -u SUPERVISOR_COLLABORATION_MODE -u SUPERVISOR_CONSULT_TIMEOUT \
        bash -c '. "'"$BIN_DIR"'/supervisor-lib.sh"; run_env_stamp')"
for v in SUPERVISOR_CODEX_EFFORT SUPERVISOR_CODEX_MODEL SUPERVISOR_CLAUDE_EFFORT \
         SUPERVISOR_CLAUDE_MODEL SUPERVISOR_REPORT_LANGUAGE SUPERVISOR_REPORT_WRITER; do
  case "$bare" in
    *"$v="*) : ;;
    *) bad "$v is missing entirely from the stamp"; continue ;;
  esac
done
for v in SUPERVISOR_COLLABORATION_MODE SUPERVISOR_CONSULT_TIMEOUT; do
  case "$bare" in *"$v="*) : ;; *) bad "$v is missing entirely from the stamp" ;; esac
done
case "$bare" in
  *"SUPERVISOR_CLAUDE_EFFORT='high'"*) ok "the resolved default is stated, not left to the child" ;;
  *) bad "the default did not make it into the stamp: $bare" ;;
esac
case "$bare" in
  *"SUPERVISOR_REPORT_LANGUAGE='Ukrainian'"*) ok "and so is the language" ;;
  *) bad "the language default is missing: $bare" ;;
esac

echo "===== a value with spaces or quotes cannot break the command line ====="

nasty="$(SUPERVISOR_REPORT_LANGUAGE="Ukrainian; rm -rf /" run_env_stamp)"
case "$nasty" in
  *"'Ukrainian; rm -rf /'"*) ok "quoted, so a shell metacharacter is inert" ;;
  *) bad "not quoted: $nasty" ;;
esac

echo "===== both launch paths use it ====="

[ "$(grep -c 'run_env_stamp' "$BIN_DIR/night-shift.sh")" = "2" ] \
  && ok "start and resume both stamp the run" \
  || bad "only $(grep -c 'run_env_stamp' "$BIN_DIR/night-shift.sh") launch path(s) stamp it"
grep -q "SUPERVISOR_CODEX_EFFORT=.*SUPERVISOR_CODEX_MODEL=.*RAW_LAUNCH" "$BIN_DIR/night-shift.sh" \
  && bad "the old two-variable stamp is still there" \
  || ok "the old Codex-only stamp is gone"

echo "===== the worker's own flags still carry its effort and model ====="

# Built by the helper now, because a model with no reasoning levels has to reach the CLI with no
# --effort at all and an empty variable cannot say that — config.sh fills an empty one with `high`.
# See test-claude-effort.sh for what the helper produces.
grep -q 'EFFORT_FLAG="$(claude_effort_launch_flag)"' "$BIN_DIR/night-shift.sh" \
  && ok "--effort is built by the one helper that knows when to omit it" \
  || bad "the worker lost its --effort flag"
grep -q 'claude ${EFFORT_FLAG}' "$BIN_DIR/night-shift.sh" \
  && ok "and the launch line still carries it" || bad "EFFORT_FLAG never reaches the launch line"
grep -q 'MODEL_FLAG="--model' "$BIN_DIR/night-shift.sh" \
  && ok "--model too" || bad "the worker lost its --model flag"

echo "===== a run against another state directory keeps it ====="
#
# The worker's hooks resolve their own instance through SUPERVISOR_STATE_DIR. Left out of the
# launch line, a run started against a different state directory lost it at the door: the review
# gate looked under ~/.claude/supervisor, found no instance, and quietly did not run.
elsewhere="$(SUPERVISOR_STATE_DIR="$TMP/other-state" run_env_stamp)"
case "$elsewhere" in
  "SUPERVISOR_STATE_DIR='$TMP/other-state' "*) ok "a non-default state directory is stamped first" ;;
  *) bad "the state directory is missing from the launch line: $elsewhere" ;;
esac
default="$(SUPERVISOR_STATE_DIR="$HOME/.claude/supervisor" run_env_stamp)"
case "$default" in
  *SUPERVISOR_STATE_DIR*) bad "the default state directory is stamped needlessly" ;;
  *) ok "and the default one is not restated" ;;
esac

echo "===== and the same choices are written where a later process can read them ====="
#
# The stamp reaches only what tmux launches. A preflight, a peer brief or a consultation started by
# the APP is a child of Bulava's own shell and carries none of it, so those calls ran at
# config.sh's defaults while the composer named something else.
D="$TMP/inst"; mkdir -p "$D"
SUPERVISOR_CODEX_EFFORT=low SUPERVISOR_CODEX_MODEL=gpt-5-codex \
  SUPERVISOR_CLAUDE_EFFORT=xhigh SUPERVISOR_CLAUDE_MODEL=opus \
  SUPERVISOR_REPORT_LANGUAGE="Ukrainian" SUPERVISOR_COLLABORATION_MODE=adaptive_peer \
  run_env_save "$D"
[ -s "$D/run-env" ] && ok "the run's choices are on disk" || bad "run-env was not written"
read_back() {   # $1=variable → what a child would see
  ( for v in $(compgen -v | grep '^SUPERVISOR_'); do case "$v" in SUPERVISOR_STATE_DIR) ;; *) unset "$v" ;; esac; done
    . "$BIN_DIR/supervisor-lib.sh"
    run_env_load "$D" 2>/dev/null
    printf '%s' "${!1}" )
}
[ "$(read_back SUPERVISOR_CODEX_EFFORT)" = low ] && ok "a child reads the chosen Codex depth" \
  || bad "the child saw '$(read_back SUPERVISOR_CODEX_EFFORT)' instead of low"
[ "$(read_back SUPERVISOR_CLAUDE_MODEL)" = opus ] && ok "and the chosen Claude model" \
  || bad "the child saw '$(read_back SUPERVISOR_CLAUDE_MODEL)'"

echo "===== a value is data, and the file is parsed rather than sourced ====="
#
# The instance directory is writable by the worker itself. A line that closes its own quote and
# opens a statement would run the moment a shell sourced or eval'd it.
SUPERVISOR_REPORT_WRITER="it's codex" run_env_save "$D"
( unset SUPERVISOR_REPORT_WRITER; run_env_load "$D"
  [ "$SUPERVISOR_REPORT_WRITER" = "it's codex" ] ) \
  && ok "an apostrophe survives the round trip" \
  || bad "the value came back mangled: $( unset SUPERVISOR_REPORT_WRITER; run_env_load "$D"; printf '%s' "$SUPERVISOR_REPORT_WRITER" )"

printf "export SUPERVISOR_CLAUDE_MODEL='';touch %s/PWNED;x='\n" "$D" > "$D/run-env"
( SUPERVISOR_CLAUDE_MODEL=opus; run_env_load "$D" >/dev/null 2>&1; : )
[ -e "$D/PWNED" ] && bad "a crafted run-env line executed a command" || ok "a crafted line executes nothing"
( SUPERVISOR_CLAUDE_MODEL=opus; run_env_load "$D" >/dev/null 2>&1
  [ "$SUPERVISOR_CLAUDE_MODEL" = opus ] ) \
  && ok "and is refused rather than half-applied" || bad "the crafted value was accepted"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
