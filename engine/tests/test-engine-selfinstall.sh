#!/bin/bash
# The app carries the engine, and installing the app is the whole installation.
#
# A stranger downloads one file. Everything the engine needs after that — Claude Code's hooks, the
# terminal commands, the state directories — has to come from inside the app, onto a machine that
# has never seen any of it. This drives the real installer out of a real app bundle, against a HOME
# with nothing in it.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
ok()   { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad()  { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  \xe2\x9e\x96 %s\n' "$1"; }

if [ ! -d "$ROOT/Night Shift" ]; then
  skip "the app checkout is not here — the bundled engine belongs to the application"
  exit 0
fi

# Both places a build of this app lands: Xcode's shared DerivedData, and the private one
# `.night-verify.sh` uses so that an unsigned verification build cannot replace the signed app the
# director actually launches. The newest of the two is the one that matches the current source —
# reading only Xcode's meant this test kept auditing a bundle from before the change under test.
# …and the one the verifier builds for itself. It compiles the app into its own evidence directory
# and then runs this suite, so without being told where that is, this test audited whatever stale
# bundle happened to be lying in the other two places — and failed every verifier run for a
# mismatch between an old app and the engine under test.
#
# "Newest" has to be read off the bundled ENGINE, not off the .app folder. A directory's mtime does
# not move when a file inside it is rewritten, so `ls -dt` ranked these by whenever each bundle was
# first created — and picked a build from four days ago over one made a minute ago, then failed the
# whole suite for a drift that existed only in the bundle nobody had rebuilt.
newest_bundled_engine() {   # $@ = candidate .app paths → the one whose engine was written last
  local c best="" best_t=0 t
  for c in "$@"; do
    [ -d "$c/Contents/Resources/engine" ] || continue
    t="$(find "$c/Contents/Resources/engine" -type f -print0 2>/dev/null \
         | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)"
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    if [ "$t" -gt "$best_t" ]; then best="$c"; best_t="$t"; fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}
APP="$(newest_bundled_engine ${BULAVA_APP:+"$BULAVA_APP"} \
              "$HOME/Library/Developer/Xcode/DerivedData/Night_Shift-"*/Build/Products/Debug/"Bulava.app" \
              "${TMPDIR:-/tmp}/bulava-verify-dd/Build/Products/Debug/Bulava.app" 2>/dev/null)"
if [ -z "$APP" ]; then
  skip "no built application here (build it to run this)"
  exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/home"; mkdir -p "$FAKE"

# An app built before the engine last changed proves nothing about the engine as it stands: this
# test would audit the previous version while reporting on this one, and that is how a real
# data-loss bug in the installer was seen to pass.
#
# Compared by CONTENT, not by timestamps. A directory's own mtime does not move when a file inside
# it is edited, so `engine -nt bundle` answered "still current" for every edit that renamed
# nothing; and comparing the newest file on each side calls the bundle stale the moment anyone
# edits this test. `tests/` is excluded for that reason — it is bundled, but nothing here asserts
# on it — and so are the artefacts the bundling step deliberately leaves out.
#
# `-i` is not decoration. A dry-run rsync without it prints NOTHING, whatever it found, so the
# first version of this guard reported "no drift" for every bundle including a missing one. The
# exit status is read too: a comparison that could not run is not a comparison that passed.
bundle_drift() {  # $1 = bundle's engine dir → prints what differs; empty means identical
  local out; out="$TMP/drift-$$.txt"
  if rsync -rcni --delete --exclude 'tests' --exclude '.engine-version' \
       --exclude 'supervisor/memory' --exclude 'supervisor/qa-history.jsonl' \
       --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' --exclude '*.backup-*' \
       "$ROOT/engine/" "$1/" > "$out" 2>&1; then
    grep -v '^$' "$out" | head -3 | tr '\n' ' '
  else
    printf 'rsync could not compare the trees: %s' "$(tail -2 "$out" | tr '\n' ' ')"
  fi
  rm -f "$out"
}

echo "===== the comparison that decides whether this test can audit anything ====="
# Proving the guard before trusting it. A detector that cannot see a changed file would let every
# later assertion in this file report on the wrong engine.
PROBE="$TMP/probe-bundle"
rsync -a "$APP/Contents/Resources/engine/" "$PROBE/" 2>/dev/null
printf '\n# a line this checkout does not have\n' >> "$PROBE/install.sh"
if [ -n "$(bundle_drift "$PROBE")" ]; then
  ok "a bundle with one edited file is seen as different"
else
  bad "the drift check cannot see an edited file — every assertion below would be meaningless"
fi
if [ -n "$(bundle_drift "$TMP/not-here")" ]; then
  ok "a bundle that is not there is seen as different"
else
  bad "the drift check reports a missing bundle as identical"
fi
rm -rf "$PROBE"

DRIFT="$(bundle_drift "$APP/Contents/Resources/engine")"
if [ -n "$DRIFT" ]; then
  # NOT a skip. A skip here exits 0, and this file is the only thing that audits the installer a
  # stranger will run — reporting success while auditing a different engine is the failure mode
  # that let a data-loss bug through once already.
  bad "the built app carries a different engine than this checkout ($DRIFT)"
  echo "     rebuild it first:  xcodebuild -project 'Night Shift.xcodeproj' -scheme 'Night Shift' \\"
  echo "                          -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build"
  echo "❌ engine self-install: cannot audit a bundle that does not match the source"
  exit 1
fi
ok "the built app carries this checkout's engine"

echo "===== the engine travels inside the app ====="
BUNDLED="$APP/Contents/Resources/engine"
[ -x "$BUNDLED/install.sh" ] && ok "the bundle carries an installer" \
                             || bad "no installer inside the app bundle"
[ -s "$BUNDLED/.engine-version" ] && ok "stamped with the build it shipped in ($(cat "$BUNDLED/.engine-version"))" \
                                  || bad "the bundled engine carries no version stamp"

# Nothing of its author's may ride along.
leaks=""
for p in supervisor/lessons supervisor/memory supervisor/qa-history.jsonl; do
  [ -e "$BUNDLED/$p" ] && leaks="$leaks $p"
done
[ -n "$leaks" ] && bad "personal material shipped inside the app:$leaks" \
                || ok "no memory, no recorded answers — the bundle is impersonal"

echo
echo "===== it installs itself onto a machine that has never run any of this ====="
# What the app's installer does, with the app's own copy as the source.
DEST="$FAKE/Library/Application Support/Bulava/engine"
mkdir -p "$(dirname "$DEST")"
rsync -a --exclude 'supervisor/memory' "$BUNDLED/" "$DEST/" 2>/dev/null
( cd "$DEST" && HOME="$FAKE" bash ./install.sh ) > "$TMP/install.log" 2>&1 \
  && ok "the installer succeeds from inside Application Support" \
  || bad "install failed: $(grep -m2 -iE 'error|no such file' "$TMP/install.log" | tr '\n' ' ')"

[ -s "$FAKE/.claude/settings.json" ] && ok "Claude Code's settings were written" \
                                     || bad "no settings.json"
[ -s "$FAKE/.claude/supervisor/worker-settings.json" ] && ok "the worker's hooks are in place" \
                                                       || bad "worker-settings.json missing"

echo
echo "===== and the terminal commands exist, pointing at the installed copy ====="
missing=""
for c in night-shift night-queue report-finding report-outcome; do
  [ -L "$FAKE/.local/bin/$c" ] || missing="$missing $c"
done
[ -n "$missing" ] && bad "commands not linked:$missing" || ok "night-shift and friends are on PATH"

target="$(readlink "$FAKE/.local/bin/night-shift" 2>/dev/null || true)"
case "$target" in
  "$DEST"/*) ok "night-shift resolves to the installed engine, not the app bundle" ;;
  *)         bad "night-shift points somewhere unexpected: ${target:-nowhere}" ;;
esac
# A link into the bundle would break on the next app update, and silently.
case "$target" in
  *"/Bulava.app/"*) bad "the command points inside the app bundle" ;;
  *) ok "nothing points inside the bundle, so an update cannot break it" ;;
esac

echo
echo "===== a fresh install has no memory of anyone, and no way to start one ====="
if [ -e "$FAKE/.claude/supervisor/memory" ]; then
  bad "the install created a memory store"
else
  ok "no memory store — the engine does not keep one"
fi
stale=""
for c in supervisor-learn night-memory; do
  [ -L "$FAKE/.local/bin/$c" ] && stale="$stale $c"
done
[ -e "$FAKE/.claude/commands/learn.md" ] && stale="$stale /learn"
[ -n "$stale" ] && bad "self-learning is still reachable:$stale" \
                || ok "nothing on PATH or in the slash commands can start learning"

echo
[ "$fails" = 0 ] && echo "✅ engine self-install: one download is the whole installation" \
                 || echo "❌ engine self-install: $fails problem(s)"
exit "$fails"
