#!/bin/bash
# A Cyrillic task must not be able to stop Codex from taking part.
#
# It could, and it did. `head -c 1200` on `peer-alignment.md` landed in the middle of a Cyrillic
# letter, the two halves of it went onto `codex exec`'s argv, and clap refused the whole
# invocation before the session opened:
#
#     error: invalid UTF-8 was detected in one or more arguments
#
# The app showed "codex зупинився з помилкою (код 2) через 5с — codex exec [OPTIONS] <COMMAND>
# [ARGS] For more information, try '--help'", because the diagnostic kept the last two lines of
# stderr and the reason is on the first. So an evening went into a bug whose cause was printed in
# full, five seconds in, and thrown away.
#
# Three things are pinned down here: the clip itself at every boundary, every site that clips text
# that can be Cyrillic, and a diagnostic that keeps the reason instead of the usage block.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE 2>/dev/null || true
. "$BIN/supervisor-lib.sh"

valid() { printf '%s' "$1" | text_is_utf8; }
bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

echo "===== the clip never leaves half a character, at any boundary ====="
# Two bytes (Cyrillic), three (a dash), four (an emoji) — one of each straddling every limit from
# one byte to a whole character past it.
for spec in "ЖЖЖЖ:2" "————:3" "🔥🔥🔥:4"; do
  text="${spec%:*}"; width="${spec#*:}"
  broken=0; over=0
  for n in $(seq 1 12); do
    got="$(printf '%s' "$text" | clip_utf8 "$n")"
    valid "$got" || broken=$((broken + 1))
    [ "$(bytes "$got")" -le "$n" ] || over=$((over + 1))
  done
  [ "$broken" = 0 ] && ok "$width-byte characters survive every limit from 1 to 12" \
                    || bad "$width-byte characters: $broken limits produced invalid UTF-8"
  [ "$over" = 0 ] && ok "$width-byte characters: the byte budget is never exceeded" \
                  || bad "$width-byte characters: $over limits went over budget"
done

# The whole point of a byte budget: it stays a byte budget. A character limit would have tripled
# the prompt for a Ukrainian task without anyone deciding to.
GOT="$(printf '%s' "$(printf 'Ж%.0s' $(seq 1 100))" | clip_utf8 50)"
[ "$(bytes "$GOT")" = 50 ] && ok "a 50-byte budget returns 50 bytes, not 50 characters" \
                           || bad "50-byte budget returned $(bytes "$GOT") bytes"

# ASCII is untouched, and text already inside the budget comes back whole.
[ "$(printf 'hello' | clip_utf8 100)" = "hello" ] && ok "text inside the budget is returned whole" \
                                                  || bad "short text was altered"
[ "$(printf 'hello' | clip_utf8 3)" = "hel" ] && ok "ASCII still cuts exactly at the budget" \
                                              || bad "ASCII cut wrongly"
[ -z "$(printf '' | clip_utf8 100)" ] && ok "empty input stays empty" || bad "empty input grew"

echo "===== every prompt the engine builds decodes as UTF-8 ====="
# The site that actually fired: an alignment file whose byte 1200 lands mid-character.
PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
printf 'one\n' > "$PROJ/a.txt"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm base
PROJ="$(canon_path "$PROJ")"

IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf '%s\n' "utf8-test-run" > "$IDIR/run-id"

# 1199 bytes of ASCII, then a Cyrillic letter: byte 1200 is its first half.
{ printf 'a%.0s' $(seq 1 1199); printf 'Ж'; printf 'решта тексту після межі\n'; } > "$IDIR/peer-alignment.md"

# The objective and the new message are clipped too, so both get a character on their own limit:
# 1500 for the objective, 2000 for the message.
OBJ="$(printf 'о%.0s' $(seq 1 749))Ж дальше"          # 1499 bytes, then a two-byte letter
MSG="$(printf 'м%.0s' $(seq 1 999))Ж дальше"          # 1999 bytes, then a two-byte letter
thread_bind "$IDIR" "$OBJ" msg-1 1 new >/dev/null 2>&1

BRIEF="$(thread_brief "$IDIR" "$PROJ" "$MSG" 2>/dev/null)"
if [ -z "$BRIEF" ]; then
  bad "thread_brief produced nothing — the fixture did not take"
else
  valid "$BRIEF" && ok "the brief decodes as UTF-8 with a character straddling all three limits" \
                 || bad "the brief is not valid UTF-8 — a limit still cuts a character in half"
  case "$BRIEF" in
    *"Звірена позиція"*) ok "and it still carries the alignment it was clipping" ;;
    *) bad "the alignment section is missing from the brief" ;;
  esac
fi

# The degraded note, the journal's question field, and the context files preflight assembles.
printf '%s' "$(printf 'д%.0s' $(seq 1 299))Ж хвіст" > "$IDIR/degraded.md"
valid "$(clip_utf8 600 < "$IDIR/degraded.md")" && ok "the degraded note survives its 600-byte limit" \
                                               || bad "degraded.md is cut mid-character"

CTX="$TMP/context.md"; { printf 'к%.0s' $(seq 1 2999); printf 'Ж хвіст'; } > "$CTX"
valid "$(clip_utf8 6000 < "$CTX")" && ok "the chat context survives its 6000-byte limit" \
                                   || bad "the chat context is cut mid-character"

echo "===== the journal records the question that was asked, not a replacement character ====="
# The same clip feeds `jq --arg` in `journal_event` and in the consultation record. jq does not
# refuse a half-character — it writes U+FFFD in its place and exits 0 — so a byte-cut question
# ends up on the record as a question nobody asked, with nothing anywhere saying so.
FFFD="$(printf '\357\277\275')"     # U+FFFD, written in bytes: /bin/bash here is 3.2 and has no \u
# 398 bytes of two-byte letters, then a THREE-byte dash — so byte 400 is the middle of it, which
# is the shape `head -c 400` was producing on a Ukrainian question.
ASKED="$(printf 'п%.0s' $(seq 1 199))— хвіст"
Q="$(printf '%s' "$ASKED" | clip_utf8 400)"
BACK="$(jq -nr --arg q "$Q" '$q' 2>/dev/null)"
[ "$BACK" = "$Q" ] && ok "a clipped question survives jq --arg byte for byte" \
                   || bad "jq altered the clipped question"
case "$BACK" in *"$FFFD"*) bad "the record carries a replacement character" ;;
                *) ok "and carries no replacement character" ;; esac
# `journal_event` writes JSON, which is where it shows: the same 400 bytes taken with `head -c`
# come out of jq as a replacement character, on a line that exits 0 and looks written.
WAS="$(printf '%s' "$ASKED" | head -c 400)"
printf '%s' "$WAS" | text_is_utf8 && bad "the fixture does not actually split a character" \
                                  || ok "the old byte-cut leaves two thirds of a dash behind"
case "$(jq -nc --arg q "$WAS" '{question:$q}' 2>/dev/null)" in
  *"$FFFD"*) ok "and the old byte-cut is what put a replacement character there" ;;
  '')           ok "and the old byte-cut made jq refuse the line outright" ;;
  *)            ok "(this jq encodes the old byte-cut without complaint)" ;;
esac
case "$(jq -nc --arg q "$Q" '{question:$q}' 2>/dev/null)" in
  *"$FFFD"*) bad "the CLIPPED question still encodes to a replacement character" ;;
  '')           bad "jq refused the clipped question" ;;
  *)            ok "while the clipped one encodes to JSON cleanly" ;;
esac

echo "===== the gate accepts every character there is, and only those ====="
# Two gates were tried before this one and both refused text that is perfectly good. `iconv` is
# described where the helper is defined; `Encode` with FB_CROAK refuses U+FDD0, U+FFFE and
# U+10FFFF. The rule has to be the one the CLI on the other side applies — every scalar value,
# minus surrogates, minus overlong encodings, minus anything past U+10FFFF.
for spec in "U+FDD0 noncharacter:\357\267\220:yes" \
            "U+FFFE noncharacter:\357\277\276:yes" \
            "U+10FFFF, the last character:\364\217\277\277:yes" \
            "past U+10FFFF:\365\200\200\200:no" \
            "a lone surrogate:\355\240\200:no" \
            "an overlong NUL:\300\200:no" \
            "an overlong three-byte form:\340\200\200:no" \
            "a stray continuation byte:\200:no"; do
  name="${spec%%:*}"; rest="${spec#*:}"; seq_="${rest%:*}"; want="${rest##*:}"
  if printf "$seq_" | text_is_utf8; then got=yes; else got=no; fi
  [ "$got" = "$want" ] && ok "$name: $( [ "$want" = yes ] && echo accepted || echo refused )" \
                       || bad "$name: expected $want, got $got"
done

echo "===== the gate answers about a real prompt, not just a short one ====="
# The first gate here used `iconv -f UTF-8 -t UTF-8 >/dev/null`, which passes every short fixture
# and then refuses a real six-kilobyte Ukrainian prompt with "Inappropriate ioctl for device" —
# a gate that turns "Codex refuses broken text" into "Codex never runs on a Ukrainian task".
BIG="$(printf 'Це довге українське питання з переносами, тире — і емодзі 🔥. %.0s' $(seq 1 120))"
[ "$(printf '%s' "$BIG" | wc -c | tr -d ' ')" -gt 6000 ] \
  && ok "the fixture is a realistic prompt size ($(printf '%s' "$BIG" | wc -c | tr -d ' ') bytes)" \
  || bad "the fixture is too small to be the case that broke"
printf '%s' "$BIG" | text_is_utf8 && ok "and the gate lets it through" \
                                  || bad "the gate refused a valid multi-kilobyte prompt"
# Broken bytes in the middle of a long text are still caught.
printf '%s\244\245%s' "$BIG" "$BIG" | text_is_utf8 \
  && bad "broken bytes inside a long text got through" \
  || ok "and still catches broken bytes buried in the middle of one"
# The encodings Rust refuses on the other side, which a lenient decoder would wave through.
printf 'a\300\200b' | text_is_utf8 && bad "an overlong encoding got through" \
                                    || ok "an overlong encoding is refused"
printf 'a\355\240\200b' | text_is_utf8 && bad "a surrogate got through" \
                                          || ok "a lone surrogate is refused"

echo "===== already-broken text is refused locally, not by an argument parser ====="
printf 'abc\xd0' | text_is_utf8 && bad "text_is_utf8 accepted a truncated character" \
                                || ok "text_is_utf8 refuses a truncated character"
printf 'слова' | text_is_utf8 && ok "and accepts ordinary Cyrillic" \
                              || bad "text_is_utf8 refused valid text"

echo "===== the diagnostic keeps the reason, not the usage block after it ====="
# Exactly what clap prints when it refuses an argument, in exactly that order.
LOGF="$TMP/peer-codex.log"
cat > "$LOGF" <<'CLAP'
error: invalid UTF-8 was detected in one or more arguments

Usage: codex exec [OPTIONS] <COMMAND> [ARGS]...

For more information, try '--help'.
CLAP

NOTE="$(
  ART="$TMP" IDIR="$IDIR" LOG="$TMP/sup.log"
  # The function as preflight defines it, read out of the file so the test cannot drift from it.
  eval "$(awk '/^peer_stderr_note\(\)/,/^}/' "$BIN/preflight.sh")"
  peer_stderr_note "$LOGF"
)"
case "$NOTE" in
  *"invalid UTF-8"*) ok "the reason survives: «${NOTE}»" ;;
  *) bad "the reason was dropped; what reached the reader was: «${NOTE:-<nothing>}»" ;;
esac
case "$NOTE" in
  *"For more information"*|*"Usage:"*) bad "the usage block is still being quoted as the reason" ;;
  *) ok "and the usage block is not quoted in its place" ;;
esac

# A CLI that prints a bare label and puts the sentence on the next line still gets quoted with
# the sentence, not with the label.
printf 'error:\n  the actual cause was this\n\nUsage: codex exec [OPTIONS]\n' > "$LOGF"
NOTE="$(
  ART="$TMP" IDIR="$IDIR" LOG="$TMP/sup.log"
  eval "$(awk '/^peer_stderr_note\(\)/,/^}/' "$BIN/preflight.sh")"
  peer_stderr_note "$LOGF"
)"
case "$NOTE" in
  *"the actual cause was this"*) ok "a cause on the next line is kept too" ;;
  *) bad "the cause on the following line was dropped: «${NOTE:-<nothing>}»" ;;
esac

# Anything that does NOT announce itself with a cause word still comes through, as before.
printf 'something odd happened\nand then it stopped\n' > "$LOGF"
NOTE="$(
  ART="$TMP" IDIR="$IDIR" LOG="$TMP/sup.log"
  eval "$(awk '/^peer_stderr_note\(\)/,/^}/' "$BIN/preflight.sh")"
  peer_stderr_note "$LOGF"
)"
case "$NOTE" in
  *"and then it stopped"*) ok "an ordinary failure still shows its last words" ;;
  *) bad "an ordinary failure lost its note: «${NOTE:-<nothing>}»" ;;
esac

echo
[ "$fails" = 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
