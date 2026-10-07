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

echo "===== the worker answers in the language the person writes in ====="
out="$(SUPERVISOR_REPORT_LANGUAGE=Ukrainian worker_language_rule)"
case "$out" in
  *"the language they write to you in"*"their own words"*) ok "the person's own words decide the language" ;;
  *) bad "the rule does not follow the person's language" ;;
esac
case "$out" in
  *"Text they paste"*"does not count"*) ok "a pasted log or error in another language does not switch it" ;;
  *) bad "pasted text could decide the language" ;;
esac
case "$out" in
  *"neither do the instructions around their words"*) ok "nor do the engine's and the app's own notes" ;;
  *) bad "the instructions' language could decide the answer's" ;;
esac
case "$out" in
  *"sends on their behalf"*"is not their words either"*) ok "nor does a message the app sends for them" ;;
  *) bad "an app-sent message could decide the language" ;;
esac
case "$out" in
  *"мовою: Ukrainian"*|*"must be in Ukrainian"*) bad "it still fixes the answer to one language" ;;
  *) ok "no language is fixed for the answer" ;;
esac

echo
echo "===== the setting is only where it starts ====="
for lang in Ukrainian English Russian; do
  out="$(SUPERVISOR_REPORT_LANGUAGE="$lang" worker_language_rule)"
  case "$out" in
    *"before there is any,"*"use $lang."*) ok "$lang, until the person has written" ;;
    *) bad "the rule never mentions $lang as the start" ;;
  esac
done
out="$(unset SUPERVISOR_REPORT_LANGUAGE; worker_language_rule)"
case "$out" in
  *"before there is any,"*"use "*) ok "falls back to the engine's default" ;;
  *) bad "no language at all when the choice is unset" ;;
esac

echo
echo "===== and it spares what must not be translated ====="
missing=0
for kept in "Code" "commands" "commit messages"; do
  case "$out" in *"$kept"*) ;; *) missing=$((missing+1));; esac
done
[ "$missing" = 0 ] && ok "code, commands and commit messages are left alone" \
                   || bad "$missing of the do-not-translate cases are unstated"

echo
echo "===== every message says it again ====="
TMPI="$(mktemp -d)"; trap 'rm -rf "$TMPI"' EXIT
task_out="$(compose_task_prompt "$TMPI" "Why does the export button stay grey?" 2>/dev/null)"
case "$task_out" in
  *"[LANGUAGE] The person wrote the task above in English. Answer in English"*) ok "the composed message ends with it, naming English" ;;
  *) bad "a message reaches the worker without its language named" ;;
esac
for pair in "Russian|Почему кнопка экспорта серая после записи?" "Ukrainian|Чому кнопка експорту сіра після запису?" \
            "Ukrainian|Глянь, чому вона сіра:
Attached files are available at these paths:
- export.png: /Users/me/Library/Application Support/Bulava/export.png"; do
  want="${pair%%|*}"; msg="${pair#*|}"
  line="$(task_language_line "$msg")"
  case "$line" in *"wrote the task above in $want. Answer in $want"*) ok "$want is named for «${msg:0:24}…»" ;;
    *) bad "$want was not named for «${msg:0:24}…»: $line" ;; esac
done
line="$(task_language_line "[BULAVA] The app asks for a report on the work already done.")"
case "$line" in *"from the app, not from the person"*"the person has been writing to you in"*)
  ok "a message the app wrote keeps the person's language, not its own" ;;
  *) bad "the app's own words were taken for the person's" ;; esac
line="$(task_language_line "https://example.com/issue/42")"
case "$line" in *"wrote the task above in"*) bad "a bare link was given a language" ;;
  *) ok "a message with no words of the person's names none" ;; esac

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
