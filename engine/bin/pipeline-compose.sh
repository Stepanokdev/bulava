#!/bin/bash
# Stage: turn the director's message into the prompt the worker actually receives.
#
# Composition reads the artifacts of THIS message — never the instance's shared copies — so a
# second message cannot be handed the first one's reasoning while it waits its turn.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

ART=""
while [ $# -gt 0 ]; do
  case "${1:-}" in --art) ART="${2:-}"; shift 2 ;; *) break ;; esac
done
PROJ="${1:?usage: pipeline-compose.sh --art DIR <project> <task...>}"; shift
TASK="$*"
IDIR="${PIPE_IDIR:?pipeline-compose.sh runs as a pipeline stage}"
[ -n "$ART" ] || ART="${PIPE_ART:-$IDIR}"
run_env_load "$IDIR"

compose_task_prompt "$IDIR" "$TASK" "$ART" > "$ART/composed.txt.tmp" 2>/dev/null \
  && mv -f "$ART/composed.txt.tmp" "$ART/composed.txt" \
  || { rm -f "$ART/composed.txt.tmp" 2>/dev/null
       printf '%s\n' "$TASK" > "$ART/composed.txt"
       echo "$(date '+%F %T') [pipeline] compose failed — falling back to the original message" >> "$SUP_STATE/supervisor.log"; }
[ -s "$ART/composed.txt" ] || printf '%s\n' "$TASK" > "$ART/composed.txt"

# What the pipeline itself adds. Its own text goes AFTER the standard sections and never in place of
# them: proof and the outcome protocol are what lets the gate judge the work, and a description
# shared from somebody else's repository must not be able to talk them away.
COMPILED="$ART/pipeline.compiled.json"
if [ -s "$COMPILED" ]; then
  {
    _name="$(jq -r '.name // ""' "$COMPILED" 2>/dev/null)"
    _extra="$(jq -r '.brief.extra // empty' "$COMPILED" 2>/dev/null)"
    if [ -n "$_extra" ] && [ -s "$_extra" ]; then
      printf '\n[ПАЙПЛАЙН «%s»]\n' "$_name"
      clip_utf8 12000 < "$_extra" 2>/dev/null || head -c 12000 "$_extra"
      printf '\n'
    fi
    if [ "$(jq -r '.brief.research // false' "$COMPILED" 2>/dev/null)" = true ]; then
      printf '\n[ДОСЛІДЖЕННЯ] Результат цієї задачі — звіт, а не зміни коду. Код продукту не змінюй; звіт поклади в artifacts/ (HTML або Markdown). Коли він готовий, заяви результат succeeded_research і назви в підсумку шлях до звіту — Codex перевірятиме саме його зміст.\n'
    fi
    # A role pipeline: the agreement is the plan above; each role's own result is named here so the
    # implementer can go back to the analysis, the test cases and both architectures themselves.
    if [ "$(jq -r '.brief.roles | length' "$COMPILED" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
      printf '\n[РОЛІ ПІДГОТОВКИ] Узгоджене рішення ролей — у плані вище (%s). Результати кожної ролі:\n' "$ART/peer-alignment.md"
      jq -r '.brief.roles[] | "\(.id)\t\(.title)\t\(.engine)"' "$COMPILED" 2>/dev/null | while IFS="$(printf '\t')" read -r _rid _rt _re; do
        if [ -s "$ART/role-$_rid.md" ]; then printf -- '- %s (%s): %s\n' "$_rt" "$_re" "$ART/role-$_rid.md"
        else printf -- '- %s (%s): результату немає — %s\n' "$_rt" "$_re" "$(cat "$ART/role-$_rid.unavailable" 2>/dev/null || echo "причина невідома")"; fi
      done
      printf 'Тест-кейси з узгодженого рішення — це критерії готовності: перед завершенням перевір кожен і назви в підсумку, як. Якщо не згоден з узгодженим рішенням, скажи це першим рядком і поясни, перш ніж відходити від нього. Codex перевірятиме роботу саме проти цього рішення.\n'
    fi
    _skills="$(jq -r '.brief.skills[]? // empty' "$COMPILED" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    if [ -n "$_skills" ]; then
      printf '\n[ОБОВ'"'"'ЯЗКОВІ СКІЛИ] Перед роботою виклич і застосуй: %s. Ворота шукатимуть виклик Skill у транскрипті цієї сесії; без нього робота повернеться.\n' "$_skills"
    fi
  } >> "$ART/composed.txt" 2>/dev/null || true
fi
exit 0
