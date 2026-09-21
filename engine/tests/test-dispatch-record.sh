#!/bin/bash
# What a dispatch leaves behind, so the app can find the work afterwards.
#
# Three failures in a row came from this being absent. A second job into a live session was
# invisible to the app, because the run nonce cannot change and there was nothing else to tell the
# two apart. A job from the terminal produced no report at all, because the instruction that asks
# for one lived only in the app. And a result nobody was running to see was gone for good, because
# `done` is one file per instance and the next job clears it.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SUP_DIR_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supervisor" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

echo "===== the contract lives in one file, and renders ====="

. "$BIN_DIR/supervisor-lib.sh"
d="$(report_directive "/tmp/reports/abc12345" Ukrainian)"
case "$d" in
  *"/tmp/reports/abc12345"*) ok "the directive names the directory it was given" ;;
  *) bad "the directive lost its directory" ;;
esac
case "$d" in
  *"{{"*) bad "a placeholder was left unsubstituted" ;;
  *) ok "nothing is left unsubstituted" ;;
esac
# The word may appear — the directive explains why NOT to use it. What must not appear is
# screencapture offered as the way to take the shot.
case "$d" in
  *"(screencapture)"*|*"через screencapture"*) bad "still offers screencapture as the way to capture" ;;
  *) case "$d" in
       *'$IDIR/capture'*) ok "macOS frames go through \$IDIR/capture" ;;
       *) bad "no capture instruction at all" ;;
     esac ;;
esac

echo
echo "===== the app's key wins, and nobody asks twice ====="
# The app appends its own directive and hands the key over; dispatch must not add a second one
# pointing somewhere else — the worker was told two different directories in one prompt.
if grep -q 'if \[ -z "\$CALLER_REPORT_KEY" \]; then' "$BIN_DIR/dispatch.sh" \
   && grep -Eq -- '--report-key\) +CALLER_REPORT_KEY=' "$BIN_DIR/dispatch.sh"; then
  ok "a caller-supplied key suppresses the engine's own directive"
else
  bad "dispatch appends a directive unconditionally"
fi


echo
echo "===== the report is ONE document, and the text is part of it ====="
# The complaint this pins: he asked a finished run why the report said nothing about the parts that
# need a backend change, and got a second file beside the HTML instead of a section inside it. The
# contract was the cause — it described `body` as belonging to the non-visual format only.
case "$d" in
  *"лишається основним текстом звіту і заповнюється завжди"*) ok "the written report is required with every format" ;;
  *) bad "the contract still ties the text to one format" ;;
esac
case "$d" in
  *"НЕ винось зміст у сусідній файл"*) ok "and pointing at a neighbouring file is refused" ;;
  *) bad "nothing stops the report being deferred to another file" ;;
esac
case "$d" in
  *"закрито / частково / не закрито /"*) ok "every asked-for item gets a status" ;;
  *) bad "the contract does not ask which items are closed" ;;
esac
case "$d" in
  *"з тими ж номерами"*) ok "the numbers he wrote the task in are kept" ;;
  *) bad "nothing preserves the director own numbering" ;;
esac
case "$d" in
  *"вільній формі"*|*"ВІЛЬНІЙ формі"*) ok "and the rest stays free-form prose, not a template" ;;
  *) bad "the contract reads as a form to fill in" ;;
esac
# The shape he asked for in his own words: item, verdict, proof under it.
case "$d" in
  *'"sections"'*) ok "the report answers item by item" ;;
  *) bad "there is no per-item answer in the contract" ;;
esac
case "$d" in
  *"САМЕ по тому списку"*) ok "and it answers HIS list, not the plan we made from it" ;;
  *) bad "nothing ties the report to the director own numbering" ;;
esac
case "$d" in
  *"В ЦЕЙ ЖЕ розділ"*) ok "the proof sits with the item it proves" ;;
  *) bad "evidence is still a gallery at the end" ;;
esac
case "$d" in
  *"Жоден його пункт не має зникнути"*) ok "and nothing he asked for may silently vanish" ;;
  *) bad "an item can still disappear from the report" ;;
esac
case "$d" in
  *'"attention"'*) ok "what needs the director is its own field" ;;
  *) bad "there is no place for what needs his decision" ;;
esac

echo
echo "===== and the caller names the dispatch when it has a card for it ====="
# The app has the card before the engine has the run, so the app names the work. When the engine
# minted the id instead, the app could not recognise its own job coming back and adopted it as work
# from outside: a twin card, a twin report, the night's console printed twice.
if grep -q -- '--dispatch-id) CALLER_DISPATCH_ID=' "$BIN_DIR/dispatch.sh" \
   && grep -q 'DISPATCH_ID="\${CALLER_DISPATCH_ID:-' "$BIN_DIR/dispatch.sh"; then
  ok "a caller-supplied dispatch id is used as-is"
else
  bad "the engine mints an id even when the caller already named one"
fi
# And a dispatch from the terminal, which has no card to bind to, still gets one.
if grep -q 'uuidgen' "$BIN_DIR/dispatch.sh"; then
  ok "a dispatch with no caller id still gets one"
else
  bad "a terminal dispatch would have no identity at all"
fi

echo
echo "===== every dispatch is recorded once and never rewritten ====="
if grep -q 'dispatches/\$DISPATCH_ID.json' "$BIN_DIR/dispatch.sh"; then
  ok "each dispatch gets its own immutable record"
else
  bad "only the latest dispatch is kept — a result nobody saw is lost"
fi
if grep -q 'dispatches/\$_did.done' "$(dirname "$BIN_DIR")/hooks/review-gate.sh"; then
  ok "the gate stamps the dispatch it finished"
else
  bad "nothing marks WHICH dispatch a result belongs to"
fi

echo
[ "$fails" = 0 ] && echo "✅ dispatch records: the work can be found afterwards" || echo "❌ $fails problem(s)"
exit "$fails"
