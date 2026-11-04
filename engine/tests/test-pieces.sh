#!/bin/bash
# A long project, one piece at a time (bin/lib/pieces.sh, bin/piece.sh, the gate):
#   • a plan keeps its order and skips titles it already has
#   • a piece needs criteria, at most ten; a second one is refused while the first is open
#   • the review is given the open piece's criteria and its own diff, not the whole job's
#   • a PASS accepts the piece at HEAD and sends the worker to the next one — no finish, a fresh
#     budget, the old outcome set aside
#   • planned pieces left and none open: back to open one, no review spent
#   • a FAIL leaves the piece open
#   • with a piece open, a stop without a declaration since the last review spends no review —
#     until the worker has stopped that way too many times
#   • the last PASS finishes the job; an accepted piece cannot be reopened under its name
#   • the product's specification (named by the job or conventionally called so) is given to the
#     review, which holds the piece to it as well; the worker is shown it when a piece opens
#   • no plan: the gate behaves as before
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

FAKE="$(mktemp -d)"; PROMPT="$FAKE/prompt"; CALLED="$FAKE/called"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "$CALLED"; printf '%s\n' "${@: -1}" > "$PROMPT"
  echo "STATE: COMPLETE"; echo "VERDICT: ${FAKE_VERDICT:-PASS}"
  [ "${FAKE_VERDICT:-PASS}" = FAIL ] && echo "1. [acceptance_failure] ${FAKE_REPEAT:+[repeat] }src/a.ts — рука не тримає бластер"
  exit 0
fi
echo "VERDICT: PASS"
EOF
chmod +x "$FAKE/codex"; export PROMPT CALLED
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"шматок готовий"}]}}' > "$TR"

REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

mkcase(){
  RID="pieces-run-$RANDOM$RANDOM"
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/a.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**"],"objective":"ціла гра","acceptance":["гра цілком"]}' > "$IDIR/runspec.json"
}
piece(){ ( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" bash "$ROOT/bin/piece.sh" "$@" ); }
work(){ echo "$1 $RANDOM" >> "$PROJ/src/$2"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm "$1"; }
declare_done(){ jq -nc --arg r "$RID" --arg n "$RANDOM$RANDOM" '{result:"succeeded_changes", summary:("шматок " + $n), run_id:$r, ts:"2026-10-27 12:00"}' > "$IDIR/outcome.json"; }
rungate(){
  rm -f "$CALLED" "$PROMPT"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
state_of(){ jq -r --arg t "$1" '.pieces[] | select(.title == $t) | .state' "$IDIR/pieces.json"; }

echo "===== a plan, and a piece needs criteria ====="
mkcase
piece plan "Острів" "Фабрика" >/dev/null
piece plan "Острів" "Казино" >/dev/null
check "three pieces, in order"            '[ "$(jq -r "[.pieces[].title] | join(\",\")" "$IDIR/pieces.json")" = "Острів,Фабрика,Казино" ]'
check "all planned"                       '[ "$(jq "[.pieces[] | select(.state == \"planned\")] | length" "$IDIR/pieces.json")" = 3 ]'
check "no criteria — refused"             '! piece start -- >/dev/null 2>&1'
check "eleven criteria — refused"         '! piece start -- 1 2 3 4 5 6 7 8 9 10 11 >/dev/null 2>&1'
piece start -- "озеро видно з пірса" "стежка до поля" >/dev/null
check "the first planned piece is open"   '[ "$(state_of Острів)" = open ]'
check "measured from HEAD"                '[ "$(jq -r ".pieces[0].base_sha" "$IDIR/pieces.json")" = "$(git -C "$PROJ" rev-parse HEAD)" ]'
check "a second one is refused"           '! piece start "Фабрика" -- "x" >/dev/null 2>&1'
check "status shows the ladder"           'piece status | grep -q "▶ 1. Острів — у роботі"'

echo "===== the review sees this piece only ====="
work island a.ts; island_base="$(jq -r '.pieces[0].base_sha' "$IDIR/pieces.json")"
declare_done
out="$(FAKE_VERDICT=FAIL rungate s-p1)"
check "the reviewer was called"           '[ -f "$CALLED" ]'
check "it got the piece's criteria"       'grep -q "P1. озеро видно з пірса" "$PROMPT"'
check "and was told later pieces are not owed" 'grep -q "Later pieces are not" "$PROMPT"'
check "the whole job only as context"     'grep -q "THE WHOLE JOB (context" "$PROMPT"'
check "no specification: no spec rule"    '! grep -q "THE PRODUCT SPECIFICATION" "$PROMPT" && ! grep -q "not a replacement for it" "$PROMPT"'
check "a FAIL leaves the piece open"      '[ "$(state_of Острів)" = open ]'
check "and goes back to the worker"       'printf "%s" "$out" | grep -q "\"decision\""'

work island-try a.ts; declare_done
out="$(FAKE_VERDICT=FAIL rungate s-p1b)"
check "a second FAIL with the piece open is not parked" '[ ! -f "$IDIR/done" ]'
check "it goes back to the worker again"   'printf "%s" "$out" | grep -q "\"decision\""'

echo "===== a stop without a new declaration is not a review ====="
work island-wip a.ts
out="$(rungate s-p1c)"
check "the reviewer was not called"       '[ ! -f "$CALLED" ]'
check "the worker is told to declare"     'printf "%s" "$out" | jq -r .reason | grep -q "не заявив"'
check "and to wait with a blocking command" 'printf "%s" "$out" | jq -r .reason | grep -q "блокуючою командою"'
out="$(FAKE_VERDICT=FAIL SUPERVISOR_PIECE_UNDECLARED_MAX=1 rungate s-p1d)"
check "too many such stops: reviewed anyway" '[ -f "$CALLED" ]'
git -C "$PROJ" commit -qam wip

echo "===== a PASS accepts it and sends the worker on ====="
work island-fix a.ts; declare_done
out="$(rungate s-p2)"
check "the piece is accepted"             '[ "$(state_of Острів)" = accepted ]'
check "at the reviewed commit"            '[ "$(jq -r ".pieces[0].reviewed_sha" "$IDIR/pieces.json")" = "$(git -C "$PROJ" rev-parse HEAD)" ]'
check "the job is not finished"           '[ ! -f "$IDIR/done" ] || [ "$(cat "$IDIR/done")" != passed ]'
check "the worker is sent to the next"    'printf "%s" "$out" | jq -r .reason | grep -q "Наступний за планом: «Фабрика»"'
check "the old outcome is set aside"      '[ ! -f "$IDIR/outcome.json" ] && [ -f "$IDIR/outcome.piece-1.json" ]'
check "a fresh review budget"             '! ls "$SUPERVISOR_STATE_DIR"/rounds-"$RID" >/dev/null 2>&1'
check "an accepted piece cannot be reopened" '! piece start "Острів" -- "x" >/dev/null 2>&1'

echo "===== planned pieces left and none open: no review is spent ====="
work stray a.ts; declare_done
out="$(rungate s-p3)"
check "the reviewer was not called"       '[ ! -f "$CALLED" ]'
check "the worker is told to open one"    'printf "%s" "$out" | jq -r .reason | grep -q "piece start"'

echo "===== the next piece is measured from where it started ====="
piece start -- "будівлі на полі" >/dev/null
fbase="$(jq -r '.pieces[1].base_sha' "$IDIR/pieces.json")"
check "its base is the accepted HEAD"     '[ "$fbase" = "$(git -C "$PROJ" rev-parse HEAD)" ]'
work factory b.ts; declare_done
rungate s-p4 >/dev/null
check "the review saw only its own file"  'grep -q "src/b.ts" "$PROMPT" && ! grep -q "src/a.ts" "$PROMPT"'
check "Фабрика accepted"                  '[ "$(state_of Фабрика)" = accepted ]'

echo "===== the last PASS finishes the job ====="
piece start -- "рулетка крутиться" >/dev/null
work casino c.ts; declare_done
rungate s-p5 >/dev/null
check "Казино accepted"                   '[ "$(state_of Казино)" = accepted ]'
check "the job is done"                   '[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ]'

echo "===== a PASS over uncommitted work accepts nothing ====="
mkcase; piece plan "Острів" "Фабрика" >/dev/null; piece start -- "озеро" >/dev/null
work island a.ts; echo "not committed" >> "$PROJ/src/a.ts"; declare_done
out="$(rungate s-dirty)"
check "the piece stays open"              '[ "$(state_of Острів)" = open ]'
check "the worker is told to commit"      'printf "%s" "$out" | jq -r .reason | grep -q "Закоміть"'
check "and the job is not finished"       '[ "$(cat "$IDIR/done" 2>/dev/null)" != passed ]'

echo "===== a recorded acceptance that cannot be written finishes nothing ====="
git -C "$PROJ" commit -qam fix; declare_done
chmod a-w "$IDIR"
out="$(rungate s-ro)"
chmod u+w "$IDIR"
check "the worker is told it was not recorded" 'printf "%s" "$out" | jq -r .reason | grep -q "не зміг записати"'
check "the job is not finished"           '[ "$(cat "$IDIR/done" 2>/dev/null)" != passed ]'

echo "===== the plan of a task lives with the task, not the attempt ====="
mkcase
TID="PRJ-$RANDOM"; mkdir -p "$(task_dir "$TID")"; printf '{"id":"%s"}' "$TID" > "$(task_file "$TID")"
printf '%s\n' "$TID" > "$IDIR/task-id"
if task_exists "$TID"; then
  piece plan "Острів" "Фабрика" >/dev/null
  check "stored in the task's folder"     '[ -s "$(task_dir "$TID")/pieces.json" ] && [ ! -e "$IDIR/pieces.json" ]'
  rm -f "$IDIR/task-id"
  check "a run without the task sees none" '! piece status | grep -q Острів'
else
  echo "  (task_create unavailable here — case skipped)"
fi

echo "===== a new request does not inherit the last one's plan ====="
mkcase; piece plan "Острів" >/dev/null
check "the plan is there"                 '[ -s "$IDIR/pieces.json" ]'
( . "$ROOT/bin/lib/pieces.sh"; pieces_set_aside "$IDIR" )
check "pipeline.sh sets it aside for a new request" 'grep -q "\[ \"\${RELATION:-}\" != continue \] && pieces_set_aside" "$ROOT/bin/pipeline.sh"'
check "archived aside for a new request"  '[ ! -e "$IDIR/pieces.json" ] && ls "$IDIR"/dispatches/*.pieces.json >/dev/null 2>&1'

echo "===== the product's specification binds a piece too ====="
mkcase
printf '# Гра\n## Асети\nСпочатку готові моделі, а не примітиви.\n' > "$PROJ/SPEC.md"
mkdir -p "$PROJ/docs" && echo "арт" > "$PROJ/docs/art-direction.md" && echo "x" > "$PROJ/README.md"
echo "x" > "$PROJ/KNOWN_ISSUES.md"; echo "x" > "$PROJ/spec-notes.md"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm spec
jq '.objective = "Збудуй гру за специфікацією SPEC.md і docs/art-direction.md, див. також ../secret.md.\nВідомі вади — у KNOWN_ISSUES.md, їх не чіпай."' "$IDIR/runspec.json" > "$IDIR/rs.tmp" && mv "$IDIR/rs.tmp" "$IDIR/runspec.json"
specs="$(bash -c '. "$1/bin/supervisor-lib.sh"; . "$1/bin/lib/pieces.sh"; piece_spec_files "$2" "$3"' _ "$ROOT" "$IDIR" "$PROJ")"
check "SPEC.md is found"                  'printf "%s\n" "$specs" | grep -qx SPEC.md'
check "a document the job names is found" 'printf "%s\n" "$specs" | grep -qx docs/art-direction.md'
check "listed once"                       '[ "$(printf "%s\n" "$specs" | grep -cx SPEC.md)" = 1 ]'
check "nothing outside the project, no README" '! printf "%s\n" "$specs" | grep -qE "secret|README"'
check "a file merely mentioned is not a spec" '! printf "%s\n" "$specs" | grep -q KNOWN_ISSUES'
check "nor one only named like a spec"    '! printf "%s\n" "$specs" | grep -q spec-notes'
piece plan "Руки" "Риба" >/dev/null
out="$(piece start -- "дві руки тримають вудку")"
check "opening a piece names the spec"    'printf "%s" "$out" | grep -q "Специфікація продукту: SPEC.md"'
check "and says a departure goes to the director" 'printf "%s" "$out" | grep -q "рішення директора"'
work hands a.ts; declare_done
printf '4 1\n' > "$SUPERVISOR_STATE_DIR/rounds-meta-$RID"
FAKE_VERDICT=FAIL rungate s-spec >/dev/null
check "new rules: the stall count starts again" '[ "$(cut -d" " -f2 "$SUPERVISOR_STATE_DIR/rounds-meta-$RID")" = 0 ]'
git -C "$PROJ" commit -qam wip >/dev/null 2>&1; work hands-2 a.ts; declare_done
FAKE_VERDICT=FAIL FAKE_REPEAT=1 rungate s-spec1 >/dev/null
check "same rules, same finding back: counted as before"     '[ "$(cut -d" " -f2 "$SUPERVISOR_STATE_DIR/rounds-meta-$RID")" = 1 ]'
check "the review is given the spec"      'grep -q "THE PRODUCT SPECIFICATION" "$PROMPT" && grep -q "^  SPEC.md" "$PROMPT"'
check "criteria do not replace it"        'grep -q "not a replacement for it" "$PROMPT"'
check "a watered-down criterion is a defect" 'grep -q "writes a weaker version" "$PROMPT" && grep -q "acceptance_failure" "$PROMPT"'
check "later pieces still not owed"       'grep -q "still not" "$PROMPT"'
check "the rule names no tool of one project" '! grep -qiE "blender|procedural" "$PROMPT"'
check "a missing free tool is no excuse"  'grep -q "machine is not a reason" "$PROMPT"'
check "the worker's say-so excuses nothing" 'grep -q "say-so" "$PROMPT"'
git -C "$PROJ" commit -qam wip >/dev/null 2>&1; work hands-fix a.ts; declare_done
out="$(rungate s-spec2)"
check "the next piece is sent with the spec" 'printf "%s" "$out" | jq -r .reason | grep -q "Специфікація продукту: SPEC.md"'
rm -f "$PROJ/SPEC.md" "$PROJ/docs/art-direction.md"; git -C "$PROJ" commit -qam nospec
specs="$(bash -c '. "$1/bin/supervisor-lib.sh"; . "$1/bin/lib/pieces.sh"; piece_spec_files "$2" "$3"' _ "$ROOT" "$IDIR" "$PROJ")"
check "a named file that is gone is not listed" '[ -z "$specs" ]'

echo "===== no plan: as before ====="
mkcase; work plain a.ts; declare_done
rungate s-plain >/dev/null
check "reviewed"                          '[ -f "$CALLED" ]'
check "no piece block"                    '! grep -q "ONE PIECE AT A TIME" "$PROMPT"'
check "finished on PASS"                  '[ "$(cat "$IDIR/done" 2>/dev/null)" = passed ]'

echo
echo "pieces: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
