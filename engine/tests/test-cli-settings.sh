#!/bin/bash
# The terminal's own settings reach a terminal's run — and never the app's.
#
# `night-shift config` writes ~/.config/night-shift/config.json; a `night-shift start` from a
# terminal reads it, under its flags and under any SUPERVISOR_* variable the caller exported. The
# desktop app keeps its own choices and sends them with every call, so a start it makes must come
# out exactly as it did before this file existed, whatever the file says. Both are proven here on a
# real start, with a stand-in `claude` that writes down the flags it was launched with.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM

# Nothing of the caller's may leak in: not the app's markers, not the bundle id a process started
# from Bulava carries, not a SUPERVISOR_* choice exported in the shell that runs the suite.
for v in $(compgen -e | grep '^SUPERVISOR_'); do unset "$v"; done
unset __CFBundleIdentifier NIGHT_SHIFT_SETTINGS NIGHT_SHIFT_LANG XDG_CONFIG_HOME
export SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export NIGHT_SHIFT_CONFIG="$TMP/config.json"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# The stand-in Claude: records its argv, then waits like an interactive session would.
mkdir -p "$TMP/bin"
mkdir -p "$TMP/args"
# Written outside the project: a file inside it would make the next start see uncommitted work.
cat > "$TMP/bin/claude" <<EOF
#!/bin/bash
printf '%s\\n' "\$*" > "$TMP/args/\$(basename "\$PWD")"
exec cat
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

NS="$BIN_DIR/night-shift.sh"
CLI="$BIN_DIR/ns-cli.py"
. "$BIN_DIR/supervisor-lib.sh"

make_repo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q -b main && git config user.name T && git config user.email t@example.com \
    && echo x > a && git add a && git commit -qm base )
}
idir_of() { instance_dir "$(slug_for "$(canon_path "$1")")"; }
run_var() { sed -n "s/^export $2='\\(.*\\)'$/\\1/p" "$(idir_of "$1")/run-env" 2>/dev/null; }
args_file() { printf '%s/args/%s' "$TMP" "$(basename "$1")"; }
args_of() { cat "$(args_file "$1")" 2>/dev/null; }
wait_args() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$(args_file "$1")" ] && return 0; sleep 0.3; done; return 1; }
stop() { bash "$NS" stop "$1" --yes >/dev/null 2>&1 || true; rm -f "$(args_file "$1")"; }

echo "===== no settings file: a start is what it always was ====="
P="$TMP/plain"; make_repo "$P"
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "started" || bad "exit $rc: $out"
wait_args "$P"
[ "$(run_var "$P" SUPERVISOR_CLAUDE_EFFORT)" = high ] && ok "Claude depth is the engine default" || bad "depth: $(run_var "$P" SUPERVISOR_CLAUDE_EFFORT)"
case "$(args_of "$P")" in *--model*) bad "a model appeared from nowhere: $(args_of "$P")" ;; *) ok "no --model is sent" ;; esac
[ "$(cat "$(idir_of "$P")/origin" 2>/dev/null)" = cli ] && ok "the run is marked as the terminal's" || bad "origin: $(cat "$(idir_of "$P")/origin" 2>/dev/null)"
[ ! -e "$NIGHT_SHIFT_CONFIG" ] && ok "and no settings file was created by starting" || bad "start wrote a settings file"
stop "$P"

echo "===== the settings file reaches the worker and the run ====="
python3 "$CLI" config set claude.model opus >/dev/null
python3 "$CLI" config set codex.effort xhigh >/dev/null
python3 "$CLI" config set language en >/dev/null
P="$TMP/configured"; make_repo "$P"
python3 "$CLI" config set claude.effort max --project "$P" >/dev/null
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "started" || bad "exit $rc: $out"
wait_args "$P"
case "$(args_of "$P")" in *"--effort max --model opus"*) ok "the worker got the project's depth and the global model" ;; *) bad "worker argv: $(args_of "$P")" ;; esac
[ "$(run_var "$P" SUPERVISOR_CODEX_EFFORT)" = xhigh ] && ok "Codex depth is in the run's file" || bad "codex effort: $(run_var "$P" SUPERVISOR_CODEX_EFFORT)"
[ "$(run_var "$P" SUPERVISOR_REPORT_LANGUAGE)" = English ] && ok "so is the language" || bad "language: $(run_var "$P" SUPERVISOR_REPORT_LANGUAGE)"
grep -q -- "--model 'opus'" "$(idir_of "$P")/relaunch-template" && ok "a worker restarted in place keeps the model" || bad "relaunch template lost the model"

echo "===== status shows who started what, with which models ====="
st="$(bash "$NS" status 2>&1)"
case "$st" in *"запустив=термінал"*"Claude opus·max"*"xhigh"*) ok "status names origin and models" ;; *) bad "status: $st" ;; esac
js="$(bash "$NS" status --json)"
if printf '%s' "$js" | python3 -c 'import json,sys; d=json.load(sys.stdin); i=[x for x in d["instances"] if x["project"].endswith("/configured")][0]; assert i["origin"]=="cli" and i["claude"]["model"]=="opus" and i["codex"]["effort"]=="xhigh"'; then
  ok "status --json is machine-readable and complete"
else bad "status --json: $js"; fi

echo "===== a running run's Codex choices change on the spot ====="
out="$(cd "$P" && bash "$NS" config set codex.effort max --run 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(run_var "$P" SUPERVISOR_CODEX_EFFORT)" = max ] && ok "codex.effort --run rewrote the run's file" || bad "rc=$rc $out / $(run_var "$P" SUPERVISOR_CODEX_EFFORT)"
[ "$(run_var "$P" SUPERVISOR_CLAUDE_MODEL)" = opus ] && ok "and left every other choice alone" || bad "run-env lost the model"
( . "$BIN_DIR/supervisor-lib.sh"; run_env_load "$(idir_of "$P")"; [ "$SUPERVISOR_CODEX_EFFORT" = max ] ) \
  && ok "the engine's own loader reads the change back" || bad "run_env_load does not see it"
out="$(bash "$NS" config set claude.model sonnet --run "$P" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "the worker's own model is refused mid-run, with a reason" || bad "claude.model --run was accepted: $out"
stop "$P"

echo "===== precedence: flag > caller's variable > project > global ====="
P="$TMP/precedence"; make_repo "$P"
python3 "$CLI" config set codex.effort medium --project "$P" >/dev/null
SUPERVISOR_CODEX_EFFORT=low bash "$NS" start "$P" --no-attach >/dev/null 2>&1
[ "$(run_var "$P" SUPERVISOR_CODEX_EFFORT)" = low ] && ok "an exported variable beats the file" || bad "got $(run_var "$P" SUPERVISOR_CODEX_EFFORT)"
stop "$P"
SUPERVISOR_CODEX_EFFORT=low bash "$NS" start "$P" --no-attach --codex-effort max --model=sonnet >/dev/null 2>&1
wait_args "$P"
[ "$(run_var "$P" SUPERVISOR_CODEX_EFFORT)" = max ] && ok "a flag beats the variable" || bad "got $(run_var "$P" SUPERVISOR_CODEX_EFFORT)"
case "$(args_of "$P")" in *"--model sonnet"*) ok "--model=value form works" ;; *) bad "argv: $(args_of "$P")" ;; esac
stop "$P"; rm -f "$(args_file "$P")"
bash "$NS" start "$P" --no-attach --effort auto >/dev/null 2>&1
wait_args "$P"
case "$(args_of "$P")" in *"--effort high"*) ok "--effort auto puts the engine default back over the file" ;; *) bad "argv: $(args_of "$P")" ;; esac
stop "$P"

echo "===== a bad value stops before anything is touched ====="
P="$TMP/bad"; make_repo "$P"
out="$(bash "$NS" start "$P" --no-attach --effort extreme 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "exit 2 for an unknown depth" || bad "exit $rc: $out"
[ ! -d "$(idir_of "$P")" ] && ok "no run was created" || bad "an instance was left behind"
out="$(bash "$NS" start "$P" --no-attach --model 'x; rm -rf /' 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "a model name that is not a name is refused" || bad "exit $rc: $out"
out="$(bash "$NS" start "$P" --no-attach --frobnicate 2>&1)"; rc=$?
[ "$rc" = 2 ] && ok "an unknown flag is an error, not a folder name" || bad "exit $rc: $out"

echo "===== the app's starts never read the file ====="
P="$TMP/app"; make_repo "$P"
SUPERVISOR_APP_ANSWERS="dirty mcp git heavy" bash "$NS" start "$P" --no-attach >/dev/null 2>&1
wait_args "$P"
case "$(args_of "$P")" in *--model*) bad "the app's start picked up the terminal's model: $(args_of "$P")" ;; *) ok "no --model from the terminal's file" ;; esac
[ "$(run_var "$P" SUPERVISOR_CODEX_EFFORT)" = high ] && ok "Codex stays at the engine default" || bad "got $(run_var "$P" SUPERVISOR_CODEX_EFFORT)"
[ "$(cat "$(idir_of "$P")/origin")" = app ] && ok "and the run is marked as the app's" || bad "origin: $(cat "$(idir_of "$P")/origin")"
stop "$P"; rm -f "$(args_file "$P")"
__CFBundleIdentifier=stepanok.com.Night-Shift bash "$NS" start "$P" --no-attach >/dev/null 2>&1
wait_args "$P"
case "$(args_of "$P")" in *--model*) bad "a process spawned by the app read the file" ;; *) ok "a process carrying the app's bundle id does not read it either" ;; esac
stop "$P"
SUPERVISOR_APP_ANSWERS="dirty" SUPERVISOR_CLAUDE_EFFORT=low SUPERVISOR_CODEX_MODEL=gpt-x \
  bash "$NS" start "$P" --no-attach >/dev/null 2>&1
[ "$(run_var "$P" SUPERVISOR_CLAUDE_EFFORT)" = low ] && [ "$(run_var "$P" SUPERVISOR_CODEX_MODEL)" = gpt-x ] \
  && ok "the app's own choices arrive exactly as sent" || bad "app env lost: $(cat "$(idir_of "$P")/run-env")"
stop "$P"

echo "===== one start per project, whoever asks ====="
P="$TMP/locked"; make_repo "$P"
L="$SUPERVISOR_STATE_DIR/locks/start-$(slug_for "$(canon_path "$P")")"
mkdir -p "$L"; echo $$ > "$L/pid"
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a start already in progress refuses the second" || bad "exit $rc: $out"
[ ! -d "$(idir_of "$P")" ] && ok "without touching anything" || bad "an instance appeared"
[ -d "$L" ] && ok "and the holder keeps its lock" || bad "the lock was taken away"
echo 999999 > "$L/pid"
bash "$NS" start "$P" --no-attach >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "a lock whose holder died is taken over" || bad "exit $rc"
[ ! -d "$L" ] && ok "and released when the start ends" || bad "lock left behind"
stop "$P"

echo "===== stop without a terminal never waits for an answer ====="
P="$TMP/stopme"; make_repo "$P"
SUPERVISOR_APP_ANSWERS="dirty" bash "$NS" start "$P" --no-attach >/dev/null 2>&1
bash "$NS" stop "$P" </dev/null >/dev/null 2>&1
[ ! -d "$(idir_of "$P")" ] && ok "the app's run stops when nobody is at a terminal (app, queue)" || bad "stop was blocked"

echo "===== help, models and completion ====="
for c in "help" "help start" "help config" "start --help" "config --help" "--help" "stop --help"; do
  bash "$NS" $c >/dev/null 2>&1 && ok "night-shift $c" || bad "night-shift $c failed"
done
bash "$NS" no-such-command >/dev/null 2>&1; [ $? = 1 ] && ok "an unknown command exits 1" || bad "unknown command exit"
bash "$NS" models >/dev/null 2>&1 && ok "models works with no catalogue" || bad "models failed"
bash "$NS" models --json | python3 -c 'import json,sys; json.load(sys.stdin)' && ok "models --json is JSON" || bad "models --json"
bash "$NS" completion bash > "$TMP/c.bash" && bash -n "$TMP/c.bash" && ok "bash completion parses" || bad "bash completion"
if command -v zsh >/dev/null 2>&1; then
  bash "$NS" completion zsh > "$TMP/c.zsh" && zsh -n "$TMP/c.zsh" && ok "zsh completion parses" || bad "zsh completion"
fi
bash "$NS" completion fish | grep -q 'complete -c night-shift' && ok "fish completion" || bad "fish completion"
bash "$NS" completion powershell | grep -q 'Register-ArgumentCompleter' && ok "PowerShell completion" || bad "powershell completion"
( . "$TMP/c.bash"; COMP_WORDS=(night-shift config set cl); COMP_CWORD=3; _night_shift; printf '%s\n' "${COMPREPLY[@]}" ) \
  | grep -qx 'claude.effort' && ok "bash completion offers setting keys" || bad "completion does not offer keys"

echo "===== the settings file is guarded ====="
python3 "$CLI" config set review.max-rounds 0 >/dev/null 2>&1; [ $? = 2 ] && ok "an out-of-range number is refused" || bad "accepted 0 rounds"
python3 "$CLI" config set nonsense 1 >/dev/null 2>&1; [ $? = 2 ] && ok "an unknown key is refused" || bad "accepted unknown key"
[ "$(stat -c %a "$NIGHT_SHIFT_CONFIG" 2>/dev/null || stat -f %Lp "$NIGHT_SHIFT_CONFIG")" = 600 ] && ok "the file is private (600)" || bad "mode"
# Twenty writers at once: every one of them lands, and the file is never half-written.
for i in $(seq 1 20); do python3 "$CLI" config set review.max-rounds-hard "$((i + 10))" --project "$TMP/p$i" >/dev/null 2>&1 & done; wait
n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["projects"]))' "$NIGHT_SHIFT_CONFIG" 2>/dev/null)"
[ "${n:-0}" -ge 22 ] && ok "20 concurrent writers, none lost ($n projects)" || bad "concurrent writes lost: $n"
python3 "$CLI" config check >/dev/null && ok "config check passes" || bad "config check"
echo '{"defaults":{"claude.effort":"loud"}}' > "$TMP/broken.json"
NIGHT_SHIFT_CONFIG="$TMP/broken.json" python3 "$CLI" config check >/dev/null 2>&1; [ $? = 1 ] && ok "a hand-edited bad value is caught by check" || bad "check missed it"

echo "===== import from the app (macOS) ====="
if [ "$(uname -s)" = Darwin ]; then
  # A stand-in `defaults` that answers with the shape the app writes: a JSON blob under one key.
  blob='{"claudeModel":"fable","claudeEffort":"xhigh","codexEffort":"auto","codexModel":"gpt-6.1-sol","reportLanguage":"ru","reportWriter":"claude","stateDirPath":"'"$SUPERVISOR_STATE_DIR"'"}'
  python3 - "$blob" > "$TMP/app.plist" <<'PY'
import plistlib, sys
sys.stdout.buffer.write(plistlib.dumps({"com.nightshift.settings.v1": sys.argv[1].encode()}))
PY
  mkdir -p "$TMP/fake"; printf '#!/bin/bash\ncat %q\n' "$TMP/app.plist" > "$TMP/fake/defaults"; chmod +x "$TMP/fake/defaults"
  export NIGHT_SHIFT_CONFIG="$TMP/import.json"
  python3 "$CLI" config set claude.model opus >/dev/null
  out="$(PATH="$TMP/fake:$PATH" python3 "$CLI" config import-app 2>&1)"
  [ "$(python3 "$CLI" config get claude.model)" = opus ] && ok "an existing terminal choice is kept" || bad "import overwrote claude.model"
  case "$out" in *"--force"*) ok "and it says how to replace it" ;; *) bad "no hint: $out" ;; esac
  [ "$(python3 "$CLI" config get claude.effort)" = xhigh ] && [ "$(python3 "$CLI" config get language)" = Russian ] \
    && [ "$(python3 "$CLI" config get report.writer)" = claude ] && ok "the rest is carried over" || bad "import: $out"
  [ "$(python3 "$CLI" config get codex.effort)" = auto ] && ok "'Automatic' in the app is not written down" || bad "auto was imported"
  PATH="$TMP/fake:$PATH" python3 "$CLI" config import-app --force >/dev/null 2>&1
  [ "$(python3 "$CLI" config get claude.model)" = fable ] && ok "--force replaces it" || bad "--force did nothing"
else
  ok "(not macOS — import-app refuses by design)"
fi


echo "== the app's own preferences file wins over a stale \`defaults\` (22.10)"
if [ "$(uname)" = Darwin ]; then
  mkdir -p "$HOME/Library/Preferences"
  python3 - '{"claudeModel":"opus","claudeEffort":"medium","codexModel":"gpt-6-astra","codexEffort":"medium"}' \
    > "$HOME/Library/Preferences/stepanok.com.Night-Shift.plist" <<'PY'
import plistlib, sys
sys.stdout.buffer.write(plistlib.dumps({"com.nightshift.settings.v1": sys.argv[1].encode()}))
PY
  export NIGHT_SHIFT_CONFIG="$TMP/import-file.json"
  out="$(PATH="$TMP/fake:$PATH" python3 "$CLI" config import-app --dry-run 2>&1)"
  case "$out" in *"codex.model = gpt-6-astra"*"claude.model = opus"*|*"claude.model = opus"*"codex.model = gpt-6-astra"*)
    ok "models and depth come from the file, not from the old copy defaults answered with" ;;
    *) bad "import-app read the stale copy: $out" ;; esac
  rm -f "$HOME/Library/Preferences/stepanok.com.Night-Shift.plist"
fi

echo "== a depth is checked against what the model offers on this account (22.10)"
export CODEX_HOME="$TMP/codex-home"; mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/models_cache.json" <<'JSON'
{"models":[{"slug":"gpt-big","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"ultra"}]},
           {"slug":"gpt-small","visibility":"list","priority":2,"supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}
JSON
export NIGHT_SHIFT_CONFIG="$TMP/levels.json"
python3 "$CLI" config set codex.model gpt-small >/dev/null 2>&1
python3 "$CLI" config set codex.effort ultra >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "ultra is refused for a model this account does not get it for" || bad "ultra accepted for gpt-small (rc=$rc)"
python3 "$CLI" config set codex.model gpt-big >/dev/null 2>&1
python3 "$CLI" config set codex.effort ultra >/dev/null 2>&1 && ok "and taken where the account's catalogue offers it" || bad "ultra refused for gpt-big"
python3 "$CLI" config set codex.model gpt-small >/dev/null 2>&1
out="$(python3 "$CLI" env 2>&1)"
case "$out" in *"SUPERVISOR_CODEX_EFFORT	high"*) ok "a saved level the model no longer takes is lowered at start, out loud" ;;
  *) bad "start passed an unsupported level: $out" ;; esac
unset CODEX_HOME

printf '\n%s\n' "failures: $fails"
[ "$fails" -eq 0 ]
