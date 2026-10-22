#!/bin/bash
# The BSD spellings the engine is written in mean the same thing on GNU systems (lib/portable.sh).
#
# On macOS the layer must define nothing at all — the app's path stays exactly what it was. On
# Linux and WSL2 each translated call must give the answer macOS would.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

case "${OSTYPE:-}" in
  darwin*)
    echo "===== macOS: nothing is redefined ====="
    for f in stat date mktemp ps cut; do
      [ "$(type -t "$f")" = file ] && ok "$f is the system's own" || bad "$f is shadowed by a $(type -t "$f")"
    done
    printf '\n%s\n' "failures: $fails"; [ "$fails" -eq 0 ]; exit
    ;;
esac

echo "===== stat ====="
f="$TMP/file"; printf 'hello' > "$f"; touch -t 202401020304.05 "$f"   # POSIX local time; uutils' touch -d reads it as UTC
want="$(command stat -c %Y "$f")"
[ "$(stat -f %m "$f")" = "$want" ] && ok "stat -f %m is the mtime" || bad "stat -f %m → $(stat -f %m "$f")"
[ "$(stat -L -f %m "$f")" = "$want" ] && ok "stat -L -f %m too" || bad "stat -L -f %m"
[ "$(stat -f %z "$f")" = 5 ] && ok "stat -f %z is the size" || bad "stat -f %z → $(stat -f %z "$f")"
out="$(stat -f %m "$TMP/missing" 2>/dev/null || echo 0)"
[ "$out" = 0 ] && ok "a missing file fails, so '|| echo 0' fires cleanly" || bad "missing file printed: $out"
[ "$(stat -c %s "$f")" = 5 ] && ok "GNU spellings pass straight through" || bad "stat -c broken"
age=$(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo 0) ))
[ "$age" -gt 0 ] && ok "the engine's age arithmetic works" || bad "age=$age"

echo "===== date ====="
[ "$(date -r 0 '+%Y' 2>/dev/null)" = "$(command date -d @0 '+%Y')" ] && ok "date -r <epoch>" || bad "date -r 0 → $(date -r 0 '+%Y')"
[ "$(date -r "$f" '+%Y-%m-%d')" = 2024-01-02 ] && ok "date -r <file> still means the file" || bad "date -r file"
[ "$(date -j -f '%Y-%m-%d %H:%M:%S' '2024-01-02 03:04:05' +%s)" = "$want" ] && ok "date -j -f parses" || bad "date -j -f"
h="$(date -v-3H '+%s')"; now="$(command date +%s)"
[ $(( now - h )) -ge 10790 ] && [ $(( now - h )) -le 10810 ] && ok "date -v-3H" || bad "date -v-3H off by $(( now - h ))"
d="$(date -v-1d '+%s')"; [ $(( now - d )) -ge 86390 ] && ok "date -v-1d" || bad "date -v-1d"

echo "===== mktemp, ps, shasum ====="
t="$(mktemp -t bulava-test)" && [ -f "$t" ] && ok "mktemp -t name" || bad "mktemp -t"; rm -f "$t"
t="$(mktemp -d "$TMP/x.XXXXXX")" && [ -d "$t" ] && ok "mktemp with a template" || bad "mktemp template"
ps -ax -ww -o pid=,command= 2>&1 | grep -q "$$" && ok "ps -ax lists this shell" || bad "ps -ax"
[ "$(printf abc | shasum | cut -c1-8)" = a9993e36 ] && ok "shasum (sha1)" || bad "shasum"
[ "$(printf abc | shasum -a 256 | cut -c1-8)" = ba7816bf ] && ok "shasum -a 256" || bad "shasum -a 256"

echo "===== cut -c counts characters ====="
[ "$(printf 'абвгд' | cut -c1-3)" = "абв" ] && ok "cut -c1-N on Cyrillic is N letters" || bad "cut -c1-3 → $(printf 'абвгд' | cut -c1-3 | od -An -tx1)"
[ "$(printf 'Сесію Claude Code перезапущено: попередній хід завис' | LC_ALL=en_US.UTF-8 cut -c1-38 | iconv -f UTF-8 -t UTF-8 2>/dev/null)" = "Сесію Claude Code перезапущено: попере" ] \
  && ok "a needle cut from a Ukrainian prompt is whole letters" || bad "the needle was cut inside a letter"
[ "$(printf 'один\nдва\n' | cut -c1-2)" = "$(printf 'од\nдв')" ] && ok "line by line, like cut" || bad "lines were not cut one by one"
[ "$(printf 'abcdef' | cut -c1-4)" = abcd ] && ok "ASCII is unchanged" || bad "ASCII cut broken"
[ "$(printf 'a:b:c' | cut -d: -f2)" = b ] && ok "other spellings go to the real cut" || bad "cut -d -f broken"

echo "===== find -depth N ====="
mkdir -p "$TMP/w/a/b/c" "$TMP/w/x"
got="$(find -P "$TMP/w" -xdev -mindepth 1 -maxdepth 3 \( -type d -depth 3 \) -print 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$got" = "$TMP/w/a/b/c" ] && ok "only the directory exactly 3 levels down" || bad "rc=$rc got: $got"
got="$(find "$TMP/w" -depth -name x 2>&1)"
[ "$got" = "$TMP/w/x" ] && ok "GNU's own -depth (no number) is left alone" || bad "plain -depth: $got"

echo "===== the slug matches macOS's ====="
# The app recomputes this slug in Swift; the same folder must get the same instance on both.
[ "$(slug_for /tmp)" = "tmp-$(printf '%s' "$(cd /tmp && pwd -P)" | shasum | cut -c1-12)" ] \
  && ok "slug_for uses the same hash" || bad "slug_for → $(slug_for /tmp)"

echo "===== locks take over a dead holder ====="
L="$SUPERVISOR_STATE_DIR/locks/t"; mkdir -p "$L"; echo 999999 > "$L/pid"
_take_lock "$L" && ok "_take_lock (stat -f %m inside)" || bad "_take_lock"

printf '\n%s\n' "failures: $fails"
[ "$fails" -eq 0 ]
