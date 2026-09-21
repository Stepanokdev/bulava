#!/bin/bash
# Someone else's first five minutes with this.
#
# The installer assumed a ~/.claude that already had settings in it, and on a machine that had
# never run Claude Code it died on its very first line — `cp: settings.json: No such file or
# directory` — before doing anything at all. That is the one case an installer exists for.
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A HOME with nothing in it, and a PATH that still has the tools the script needs.
FAKE="$TMP/home"; mkdir -p "$FAKE"

run_install() {  # $1=export dir to install FROM
  ( cd "$1" && HOME="$FAKE" bash ./install.sh ) >"$TMP/install.log" 2>&1
}

echo "===== the engine installs onto a machine that has never run Claude Code ====="
EXPORT="$TMP/engine"
if "$ENGINE/bin/publish-engine.sh" "$EXPORT" >"$TMP/pub.log" 2>&1; then
  ok "a clean engine was produced to install from"
else
  bad "could not produce a clean engine: $(tail -2 "$TMP/pub.log" | tr '\n' ' ')"
  echo; echo "❌ clean install: $fails problem(s)"; exit "$fails"
fi

if run_install "$EXPORT"; then
  ok "install.sh succeeds on an empty HOME"
else
  bad "install.sh failed on an empty HOME: $(grep -m2 -iE 'no such file|error|not found' "$TMP/install.log" | tr '\n' ' ')"
fi

[ -s "$FAKE/.claude/settings.json" ] \
  && ok "it created the settings file it needs" \
  || bad "no settings.json was written"

if [ -s "$FAKE/.claude/settings.json" ]; then
  python3 - "$FAKE/.claude/settings.json" <<'PY' && ok "the settings it wrote are valid JSON with the statusline wired" || bad "the settings it wrote are not usable"
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(s, dict), "not an object"
assert "statusLine" in s and s["statusLine"].get("command"), "no statusline"
PY
fi

[ -s "$FAKE/.claude/supervisor/worker-settings.json" ] \
  && ok "the worker's own hooks were installed" \
  || bad "worker-settings.json is missing"

# Nothing personal can have arrived with it — this is a stranger's machine. The engine keeps no
# learned memory at all now, so the check is that no store appears and no learning command is put
# on their PATH by the act of installing.
if [ -e "$FAKE/.claude/supervisor/memory" ]; then
  bad "the fresh install created a memory store"
elif [ -L "$FAKE/.local/bin/supervisor-learn" ] || [ -L "$FAKE/.local/bin/night-memory" ]; then
  bad "the fresh install put a self-learning command on PATH"
elif [ -e "$FAKE/.claude/commands/learn.md" ]; then
  bad "the fresh install added a /learn command"
else
  ok "the fresh install carries no memory and nothing that would start one"
fi

echo
echo "===== running it twice is not worse than running it once ====="
if run_install "$EXPORT"; then
  ok "a second install still succeeds"
  n="$(ls "$FAKE"/.claude/settings.json.backup-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -ge 1 ] && ok "and it backed up what was already there ($n backup(s))" \
                 || bad "the second run kept no backup"
else
  bad "the second install failed: $(grep -m2 -iE 'no such file|error' "$TMP/install.log" | tr '\n' ' ')"
fi

echo
echo "===== and its python runs on the python a stranger has ====="
# A Mac ships /usr/bin/python3 and nothing else. This machine had Homebrew's 3.14 first on PATH, so
# `web-video.py` — which contained an f-string expression with a backslash in it, legal only from
# 3.12 — compiled here and was a SyntaxError on every Mac without a newer python installed. The
# recorder simply never started there, and nothing in the suite noticed for as long as the developer
# had the newer one.
STOCK="/usr/bin/python3"
if [ -x "$STOCK" ]; then
  bad_py=""
  for f in "$EXPORT"/bin/*.py "$EXPORT"/bin/lib/*.py; do
    [ -f "$f" ] || continue
    "$STOCK" -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$f" \
      >/dev/null 2>&1 || bad_py="$bad_py $(basename "$f")"
  done
  [ -z "$bad_py" ] \
    && ok "every python file in the shipped engine compiles on $("$STOCK" -V 2>&1)" \
    || bad "these do not run on a stock macOS python:$bad_py"
else
  ok "no stock python3 on this machine to check against"
fi

echo
[ "$fails" = 0 ] && echo "✅ clean install: a stranger can install this" || echo "❌ clean install: $fails problem(s)"
exit "$fails"
