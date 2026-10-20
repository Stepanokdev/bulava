#!/bin/bash
# Stage: Codex writes its part of the change, and Claude applies it.
#
# A pipeline step «Codex робить частину» — the designer, most often: the director wants the design
# made by Codex and the logic by Claude. Codex reads the brief Claude is about to receive (the plan,
# the test cases, the roles' results) and the step's own prompt, and answers with its part as a
# unified diff. It runs read-only, as every other Codex step in the engine does: the diff is
# checked here with `git apply --check`, and Claude — the one session in the run that changes files,
# inside its scope gate — applies it, builds on it and answers for it in the review.
#
#   pipeline-codex-part.sh --node ID --title TITLE [--prompt FILE] --art DIR <project> <task...>
#
# Exit 0: a patch that applies cleanly, named in the brief. Non-zero: no usable patch; the reason is
# in .unavailable-<stage>, and whether the run stops is the step's "required" flag, as for any step.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

NODE=""; TITLE=""; PROMPT_FILE=""; ART=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --node)   NODE="${2:-}"; shift 2 ;;
    --title)  TITLE="${2:-}"; shift 2 ;;
    --prompt) PROMPT_FILE="${2:-}"; shift 2 ;;
    --art)    ART="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
PROJ="${1:?usage: pipeline-codex-part.sh --node ID --title T [--prompt F] --art DIR <project> <task...>}"; shift
TASK="$*"
IDIR="${PIPE_IDIR:?pipeline-codex-part.sh runs as a pipeline stage}"
[ -n "$ART" ] || ART="${PIPE_ART:-$IDIR}"
[ -n "$NODE" ] || NODE="${PIPE_STAGE:-codex-part}"
[ -n "$TITLE" ] || TITLE="$NODE"
STAGE="${PIPE_STAGE:-$NODE}"
run_env_load "$IDIR"
LOG="$SUP_STATE/supervisor.log"
CODEX_BIN="${SUPERVISOR_CODEX_BIN:-codex}"
TIMEOUT="${SUPERVISOR_CODEX_PART_TIMEOUT:-1800}"
strip_paid_api_env "$LOG" >/dev/null 2>&1 || true
unset OPENAI_API_KEY CODEX_API_KEY 2>/dev/null || true
plog() { printf '%s [pipeline/codex-part %s] %s\n' "$(date '+%F %T')" "$NODE" "$*" >> "$LOG" 2>/dev/null || true; }

unavailable() {   # $1 = why, in his words
  printf '%s\n' "$1" > "$ART/.unavailable-$STAGE" 2>/dev/null || true
  plog "no patch — $1"
  exit 1
}

if codex_signed_out "$CODEX_BIN"; then
  unavailable "Codex не авторизований — «${TITLE}» не підготовлено; Claude робить задачу повністю."
fi
state_line="$(provider_state codex)"
if [ "${state_line%% *}" = exhausted ]; then
  unavailable "Codex недоступний зараз ($(provider_unavailable_note codex)) — «${TITLE}» не підготовлено; Claude робить задачу повністю."
fi

# The step's own prompt — what this part is — with the task substituted; the engine's default when
# the step has none.
pf="$PROMPT_FILE"
[ -n "$pf" ] && [ -s "$pf" ] || pf="$ROOT/supervisor/prompts/codex-part.md"
part="$(TASK="$TASK" TITLE="$TITLE" perl -0777 -pe 'for my $k (qw(TASK TITLE)) { my $v = $ENV{$k} // ""; s/\Q{{$k}}\E/$v/g; }' "$pf" 2>/dev/null)"
# The brief normally exists — the compiler puts this step after the composition. If it does not, it
# is started from his words, so the worker is never handed Codex's note in place of the task.
[ -s "$ART/composed.txt" ] || printf '%s\n' "$TASK" > "$ART/composed.txt" 2>/dev/null \
  || unavailable "Не вдалося записати бриф у $ART — «${TITLE}» не підготовлено."
brief="$(clip_utf8 30000 < "$ART/composed.txt" 2>/dev/null || true)"
prompt="You are Codex, writing one part of a change before Claude does the rest. Your part is «${TITLE}».

YOUR PART
$part

THE BRIEF CLAUDE WILL BE HANDED AFTER YOU (the plan, the test cases, everything agreed — context
for your part; do not write Claude's share)
${brief:-$TASK}

THE REPOSITORY
$PROJ, read-only for you. Read what you need: the components, the design tokens, the files you
will change.

WHAT TO ANSWER
Your part as ONE unified diff against the current working tree, the kind \`git apply\` accepts:
'diff --git a/PATH b/PATH' headers, paths relative to the repository root, enough context lines,
new files as '--- /dev/null'. Finished code — not advice, not placeholders. Match what is already
here: components, tokens, naming, comment style. Put the diff between a line '===PATCH===' and a
line '===END===', and after it a short note for Claude: what the change does, file by file, and how
to check it."

printf '%s' "$prompt" | text_is_utf8 || unavailable "Текст для Codex не є коректним UTF-8 — «${TITLE}» не підготовлено."

OUT="$ART/codex-part-$NODE.md"
PATCH="$ART/codex-part-$NODE.patch"
plog "Codex writes «${TITLE}» for $PROJ"
started="$(date +%s)"
( cd "$PROJ" && perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
  "$CODEX_BIN" exec $(codex_effort_flags) --sandbox read-only --skip-git-repo-check --ephemeral --json \
  -o "$OUT.partial" "$prompt" </dev/null > "$ART/codex-part-$NODE.events.jsonl" 2> "$ART/codex-part-$NODE.stderr.log" )
rc=$?; elapsed=$(( $(date +%s) - started ))
if [ "$rc" != 0 ] || [ ! -s "$OUT.partial" ]; then
  rm -f "$OUT.partial" 2>/dev/null || true
  case "$rc" in
    0)   unavailable "Codex завершився, нічого не сказавши" ;;
    142) unavailable "Codex не закінчив «${TITLE}» за ${TIMEOUT}с" ;;
    *)   unavailable "Codex зупинився з помилкою (код $rc) через ${elapsed}с" ;;
  esac
fi
mv -f "$OUT.partial" "$OUT"
awk '/^===PATCH===[[:space:]]*$/ {on=1; next} /^===END===[[:space:]]*$/ {on=0} on' "$OUT" > "$PATCH"
[ -s "$PATCH" ] || { rm -f "$PATCH"; unavailable "Codex відповів без патча між ===PATCH=== і ===END==="; }
if ! check="$(git -C "$PROJ" apply --check --recount "$PATCH" 2>&1)"; then
  printf '%s\n' "$check" > "$ART/codex-part-$NODE.check.log"
  # A patch that does not apply is still Codex's design; the worker can read it and redo it by hand.
  printf '\n[ЧАСТИНА CODEX «%s» НЕ НАКЛАДАЄТЬСЯ] Патч %s не проходить git apply --check (%s). Прочитай його як дизайн і зроби цю частину сам.\n' \
    "$TITLE" "$PATCH" "$(printf '%s' "$check" | head -2 | tr '\n' ' ' | cut -c1-200)" >> "$ART/composed.txt" 2>/dev/null || true
  unavailable "Патч Codex для «${TITLE}» не накладається на поточну теку"
fi
files="$(grep -E '^diff --git ' "$PATCH" | sed -E 's|^diff --git a/(.*) b/.*$|\1|' | sort -u)"
plog "Codex wrote «${TITLE}» in ${elapsed}s — $(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ') file(s), applies cleanly"
{
  printf '\n[ЧАСТИНА, ЯКУ НАПИСАВ CODEX: «%s»]\n' "$TITLE"
  printf 'Codex підготував цю частину як патч: %s\n' "$PATCH"
  printf 'Файли: %s\n' "$(printf '%s\n' "$files" | sed '/^$/d' | tr '\n' ' ')"
  printf 'Спершу застосуй його (`git -C %s apply --recount %s`), перевір і добудуй решту задачі на ньому. Не переписуй цю частину заново; якщо в ній щось не так — виправ і скажи про це в підсумку. За весь результат відповідаєш ти.\n' "$(printf '%q' "$PROJ")" "$(printf '%q' "$PATCH")"
  printf 'Що Codex каже про свою частину:\n'
  sed -n '/^===END===[[:space:]]*$/,$p' "$OUT" | sed '1d' | clip_utf8 3000 2>/dev/null
  printf '\n'
} >> "$ART/composed.txt" 2>/dev/null || unavailable "Не вдалося дописати бриф — Claude не дізнався б про патч «${TITLE}»."
exit 0
