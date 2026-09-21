#!/bin/bash
# Updating the engine must never destroy what the director wrote.
#
# An install old enough kept their own files INSIDE the engine: before the memory store was split
# out, `_global.md` and `projects/*.md` lived at `supervisor/lessons/`. This engine ships no such
# directory, and the app updates by `rsync --delete` — so without care, updating the app would
# delete their writing as a side effect of copying files. `install.sh` moves anything found there
# into the store before the directory goes.
#
# Everything here runs against the CHECKOUT's engine, never the built app: the claim is about the
# installer, the installer is in this repository, and a test that needs a fresh build behind it is
# a test that skips — which for this particular claim reads as "nothing was lost" when nothing was
# checked.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The engine under test. Defaults to this checkout, and is pointed at a release's bundled copy for
# the rehearsal before publishing: the bytes a stranger downloads are the ones that have to rescue
# their files, and on this machine the development checkout always wins at runtime, so the shipped
# path is never exercised here unless it is asked for by name.
ENGINE="${SUPERVISOR_ENGINE_UNDER_TEST:-$ROOT/engine}"
[ -x "$ENGINE/install.sh" ] || { echo "  ❌ немає движка для перевірки: $ENGINE" >&2; exit 1; }

fails=0
ok()   { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad()  { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  \xe2\x9e\x96 %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

GLOBAL_TEXT='# taste
## his own rule, written by hand
keep the estimate at the lower bound'
PROJECT_TEXT='# atlas
## the decision he made about this one app
no dark theme here'

# An install from before the split: this engine, plus the directory it no longer ships.
old_install() {  # $1 = where to build it
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir/supervisor/lessons/projects"
  rsync -a --exclude 'supervisor/memory' --exclude 'tests' "$ENGINE/" "$dir/" 2>/dev/null
  mkdir -p "$dir/supervisor/lessons/projects"
  printf '%s\n' "$GLOBAL_TEXT"  > "$dir/supervisor/lessons/_global.md"
  printf '%s\n' "$PROJECT_TEXT" > "$dir/supervisor/lessons/projects/atlas-000000000000.md"
  printf '# shipped practice, same for everyone\n' > "$dir/supervisor/lessons/ios-native.md"
}

echo "===== the update the app performs holds their files back from --delete ====="
# Read out of the installer rather than retyped: a test that hardcodes the flags keeps passing
# after someone edits the Swift, which is the only place the real command lives.
INSTALLER_SRC="$ROOT/Night Shift/Engine/EngineInstaller.swift"
if [ -f "$INSTALLER_SRC" ]; then
  RSYNC_LINE="$(grep -m1 'rsync -a --delete' "$INSTALLER_SRC" || true)"
  EXCLUDES="$(printf '%s' "$RSYNC_LINE" | grep -oE "\-\-exclude '[^']+'" | tr '\n' ' ')"
  case "$EXCLUDES" in
    *"--exclude 'supervisor/lessons'"*) ok "the app's update excludes supervisor/lessons from --delete" ;;
    *) bad "the app's update would delete supervisor/lessons: ${EXCLUDES:-no rsync line found}" ;;
  esac
  case "$EXCLUDES" in
    *"--exclude 'supervisor/memory'"*) ok "and the memory store as well" ;;
    *) bad "the app's update would delete the memory store" ;;
  esac
else
  # An exported engine ships on its own, with no app beside it — that is the point of the export,
  # and `test-export-suite.sh` runs this whole suite from one. There is no Swift here to read the
  # flags out of, so the contract between the app and the installer is checked where the app
  # exists, and what runs here is the installer's own behaviour under the flags it is known to get.
  skip "no app checkout beside this engine — the update command is checked in the repository"
  EXCLUDES="--exclude 'supervisor/memory' --exclude 'supervisor/lessons'"
fi

echo
echo "===== their writing survives the update, byte for byte ====="
OLD="$TMP/install"; old_install "$OLD"
HOME1="$TMP/home"; mkdir -p "$HOME1"
eval "rsync -a --delete $EXCLUDES --exclude 'tests' \"\$ENGINE/\" \"\$OLD/\"" 2>/dev/null
( cd "$OLD" && HOME="$HOME1" bash ./install.sh ) > "$TMP/install.log" 2>&1 \
  && ok "the installer succeeds" \
  || bad "install failed: $(grep -m2 -iE 'error|❌|no such file' "$TMP/install.log" | tr '\n' ' ')"

STORE="$HOME1/.claude/supervisor/memory"
[ "$(cat "$STORE/_global.md" 2>/dev/null)" = "$GLOBAL_TEXT" ] \
  && ok "his cross-project file is in the store, unchanged" \
  || bad "_global.md did not survive: $(ls -R "$STORE" 2>/dev/null | tr '\n' ' ')"
[ "$(cat "$STORE/projects/atlas-000000000000.md" 2>/dev/null)" = "$PROJECT_TEXT" ] \
  && ok "and so is what he decided about a product" \
  || bad "the product file did not survive: $(ls "$STORE/projects" 2>/dev/null | tr '\n' ' ')"
[ -e "$OLD/supervisor/lessons" ] \
  && bad "the engine still carries a lessons directory after the update" \
  || ok "the engine itself is left with no lessons directory"

echo
echo "===== a second rescue never writes over the first, however fast it happens ====="
# The destination used to carry a timestamp accurate to the second. Three rescues inside one
# second all resolved to the same name, and `mv` wrote each over the last — so the loop below is
# deliberately as fast as the machine can run it.
for n in 1 2 3; do
  mkdir -p "$OLD/supervisor/lessons"
  printf 'rescue number %s\n' "$n" > "$OLD/supervisor/lessons/_global.md"
  ( cd "$OLD" && HOME="$HOME1" bash ./install.sh ) >> "$TMP/install.log" 2>&1 \
    || bad "the installer failed on repeat number $n"
done
kept="$(cat "$STORE"/_global.md "$STORE"/_global.from-engine-*.md 2>/dev/null | grep -c 'rescue number' || true)"
if [ "$(cat "$STORE/_global.md" 2>/dev/null)" = "$GLOBAL_TEXT" ] && [ "$kept" = 3 ]; then
  ok "all three are on disk beside the original ($(ls "$STORE" | grep -c 'from-engine') archived copies)"
else
  bad "rescues overwrote each other: first file intact=$([ "$(cat "$STORE/_global.md" 2>/dev/null)" = "$GLOBAL_TEXT" ] && echo yes || echo no), later ones kept=$kept of 3"
fi

echo
echo "===== a rescue that cannot finish keeps everything and says so ====="
# The move used to be written `mv x y && n=$((n+1))`, which looks like it would stop the script.
# It does not: `set -e` is disabled for every command in an AND list except the last, so a failed
# `mv` fell through and the `rm -rf` below it deleted the original it had not saved.
OLD2="$TMP/install-blocked"; old_install "$OLD2"
HOME2="$TMP/home-blocked"; mkdir -p "$HOME2/.claude/supervisor/memory/projects"
chmod 500 "$HOME2/.claude/supervisor/memory" "$HOME2/.claude/supervisor/memory/projects"
eval "rsync -a --delete $EXCLUDES --exclude 'tests' \"\$ENGINE/\" \"\$OLD2/\"" 2>/dev/null
( cd "$OLD2" && HOME="$HOME2" bash ./install.sh ) > "$TMP/blocked.log" 2>&1
rc=$?
chmod -R u+w "$HOME2" 2>/dev/null || true

[ "$rc" != 0 ] && ok "the installer reports the failure (exit $rc)" \
               || bad "a rescue that could not write still reported success"

# …and still finishes installing. The app replaces the engine by `rsync --delete` BEFORE running
# this script, so an installer that stops at the rescue leaves the hooks unwritten and the commands
# unlinked — while the copied files make the app report the engine as ready. An engine that looks
# installed and has no gates is a worse state than the one the rescue is protecting against.
[ -s "$HOME2/.claude/supervisor/worker-settings.json" ] \
  && ok "the worker's hooks were still written" \
  || bad "the failure left the engine without its hooks"
[ -L "$HOME2/.local/bin/night-shift" ] \
  && ok "and the terminal commands are still linked" \
  || bad "the failure left the engine unreachable from the command line"
[ "$(cat "$OLD2/supervisor/lessons/_global.md" 2>/dev/null)" = "$GLOBAL_TEXT" ] \
  && ok "his cross-project file is still where it was" \
  || bad "_global.md was deleted without being saved anywhere"
[ "$(cat "$OLD2/supervisor/lessons/projects/atlas-000000000000.md" 2>/dev/null)" = "$PROJECT_TEXT" ] \
  && ok "and so is the product file" \
  || bad "the product file was deleted without being saved anywhere"
# The message a person reads has to describe the state they are actually in: the engine IS
# installed, and it is their old files that did not move. Saying "the engine is missing" would
# send them looking for the wrong problem.
if grep -q "Движок встановлено, але твої старі файли памʼяті лишились усередині нього" "$TMP/blocked.log"; then
  ok "and it describes the real state rather than a missing engine"
else
  bad "the message does not match what actually happened: $(tail -3 "$TMP/blocked.log" | tr '\n' ' ')"
fi
grep -q "$OLD2/supervisor/lessons" "$TMP/blocked.log" \
  && ok "and names where the files are" \
  || bad "it does not say where the files were left"

echo
echo "===== an engine with nothing to rescue is left alone ====="
OLD3="$TMP/install-clean"
rm -rf "$OLD3"; mkdir -p "$OLD3"
rsync -a --exclude 'supervisor/memory' --exclude 'tests' "$ENGINE/" "$OLD3/" 2>/dev/null
HOME3="$TMP/home-clean"; mkdir -p "$HOME3"
( cd "$OLD3" && HOME="$HOME3" bash ./install.sh ) > "$TMP/clean.log" 2>&1 \
  && ok "a normal install still succeeds" \
  || bad "the rescue broke the ordinary path: $(tail -2 "$TMP/clean.log" | tr '\n' ' ')"
[ -e "$HOME3/.claude/supervisor/memory" ] \
  && bad "it created a memory store on a machine that has none" \
  || ok "and creates no memory store out of nothing"

echo
echo "===== a command he edited survives the install that replaces it ====="
# Until 1.6.2 the app installed its engine only when somebody pressed a button. It now does it at
# launch, so anything install.sh overwrites is overwritten without a person present to see it.
HOME4="$TMP/home-edited"; mkdir -p "$HOME4/.claude/commands"
printf 'my own /night, edited by hand\n' > "$HOME4/.claude/commands/night.md"
printf 'an old learn command\n'          > "$HOME4/.claude/commands/learn.md"
( cd "$OLD3" && HOME="$HOME4" bash ./install.sh ) > "$TMP/edited.log" 2>&1 \
  && ok "the install still succeeds" \
  || bad "installing over edited commands failed: $(tail -2 "$TMP/edited.log" | tr '\n' ' ')"
cmp -s "$OLD3/claude-commands/night.md" "$HOME4/.claude/commands/night.md" \
  && ok "and /night is now exactly the one this engine ships" \
  || bad "the shipped /night did not land"
if grep -rqs "edited by hand" "$HOME4"/.claude/commands/night.md.backup-*; then
  ok "what he wrote is kept beside it"
else
  bad "his own /night was overwritten with nothing kept"
fi
if grep -rqs "an old learn command" "$HOME4"/.claude/commands/learn.md.backup-*; then
  ok "and the command being retired is kept too, not simply deleted"
else
  bad "learn.md was deleted without keeping a copy"
fi

echo
[ "$fails" = 0 ] && echo "✅ an update never costs him what he wrote" \
                 || echo "❌ $fails problem(s)"
exit "$fails"
