#!/bin/bash
# A model with no depth must reach the CLI with no --effort at all.
#
# Haiku 4.5 has no reasoning levels. The app stopped sending one, and the run still got `--effort
# high`: an ABSENT value is filled in by `supervisor/config.sh` (`: "${SUPERVISOR_CLAUDE_EFFORT:=high}"`),
# so "leave it out" and "nobody said anything" were the same thing by the time the launch line was
# built — while the settings row promised no effort would be sent. `none` is the word that carries
# the intent across, and this is what proves it survives the config default and every caller.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ENGINE_DIR="$(cd "$BIN_DIR/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"

echo "===== the depth that is not sent ====="

# Each case is a fresh shell that sources config.sh the way a real run does, so the `:=high`
# default is in play rather than assumed away.
flag_for() {
  local value="$1" fn="$2"
  env SUPERVISOR_CLAUDE_EFFORT="$value" SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" \
      bash -c ". \"$BIN_DIR/supervisor-lib.sh\"; $fn"
}

for fn in claude_effort_args claude_effort_launch_flag; do
  out="$(flag_for none "$fn")"
  if [ -z "$out" ]; then ok "$fn: none sends nothing"
  else bad "$fn: none produced “${out}”"; fi

  out="$(flag_for xhigh "$fn")"
  case "$out" in
    *--effort*xhigh*) ok "$fn: a real depth is still passed" ;;
    *) bad "$fn: xhigh produced “${out}”" ;;
  esac
done

# Nobody said anything: the config default applies, exactly as it always did.
out="$(env -u SUPERVISOR_CLAUDE_EFFORT SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" \
       bash -c ". \"$BIN_DIR/supervisor-lib.sh\"; claude_effort_args")"
case "$out" in
  *--effort*high*) ok "an unset value still falls back to the config default" ;;
  *) bad "an unset value produced “${out}”" ;;
esac

echo "===== the launch line itself ====="

# The worker command as night-shift.sh builds it. The flag fragment is what varies, so it is built
# here the same way and checked inside the whole line — an empty fragment must leave no --effort
# and no stray spacing that would split the next flag.
launch_line() {
  env SUPERVISOR_CLAUDE_EFFORT="$1" SUPERVISOR_CLAUDE_MODEL="$2" SUPERVISOR_STATE_DIR="$SUPERVISOR_STATE_DIR" \
      bash -c ". \"$BIN_DIR/supervisor-lib.sh\"
               EFFORT_FLAG=\"\$(claude_effort_launch_flag)\"
               MODEL_FLAG=\"\"; [ -n \"\${SUPERVISOR_CLAUDE_MODEL:-}\" ] && MODEL_FLAG=\"--model \$(shq \"\$SUPERVISOR_CLAUDE_MODEL\") \"
               printf 'claude %s%s--permission-mode auto' \"\$EFFORT_FLAG\" \"\$MODEL_FLAG\""
}

line="$(launch_line none haiku)"
case "$line" in
  *--effort*) bad "Haiku was launched with a depth: $line" ;;
  *"--model 'haiku'"*) ok "Haiku launches with a model and no depth: $line" ;;
  *) bad "the model never reached the line: $line" ;;
esac

line="$(launch_line ultracode claude-opus-4-7)"
case "$line" in
  *"--effort 'ultracode' --model 'claude-opus-4-7'"*) ok "a pinned version keeps both flags" ;;
  *) bad "unexpected line: $line" ;;
esac

echo "===== every caller goes through it ====="

# A new caller that reads the variable directly would reintroduce exactly this bug, quietly.
# Only EXPANSIONS matter — `${SUPERVISOR_CLAUDE_EFFORT...}`. A bare mention (the list of names
# `run_env_stamp` writes into the launch line) builds no flag.
stray="$(grep -rn '\${SUPERVISOR_CLAUDE_EFFORT' "$BIN_DIR"/*.sh \
         | grep -v 'local level=' || true)"
if [ -z "$stray" ]; then ok "no script builds the flag on its own"
else bad "built without the helper:"$'\n'"$stray"; fi

printf '\n%s\n' "failures: $fails"
[ "$fails" -eq 0 ]
