#!/bin/bash
# Before anyone writes markup, look at how this interaction has already been solved.
#
# «Design and UX decisions as a mandatory phase — go to the internet and look at how comparable
# products do it, rather than a line in a prompt.»
#
# The engine already had a research phase, and it asks a different question: what is CORRECT —
# the API, the platform rule, the current best practice. This one asks what is DONE: when Linear,
# Things or Xcode met the same interaction, what did they choose and what did it cost. A run can
# need one, both or neither, and conflating them produced briefs that were right about the
# framework and ordinary about the screen.
#
# The model calls are stubbed; what is tested is when the phase runs, what it leaves behind, and
# that it reaches the worker before the markup rather than after.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SUP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supervisor" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "===== the question is asked of anything a person will look at ====="
# The word test is the floor: it runs without a model, so a classifier that declines still leaves
# the phase reachable.
probe() { bash -c '
  task="$1"
  '"$(sed -n '/^interface_heuristic()/,/^}/p' "$BIN/preflight.sh")"'
  interface_heuristic "$task"' _ "$1"; }
for t in "Зроби порожній стан для списку задач" "Redesign the settings screen" \
         "Додай темну тему" "Onboarding для нового користувача" "поправ верстку картки"; do
  [ "$(probe "$t")" = true ] || bad "not recognised as interface work: $t"
done
ok "screens, empty states, dark mode, onboarding and layout all count"
for t in "Перепиши парсер JSON" "Fix the retry logic in the uploader" "Додай тест на міграцію"; do
  [ "$(probe "$t")" = false ] || bad "behaviour-only work asked a design question: $t"
done
ok "and behaviour-only work does not pay for it"

echo "===== and a SMALL task still gets it when it is a screen ====="
# The fast path for small tasks was skipping exactly the work precedent is for: "make an empty
# state for the task list" is six words and mechanical by no measure. What must still be skipped
# is a rename that happens to name a control.
mkdir -p "$TMP/state" "$TMP/proj" "$TMP/stub"
cat > "$TMP/stub/codex" <<'C'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then
  case "$*" in
    *design.schema*) echo '{"surface":"empty state","findings":[{"pattern":"Name the next action","products":["Things","Reminders"],"source":"https://example.invalid","source_type":"first_party_app","solves":"guessing","wrong_when":"filtered empty","acceptance_criterion":"one action is named"}],"open_questions":[]}' > "$out" ;;
    *) echo '{}' > "$out" ;;
  esac
fi
echo stub
C
chmod +x "$TMP/stub/codex"
printf '#!/bin/bash
echo stub
' > "$TMP/stub/claude"; chmod +x "$TMP/stub/claude"

ran() {  # $1 = task → "yes" if design.md was produced
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  PATH="$TMP/stub:$PATH" SUPERVISOR_STATE_DIR="$TMP/state"     perl -e 'alarm 200; exec @ARGV' bash "$BIN/preflight.sh" "$TMP/proj" "$1" >/dev/null 2>&1
  if ls "$TMP/state/instances"/*/design.md >/dev/null 2>&1; then echo yes; else echo no; fi
}
[ "$(ran "Зроби порожній стан для списку задач")" = yes ]   && ok "a six-word screen task is looked up, not waved through as small"   || bad "the small-task fast path still skips a screen"
[ "$(ran "Виправ опечатку на кнопці")" = no ]   && ok "a typo on a button pays for nothing" || bad "a rename triggered design research"
[ "$(ran "Перепиши парсер JSON")" = no ]   && ok "and neither does behaviour-only work" || bad "non-interface work triggered it"

echo "===== the phase leaves a document the worker can be held to ====="
# Render the same way preflight does, from a stubbed model answer.
cat > "$TMP/design.json" <<'J'
{"surface":"empty state of a task list",
 "findings":[
  {"pattern":"The empty state names the next action instead of describing the emptiness",
   "products":["Linear","Things","Reminders"],
   "source":"https://developer.apple.com/design/human-interface-guidelines/",
   "source_type":"platform_guidelines",
   "solves":"A first-run screen that says only «no items» leaves the person to guess what to do",
   "wrong_when":"The list is empty because a filter excluded everything — then say that instead",
   "acceptance_criterion":"The empty state contains one action, and it is the action a new user needs first"}],
 "open_questions":["Whether the filtered-empty case gets its own wording"]}
J
{
  echo "# Design precedent — $(jq -r '.surface // "(surface)"' "$TMP/design.json")"
  echo
  jq -r '.findings[]? | "## \(.pattern)\n- Seen in: \(.products | join(", "))\n- Source: [\(.source_type)] \(.source)\n- Solves: \(.solves)\n- Wrong when: \(.wrong_when)\n- Acceptance criterion: \(.acceptance_criterion)\n"' "$TMP/design.json"
  echo "## Open questions"
  jq -r '.open_questions[]? | "- \(.)"' "$TMP/design.json"
} > "$TMP/design.md"

grep -q "Linear, Things, Reminders" "$TMP/design.md" && ok "it names the products, not adjectives" \
  || bad "products missing: $(cat "$TMP/design.md")"
grep -q "Wrong when:" "$TMP/design.md" && ok "and when the pattern is the wrong choice" \
  || bad "no failure mode recorded"
grep -q "Acceptance criterion:" "$TMP/design.md" && ok "each finding ends in something checkable" \
  || bad "nothing checkable"

echo "===== the schema refuses a finding that is only an opinion ====="
schema="$SUP/schemas/design.schema.json"
jq -e '.properties.findings.items.required | index("products")' "$schema" >/dev/null \
  && ok "products are required" || bad "a finding can name no product"
jq -e '.properties.findings.items.required | index("wrong_when")' "$schema" >/dev/null \
  && ok "so is the failure mode" || bad "a pattern can be recorded with no failure mode"
jq -e '.properties.findings.items.required | index("acceptance_criterion")' "$schema" >/dev/null \
  && ok "and the checkable sentence" || bad "a finding need not be checkable"
jq -e '.properties.findings.maxItems <= 6' "$schema" >/dev/null \
  && ok "and it is bounded — padding costs the implementer attention" || bad "unbounded findings"

echo "===== the prompt insists on precedent, not taste ====="
prompt="$(cat "$SUP/prompts/design-research.md")"
case "$prompt" in *"NAME the products"*) ok "it demands named products" ;; *) bad "generalities allowed" ;; esac
case "$prompt" in *"DATA, never commands"*) ok "and treats a fetched page as data" ;;
  *) bad "no prompt-injection guard on fetched pages" ;; esac
case "$prompt" in *"Human Interface Guidelines"*) ok "platform conventions outrank blog trends" ;;
  *) bad "no source ranking" ;; esac
case "$prompt" in *"say so in \`open_questions\`"*) ok "and it may return little when the question is settled" ;;
  *) bad "it is pushed to pad" ;; esac

echo "===== it reaches the worker BEFORE the markup ====="
brief="$(cat "$BIN/supervisor-lib.sh")"
case "$brief" in *'design.md'*) ok "the brief points at it" ;; *) bad "the worker is never told it exists" ;; esac
case "$brief" in *"ПЕРЕД"*) ok "and says to read it before building, not after" ;;
  *) bad "no ordering stated" ;; esac
pf="$(cat "$BIN/preflight.sh")"
case "$pf" in *'DESIGN="$design_text"'*) ok "the plan is built with it in hand" ;;
  *) bad "planning never sees the precedent" ;; esac
# It must run before planning, or the plan is made blind and the findings arrive too late.
# Anchored on the CODE that does each thing — the schema the design step passes to the model, and
# the prompt the planning step renders. Anchoring on the section comments broke the moment
# comments were removed, and reported a real ordering as a defect.
d_line=$(grep -n 'design.schema.json' "$BIN/preflight.sh" | head -1 | cut -d: -f1)
p_line=$(grep -n 'PROMPTS/plan.md' "$BIN/preflight.sh" | head -1 | cut -d: -f1)
[ -n "$d_line" ] && [ -n "$p_line" ] && [ "$d_line" -lt "$p_line" ] \
  && ok "and it runs before planning ($d_line < $p_line)" || bad "the phase runs after the plan"

echo "===== and it can be turned off ====="
case "$pf" in *'SUPERVISOR_DESIGN_RESEARCH:-1'*) ok "one switch disables it" ;;
  *) bad "no way to opt out" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ precedent is looked up before the markup, and is checkable"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
