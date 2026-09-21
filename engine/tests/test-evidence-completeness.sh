#!/bin/bash
# Every registered check reaches the evidence, or the report is a lie by omission.
#
# One did not. The verifier reads `checks.jsonl` from stdin, and one of the registered checks ran
# `ssh`, which drains stdin when it is not handed `-n`. It swallowed the rest of the file: every
# check registered after it was never run and never recorded. Not failed, not skipped — absent.
# The evidence came out looking complete, and the one check that would have proved the work was
# the one missing from it.
#
# The second half is smaller and the same shape: a criterion written in Ukrainian has no ASCII, so
# its log was named `.log` — hidden, and shared with the next such criterion, which overwrote it.
# A reviewer judging by logs cannot judge one that another check has written over.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

echo "===== a check that drains stdin does not swallow the ones behind it ====="
# The exact shape of the loop in verify.sh, with the fix it now carries: the file is read up front
# and every step runs with its stdin closed.
probe="$(mktemp -d)"
printf 'one\ntwo\nthree\nfour\n' > "$probe/lines"
seen=0
_lines=()
while IFS= read -r _l; do _lines+=("$_l"); done < "$probe/lines"
for l in ${_lines[@]+"${_lines[@]}"}; do
  seen=$((seen + 1))
  # A step that reads everything it is given — ssh, cat, anything unfussy about stdin.
  ( cat > /dev/null ) </dev/null
done
[ "$seen" = 4 ] && ok "all four survive a step that would otherwise eat them" \
  || bad "only $seen of 4 were seen — the loop still loses work to a greedy step"

# And the unfixed shape, to show the test is asking a real question.
seen=0
while IFS= read -r l; do seen=$((seen + 1)); cat > /dev/null; done < "$probe/lines"
[ "$seen" -lt 4 ] && ok "…while the old shape demonstrably loses them ($seen of 4)" \
  || bad "the old shape did not lose anything — this test proves nothing"
rm -rf "$probe"

echo
echo "===== verify.sh actually carries that shape ====="
grep -q '</dev/null; ec=\$?' "$BIN/verify.sh" \
  && ok "each step runs with its stdin closed" \
  || bad "a step can still read the caller's stdin"
# The file may be read from stdin ONCE, to fill an array. What must not happen is the loop that
# RUNS the steps being fed from it, because that is the stdin a step can drink.
streaming="$(grep -c 'done < "\$CHECKS_FILE"' "$BIN/verify.sh")"
prereads="$(grep -c '_lines+=.*done < "\$CHECKS_FILE"' "$BIN/verify.sh")"
[ "$streaming" = "$prereads" ] \
  && ok "and the registered checks are read into memory before any of them runs" \
  || bad "a loop that runs steps is still fed from the checks file ($streaming reads, $prereads of them harmless)"

echo
echo "===== every criterion gets a log of its own, whatever language it is in ====="
slugify() { bash -c "$(sed -n '/^slugify(){/,/^}/p' "$BIN/verify.sh"); slugify \"\$1\"" _ "$1"; }
a="$(slugify 'запобіжники публікації відмовляють у кожному випадку')"
b="$(slugify 'живий сайт віддає нову версію і фід з нею згоден')"
c="$(slugify 'app builds')"
[ -n "$a" ] && [ "${#a}" -ge 3 ] && ok "a criterion with no ASCII still gets a name ($a)" \
  || bad "it slugifies to '$a' — a hidden file, or none"
[ "$a" != "$b" ] && ok "and two of them do not share one log" \
  || bad "two different criteria both write to '$a'"
[ "$c" = "app-builds" ] && ok "…while an English one is still named after itself" \
  || bad "the readable case regressed: '$c'"

echo
[ "$fails" = 0 ] && { echo "✅ evidence completeness: nothing registered can vanish"; exit 0; }
echo "❌ evidence completeness: $fails failure(s)"; exit 1
