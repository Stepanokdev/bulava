#!/bin/bash
# The worker narrates in the language the director reads.
#
# The report has been in his language for months; the running commentary was not, because nobody
# read it — it lived in a terminal nobody was watching. The app puts that commentary on screen now,
# and the first real session he was happy with narrated itself in English inside a Ukrainian
# interface: "I'll start by scouting the current state of the variants."
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

echo "===== the rule names the director's chosen language ====="

for lang in Ukrainian English Russian; do
  out="$(SUPERVISOR_REPORT_LANGUAGE="$lang" worker_language_rule)"
  case "$out" in
    *"$lang"*) ok "carries $lang" ;;
    *) bad "the rule never mentions $lang" ;;
  esac
done

out="$(unset SUPERVISOR_REPORT_LANGUAGE; worker_language_rule)"
case "$out" in
  *Ukrainian*) ok "falls back to the engine's default" ;;
  *) bad "no language at all when the choice is unset" ;;
esac

echo
echo "===== and it spares what must not be translated ====="
out="$(SUPERVISOR_REPORT_LANGUAGE=Ukrainian worker_language_rule)"
missing=0
for kept in "Код" "команди" "комітів"; do
  case "$out" in *"$kept"*) ;; *) missing=$((missing+1));; esac
done
[ "$missing" = 0 ] && ok "code, commands and commit messages are left alone" \
                   || bad "$missing of the do-not-translate cases are unstated"

echo
echo "===== both launch paths inject it ====="
n="$(grep -c 'worker_language_rule' "$BIN_DIR/night-shift.sh" || true)"
if [ "${n:-0}" -ge 2 ]; then
  ok "start and resume both carry the rule ($n sites)"
else
  bad "only ${n:-0} launch path(s) tell the worker which language to speak"
fi

echo
[ "$fails" = 0 ] && echo "✅ the worker speaks his language" || echo "❌ $fails problem(s)"
exit "$fails"
