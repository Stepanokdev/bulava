#!/bin/bash
# The engine installing onto a Mac that has no Apple command line tools.
#
# There /usr/bin/python3 is a stand-in: it asks macOS to install the tools and exits. The installer
# found that out only after it had backed up Claude Code's settings, so every attempt (the app makes
# one at every launch) left another backup behind, and the last thing it said was Apple's
# "See `man xcode-select` for more details." — which Bulava showed as the reason. That is a 1.13
# user's report, word for word (fingerprint 8e6197936f0c498c, 2026-10-11).
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The engine copied out, so that installing it has nothing to do with this checkout.
cp -R "$ENGINE" "$TMP/engine"

# What /usr/bin/python3 says and does on such a Mac, in Apple's words as the report carried them.
mkdir -p "$TMP/stand-in"
cat > "$TMP/stand-in/python3" <<'EOF'
#!/bin/bash
echo "xcode-select: note: No developer tools were found, requesting install." >&2
echo "If developer tools are located at a non-default location on disk, use \`sudo xcode-select --switch path/to/Xcode.app\` to specify the Xcode that you wish to use for command line developer tools, and cancel the installation dialog." >&2
echo "See \`man xcode-select\` for more details." >&2
exit 1
EOF
chmod +x "$TMP/stand-in/python3"

run_install() {  # $1 = HOME, $2 = PATH
  ( cd "$TMP/engine" && env -u SUPERVISOR_STATE_DIR HOME="$1" PATH="$2" bash ./install.sh ) \
    >"$TMP/install.log" 2>&1
}
last_line() { grep -v '^[[:space:]]*$' "$TMP/install.log" | tail -1; }

echo "===== Claude Code is set up, the command line tools are not ====="
HOME_A="$TMP/home-a"; mkdir -p "$HOME_A/.claude"
printf '{\n  "theme": "dark",\n  "hooks": {}\n}\n' > "$HOME_A/.claude/settings.json"
cp "$HOME_A/.claude/settings.json" "$TMP/settings.before"

if run_install "$HOME_A" "$TMP/stand-in:/usr/bin:/bin"; then
  bad "install.sh reported success with a python3 that cannot run"
else
  ok "install.sh does not claim to have installed anything"
fi
cmp -s "$TMP/settings.before" "$HOME_A/.claude/settings.json" \
  && ok "Claude Code's settings are byte for byte what they were" \
  || bad "settings.json was rewritten"
n="$(ls "$HOME_A"/.claude/settings.json.backup-* 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = 0 ] && ok "no backup was left behind for an install that never started" \
             || bad "$n backup(s) of settings.json left behind — one more at every launch"
[ ! -e "$HOME_A/.claude/supervisor/worker-settings.json" ] \
  && ok "no worker hooks were written" || bad "worker-settings.json was written"
[ -z "$(ls -A "$HOME_A/.local/bin" 2>/dev/null)" ] \
  && ok "no terminal commands were linked" || bad "terminal commands were linked: $(ls "$HOME_A/.local/bin")"

last="$(last_line)"
case "$last" in
  *"man xcode-select"*) bad "the last word is still Apple's, which is what the app shows: $last" ;;
  *python3*"xcode-select --install"*) ok "the last line says what is wrong and what installs it" ;;
  *) bad "the last line does not say python3 cannot run: $last" ;;
esac
grep -q "No developer tools were found" "$TMP/install.log" \
  && ok "python3's own words are kept above it, for the details" \
  || bad "what python3 said was swallowed"

echo
echo "===== the same Mac before Claude Code was ever run ====="
HOME_B="$TMP/home-b"; mkdir -p "$HOME_B"
run_install "$HOME_B" "$TMP/stand-in:/usr/bin:/bin" \
  && bad "install.sh reported success on an empty HOME it could not install into" \
  || ok "it refuses there too"
[ -z "$(ls -A "$HOME_B")" ] && ok "and HOME is exactly as empty as it was" \
                            || bad "it created: $(cd "$HOME_B" && find . -mindepth 1 | head -5 | tr '\n' ' ')"

echo
echo "===== a python3 that runs is not refused ====="
HOME_C="$TMP/home-c"; mkdir -p "$HOME_C/.claude"
cp "$TMP/settings.before" "$HOME_C/.claude/settings.json"
if run_install "$HOME_C" "$PATH"; then
  ok "the installer still installs where python3 works"
  [ -s "$HOME_C/.claude/supervisor/worker-settings.json" ] \
    && ok "and writes the worker hooks" || bad "it succeeded without writing the worker hooks"
else
  bad "a working python3 was refused: $(last_line)"
fi

echo
[ "$fails" = 0 ] && echo "✅ no developer tools: the engine refuses before it touches anything" \
                 || echo "❌ no developer tools: $fails problem(s)"
exit "$fails"
