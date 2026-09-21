#!/bin/bash
# Take the website's pictures of the application, without photographing anybody's real work.
#
#   site/demo/shoot.sh [--keep]
#
# Two things have to be true at once: the frames must be of the REAL Bulava, and they must contain
# no client of the person whose Mac is taking them. So this starts a SECOND Bulava against the
# fixture in this directory — its own state, its own engine state, invented products, English —
# drives it into the state each picture is about, photographs THAT window alone, and then reads the
# frames back with Vision to prove the first condition did not quietly cost us the second.
#
# WHY THE PICTURE IS TAKEN BY TERMINAL. macOS records a screen-recording grant against the
# RESPONSIBLE process, which a child inherits from whatever started it. Bulava started from a
# script inherits the script's, and a script has none — so ScreenCaptureKit answers "the user
# declined" while the switch for Bulava in System Settings is plainly on. An evening went into
# that sentence. Terminal holds the grant, `open -a Terminal` hands it a file to run, and
# `windowshot` asks for one window by pid, so nothing else on the desktop is ever in frame.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="${BULAVA_APP:-/Applications/Bulava.app}"
OUT="$ROOT/site/assets"
WORK="${TMPDIR:-/tmp}/bulava-shoot"
FRAME_KEY="NSWindow Frame Night_Shift.ContentView-1-AppWindow-1"
KEEP=0
LANG_CODE="en"
for a in "$@"; do
  case "$a" in
    --keep) KEEP=1 ;;
    --lang=*) LANG_CODE="${a#--lang=}" ;;
  esac
done
case "$LANG_CODE" in en|uk) : ;; *) die "мова має бути en або uk, а не «$LANG_CODE»" ;; esac

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
die()  { printf '\n❌ %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || die "немає $APP"
for tool in disclaim windowshot; do
  [ -x "$HERE/$tool" ] || die "немає $HERE/$tool — збери: make -C site/demo"
done

# The window frame lives in the app's shared defaults, so the demo instance and the director's
# copy read the same key. Borrowed, not taken: put back on the way out however this ends.
ORIGINAL_FRAME="$(defaults read "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" "$FRAME_KEY" 2>/dev/null || true)"
BUNDLE_ID="$(defaults read "$APP/Contents/Info" CFBundleIdentifier)"
restore_frame() {
  if [ -n "$ORIGINAL_FRAME" ]; then
    defaults write "$BUNDLE_ID" "$FRAME_KEY" "$ORIGINAL_FRAME"
  else
    defaults delete "$BUNDLE_ID" "$FRAME_KEY" 2>/dev/null || true
  fi
}

say "готую демо-стан"
rm -rf "$WORK"
PATHS="$(BULAVA_DEMO_LANG="$LANG_CODE" python3 "$HERE/fixture.py" "$WORK")"
STATE="$(printf '%s\n' "$PATHS" | sed -n 1p)"
ENGINE="$(printf '%s\n' "$PATHS" | sed -n 2p)"
[ -d "$STATE" ] && [ -d "$ENGINE" ] || die "фікстура не зібралась"
INBOX="$WORK/inbox.jsonl"
: > "$INBOX"

# A window the size the page needs. The frames are taken at 2×, so 1440×900 gives 2880×1800 —
# enough for the hero to stay sharp on a Retina display and for the crops to stay readable.
defaults write "$BUNDLE_ID" "$FRAME_KEY" "36 30 1440 900 0 0 1512 949 "

say "запускаю другу Bulava ($LANG_CODE)"
PID="$(BULAVA_STATE_DIR="$STATE" SUPERVISOR_STATE_DIR="$ENGINE" BULAVA_TEST_INBOX="$INBOX" \
       DISCLAIM_LOG="$WORK/app.log" \
       "$HERE/disclaim" "$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)" \
       -AppleLanguages "($LANG_CODE)")"
[ -n "$PID" ] || { restore_frame; die "демо-примірник не запустився"; }
note "pid $PID"

cleanup() {
  restore_frame
  # The fixture leaves a stand-in watchdog alive so the interface reads as working; it is ours
  # and it goes when we do.
  for f in "$ENGINE"/instances/*/watchdog.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
  done
  [ "$KEEP" = 1 ] || kill "$PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say "чекаю, поки вона буде готова"
ready=0
for _ in $(seq 1 60); do
  if [ -f "$ENGINE/capture-requests/service.json" ] \
     && grep -q "\"pid\":$PID" "$ENGINE/capture-requests/service.json" 2>/dev/null; then
    ready=1; break
  fi
  perl -e 'select(undef,undef,undef,0.5)'
done
[ "$ready" = 1 ] || die "демо-примірник не піднявся за 30 с"

# Driven through the app's own test inbox rather than by clicking: no Accessibility grant is
# involved, and the same lines reproduce the same frames on any machine.
drive() { printf '%s\n' "$1" >> "$INBOX"; perl -e 'select(undef,undef,undef,1.2)'; }
say "ставлю потрібний стан"
# No `language` action here on purpose: changing the interface language makes the app relaunch
# itself, which ends this process and starts another one — and the pid we were about to
# photograph stops existing. The language is set at launch instead, by -AppleLanguages.
drive '{"do":"theme","theme":"dark"}'
drive '{"do":"open","product":"Pocket Ledger"}'
drive '{"do":"inspector","product":"Pocket Ledger","action":"open"}'
perl -e 'select(undef,undef,undef,2.5)'
note "$(tail -4 "$INBOX.reply" 2>/dev/null | sed 's/^/     /' || true)"

# Read again rather than trusted: anything that makes the app relaunch itself — a language
# change, an update — leaves the pid we started with pointing at nothing.
PID="$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$ENGINE/capture-requests/service.json" 2>/dev/null)"
kill -0 "$PID" 2>/dev/null || die "демо-примірник більше не працює"

say "знімаю вікно (pid $PID)"
rm -f "$WORK/win.png" "$WORK/done" "$WORK/shotlog"
cat > "$WORK/take.command" <<EOF
#!/bin/bash
# Run BY Terminal, which macOS allows to record the screen.
cd "$ROOT"
sleep 4
"$HERE/windowshot" $PID "$WORK/win.png" > "$WORK/shotlog" 2>&1
echo "\$?" > "$WORK/done"
sleep 1
osascript -e 'tell application "Terminal" to close (every window whose name contains "take")' >/dev/null 2>&1 || true
EOF
chmod +x "$WORK/take.command"
open -a Terminal "$WORK/take.command"
for _ in $(seq 1 30); do [ -f "$WORK/done" ] && break; perl -e 'select(undef,undef,undef,1)'; done
[ "$(cat "$WORK/done" 2>/dev/null)" = "0" ] || {
  cat >&2 <<WHY

❌ знімок не вийшов: $(cat "$WORK/shotlog" 2>/dev/null)

Кадр робить Terminal, бо macOS видає дозвіл на запис екрана ВІДПОВІДАЛЬНОМУ процесу.
Якщо Terminal немає в System Settings → Privacy & Security → Screen & System Audio
Recording — додай його там. Перемикач для Bulava до цього відношення не має.
WHY
  exit 1
}
note "$(cat "$WORK/shotlog")"

say "розкладаю кадри"
mkdir -p "$OUT"
cp "$WORK/win.png" "$OUT/shot-conversation-$LANG_CODE.png"
python3 "$HERE/crop.py" "$OUT/shot-conversation-$LANG_CODE.png" "$OUT" "$LANG_CODE" \
  || die "не вдалося нарізати деталі"

say "перевіряю, що на кадрах немає нічого чужого"
python3 "$ROOT/site/analytics/check-screenshots.py" || die "кадри не пройшли перевірку — не публікуй їх"

printf '\n✅ Кадри (%s) в site/assets. Обидві мови: --lang=en і --lang=uk\n' "$LANG_CODE"
