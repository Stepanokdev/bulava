#!/bin/bash
# With two Codex installs, the newest one answers — not merely the first on PATH.
#
# Seen on the director's Mac: an npm-global Codex under Homebrew's node (0.153) and another under
# nvm's (0.156). Homebrew's directory came first, and the service offers each CLI the models of ITS
# version — GPT-6 Sol and Luna existed for 0.156 and not for 0.153. So the model menu could not show
# them, and a run told to use one would have been refused.
#
# Stand-ins shaped like the real installs (a `codex` symlink into an `@openai/codex` package) report
# a version; anything else first on PATH is somebody's deliberate choice and must not even be run.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d -t codex-newest)" || exit 1
trap 'rm -rf "$TMP"' EXIT

install_at() {   # $1=bin dir $2=version — an npm-shaped install: bin/codex → ../lib/node_modules/@openai/codex/bin/codex.js
  local root; root="$(dirname "$1")"
  mkdir -p "$1" "$root/lib/node_modules/@openai/codex/bin"
  printf '#!/bin/sh\n[ "$1" = --version ] && echo "codex-cli %s" && exit 0\necho "ran %s $*" >> "%s/ran.log"\n' \
    "$2" "$2" "$TMP" > "$root/lib/node_modules/@openai/codex/bin/codex.js"
  chmod +x "$root/lib/node_modules/@openai/codex/bin/codex.js"
  ln -sf ../lib/node_modules/@openai/codex/bin/codex.js "$1/codex"
}
install_at "$TMP/brew/bin" 0.153.4
install_at "$TMP/nvm/bin" 0.156.0

resolve() {   # $1=PATH prefix → which codex a sourced engine script would run, and its version
  SUPERVISOR_STATE_DIR="$TMP/state" PATH="$1:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c '. "$0/supervisor-lib.sh"; command -v codex; codex --version' "$BIN_DIR" 2>/dev/null
}

echo "===== the older install first on PATH ====="
out="$(resolve "$TMP/brew/bin:$TMP/nvm/bin")"
case "$out" in *"codex-cli 0.156.0"*) ok "the newest install answers" ;; *) bad "the first on PATH answered: $out" ;; esac
case "$out" in "$TMP/state/codex-bin/codex"*) ok "through the engine's own shim, nothing else on PATH moved" ;; *) bad "resolved via $out" ;; esac

echo "===== and every later start costs nothing ====="
before="$(wc -l < "$TMP/state/codex-bin/installs" | tr -d ' ')"
resolve "$TMP/nvm/bin:$TMP/brew/bin" >/dev/null
after="$(wc -l < "$TMP/state/codex-bin/installs" | tr -d ' ')"
[ "$before" = "$after" ] && ok "a PATH in the other order re-uses what each install reported" \
  || bad "the versions were asked again ($before → $after rows)"
out="$(resolve "$TMP/nvm/bin:$TMP/brew/bin")"
case "$out" in *"codex-cli 0.156.0"*) ok "and the answer does not flip with the order" ;; *) bad "flipped: $out" ;; esac

echo "===== an upgrade is noticed ====="
sleep 1; install_at "$TMP/brew/bin" 0.157.0; touch "$TMP/brew/lib/node_modules/@openai/codex/bin/codex.js"
out="$(resolve "$TMP/brew/bin:$TMP/nvm/bin")"
case "$out" in *"codex-cli 0.157.0"*) ok "the upgraded install takes over" ;; *) bad "an upgrade went unnoticed: $out" ;; esac

echo "===== something deliberate first on PATH ====="
mkdir -p "$TMP/wrapper"; printf '#!/bin/sh\necho "wrapper $*" >> "%s/wrapper.log"\necho "codex-cli 9.9.9"\n' "$TMP" > "$TMP/wrapper/codex"
chmod +x "$TMP/wrapper/codex"; rm -rf "$TMP/state"
out="$(resolve "$TMP/wrapper:$TMP/brew/bin:$TMP/nvm/bin")"
case "$out" in "$TMP/wrapper/codex"*) ok "a wrapper first on PATH is left in charge" ;; *) bad "the wrapper was bypassed: $out" ;; esac
[ "$(grep -c -- '--version' "$TMP/wrapper.log" 2>/dev/null)" -le 1 ] \
  && ok "and was not probed by the resolver (only the test's own call ran it)" \
  || bad "the resolver ran somebody else's wrapper"

echo "===== an explicit binary wins outright ====="
out="$(SUPERVISOR_CODEX_BIN="$TMP/brew/bin/codex" SUPERVISOR_STATE_DIR="$TMP/state2" PATH="$TMP/brew/bin:$TMP/nvm/bin:/usr/bin:/bin" \
       bash -c '. "$0/supervisor-lib.sh"; command -v codex' "$BIN_DIR")"
[ "$out" = "$TMP/brew/bin/codex" ] && ok "SUPERVISOR_CODEX_BIN is not second-guessed" || bad "resolved $out"

echo "===== one install: nothing to choose ====="
out="$(SUPERVISOR_STATE_DIR="$TMP/state3" PATH="$TMP/nvm/bin:/usr/bin:/bin" bash -c '. "$0/supervisor-lib.sh"; command -v codex' "$BIN_DIR")"
[ "$out" = "$TMP/nvm/bin/codex" ] && ok "a single install is used as it is" || bad "resolved $out"

echo
[ "$fails" -eq 0 ] && echo "PASS: test-codex-newest" || { echo "FAIL: test-codex-newest ($fails)"; exit 1; }
