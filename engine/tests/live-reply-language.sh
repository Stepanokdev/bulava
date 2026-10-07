#!/bin/bash
# LIVE: does a worker answer in the language the person writes in? Calls Claude (Haiku) three times.
#
# Someone who wrote to Bulava in English or Russian was answered in Ukrainian. This puts together
# what a chat's worker really gets — STANDARDS.md, the language rule with Ukrainian as the start, a
# chat context in Russian as the app writes it — and the real composed message, with all its
# Ukrainian notes, around one question in each of the three languages, and reads the language of
# each answer. A rule that only says "follow the person's language" failed exactly this: the
# notes outweighed a line of English. Exit code = answers in the wrong language.
set -u
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ENGINE/bin/supervisor-lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ cat "$ENGINE/supervisor/STANDARDS.md"; SUPERVISOR_REPORT_LANGUAGE=Ukrainian worker_language_rule
  printf '\n# APP CHAT CONTEXT\nТы работаешь в обычном долгоживущем диалоге Night Shift, который показан через приложение Bulava.\n'; } > "$T/system.md"
fails=0
ask() {  # $1=expected code $2=message
  local prompt reply got
  prompt="$(compose_task_prompt "$T" "$2" 2>/dev/null)"
  reply="$(printf '%s' "$prompt" | env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN claude -p --model haiku \
            --append-system-prompt-file "$T/system.md" --tools '' --strict-mcp-config 2>/dev/null)"
  got="$(printf '%s' "$reply" | python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import language; print(language.of_text(sys.stdin.read(), "", "?"))' "$ENGINE/bin")"
  printf '%s → %s (wanted %s): %s\n' "${2:0:40}" "$got" "$1" "$(printf '%s' "$reply" | tr '\n' ' ' | cut -c1-140)"
  [ "$got" = "$1" ] || fails=$((fails + 1))
}
ask en "Why would an export button stay grey after a recording finishes? Two sentences, no code."
ask ru "Почему кнопка экспорта может оставаться серой после окончания записи? Два предложения, без кода."
ask uk "Чому кнопка експорту може лишатися сірою після завершення запису? Два речення, без коду."
exit "$fails"
