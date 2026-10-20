#!/bin/bash
# Steps the triage chooses per task, and a part of the change written by Codex.
#
# The director asked for roles called by the task — no analyst for a small fix, a designer when the
# task has an interface — and for the design to be Codex's. A step can be marked "when triage
# decides"; the context stage asks Codex which of those this task needs. «Codex робить частину»
# answers with a patch that is checked to apply and handed to Claude in the brief, and Claude can
# ask for such a patch itself with `consult-codex --patch`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf 'body { color: black; }\n' > "$PROJ/style.css"
git -C "$PROJ" add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm init

mkdir -p "$TMP/stub" "$TMP/rec"
export REC="$TMP/rec"
# One Codex stand-in for every kind of call here, told apart by what the prompt asks.
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/bash
[ "${1:-}" = login ] && { echo "Logged in using ChatGPT"; exit 0; }
out=""; prev=""; prompt=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prompt="$a"; prev="$a"; done
n=$(( $(ls "$REC" | grep -c '^codex-') + 1 ))
printf '%s' "$prompt" > "$REC/codex-$n.prompt"
printf '%s\n' "$*" > "$REC/codex-$n.argv"
case "$prompt" in
  *"THE STEPS TO DECIDE ABOUT"*)
    if [ -n "${STUB_PICK:-}" ]; then answer="$STUB_PICK"
    else answer='{"roles":[{"id":"ba","run":false,"why":"дрібна правка, аналіз зайвий"},{"id":"design","run":true,"why":"задача про вигляд екрана"}]}'; fi ;;
  *"===PATCH==="*)
    if [ "${STUB_BAD_PATCH:-0}" = 1 ]; then
      answer='===PATCH===
diff --git a/missing.css b/missing.css
--- a/missing.css
+++ b/missing.css
@@ -1 +1 @@
-nothing here
+still nothing
===END===
Змінив missing.css.'
    else
      answer='===PATCH===
diff --git a/style.css b/style.css
--- a/style.css
+++ b/style.css
@@ -1 +1,2 @@
 body { color: black; }
+.card { border-radius: 8px; }
===END===
DESIGN-NOTE-SENTINEL: додав .card у style.css; перевір вигляд картки.'
    fi ;;
  *) answer='{"scale":"medium","needs_plan":true,"needs_external_research":false,"touches_interface":true,"reason":"t"}' ;;
esac
[ -n "$out" ] && printf '%s\n' "$answer" > "$out"
printf '%s\n' "$answer"
STUB
cat > "$TMP/stub/usage" <<'STUB'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0,"window_minutes":300}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
STUB
chmod +x "$TMP/stub/codex" "$TMP/stub/usage"
export PATH="$TMP/stub:$PATH" SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage" SUPERVISOR_DESIGN_RESEARCH=0

# ------------------------------------------------------------------------------------ compiling
M="$TMP/m"; mkdir -p "$M"
cat > "$M/pipeline.json" <<'JSON'
{"schema":"bulava.pipeline/1","id":"picked","name":"За задачею","description":"тест","revision":1,
 "nodes":[
  {"id":"chat","module":"bulava/trigger.chat@1"},
  {"id":"context","module":"bulava/prep.context@1"},
  {"id":"triage","module":"bulava/prep.classify@1","title":"Тріаж"},
  {"id":"ba","module":"bulava/prep.position@1","title":"Бізнес-аналітик","params":{"engine":"codex","when":"triage","required":true},"prompt":"BA: вимоги до {{TASK}}"},
  {"id":"qa","module":"bulava/prep.position@1","title":"Тестувальник","params":{"engine":"claude"},"prompt":"QA: тест-кейси"},
  {"id":"agree","module":"bulava/prep.align@1","title":"Домовленість","params":{"required":true}},
  {"id":"compose","module":"bulava/prep.compose@1"},
  {"id":"design","module":"bulava/agent.codexPart@1","title":"Дизайнер","params":{"when":"triage"},"prompt":"DESIGN-PROMPT-SENTINEL: зроби вигляд для {{TASK}}"},
  {"id":"deliver","module":"bulava/agent.claude@1"},
  {"id":"review","module":"bulava/gate.review@1"}],
 "edges":[
  {"from":"chat.task","to":"context.task"},{"from":"chat.task","to":"triage.task"},
  {"from":"context.context","to":"ba.context"},{"from":"triage.context","to":"ba.context"},
  {"from":"context.context","to":"qa.context"},{"from":"triage.context","to":"qa.context"},
  {"from":"ba.position","to":"agree.positions"},{"from":"qa.position","to":"agree.positions"},
  {"from":"agree.checks","to":"compose.in"},{"from":"compose.brief","to":"design.brief"},
  {"from":"design.brief","to":"deliver.brief"},{"from":"deliver.work","to":"review.work"}]}
JSON
echo "===== a step can be left to the triage, and Codex can do a part ====="
python3 "$BIN/pipeline-tool.py" validate "$M" > "$TMP/v.json" 2>&1
jq -e '.issues | map(select(.level == "error")) | length == 0' "$TMP/v.json" >/dev/null \
  && ok "the description is valid" || bad "invalid: $(head -c 600 "$TMP/v.json")"
jq -e '.guarantees | map(.k) | index("review")' "$TMP/v.json" >/dev/null \
  && ok "and still reviewed by Codex: the part Codex writes goes through Claude and the review" || bad "guarantees: $(jq -c .guarantees "$TMP/v.json")"
python3 "$BIN/pipeline-tool.py" registry > "$TMP/reg.json" 2>/dev/null
jq -e '[.. | objects | select(.k? == "when" and (.options == ["always", "triage"]))] | length > 0' "$TMP/reg.json" >/dev/null \
  && jq -e '[.. | objects | select(has("agent.codexPart"))] | length > 0 or ([.. | objects | select(.key? == "agent.codexPart" or .id? == "agent.codexPart")] | length > 0)' "$TMP/reg.json" >/dev/null \
  && ok "the editor's palette has the new step and the «Коли кликати» choice" || bad "registry lacks agent.codexPart or the when param"
SNAP="$TMP/snap"; mkdir -p "$SNAP"
python3 "$BIN/pipeline-tool.py" compile "$M" --out "$TMP/c.json" --snapshot "$SNAP" >/dev/null 2>"$TMP/c.err" \
  && ok "it compiles" || bad "compile: $(cat "$TMP/c.err")"
C="$TMP/c.json"
stage() { jq -c --arg id "$1" '.stages[] | select(.id == $id)' "$C"; }
[ "$(stage ba | jq -r '.pick // false')" = true ] && [ "$(stage qa | jq -r '.pick // false')" = false ] \
  && ok "the analyst is left to the triage, the tester always runs" || bad "pick flags: ba=$(stage ba | jq -c .pick) qa=$(stage qa | jq -c .pick)"
stage context | jq -e '[.run | to_entries[] | select(.value == "--pick-role") | .key] | length == 2' >/dev/null \
  && stage context | jq -e '.run | map(select(startswith("ba\t") or startswith("design\t"))) | length == 2' >/dev/null \
  && ok "the context stage is told which steps to choose among" || bad "context run: $(stage context | jq -c .run)"
order="$(jq -r '[.stages[].id] | join(" ")' "$C")"
case "$order" in *"compose design deliver"*) ok "Codex's part comes after the brief and before Claude: $order" ;; *) bad "order: $order" ;; esac
[ "$(stage design | jq -r '.run[0]')" = pipeline-codex-part.sh ] && [ "$(stage design | jq -r '.pick')" = true ] \
  && ok "and it runs Codex's part, when the triage calls for it" || bad "design stage: $(stage design)"

echo "===== a step left to the triage needs a triage; Codex's part needs Claude after it ====="
jq 'del(.nodes[] | select(.id == "context" or .id == "triage"))
    | .edges |= map(select(((.from | test("^(context|triage)[.]")) or (.to | test("^(context|triage)[.]"))) | not))
    | .edges += [{"from":"chat.task","to":"ba.context"},{"from":"chat.task","to":"qa.context"}]' \
  "$M/pipeline.json" > "$TMP/no-triage.json"
mkdir -p "$TMP/nt"; cp "$TMP/no-triage.json" "$TMP/nt/pipeline.json"
python3 "$BIN/pipeline-tool.py" validate "$TMP/nt" 2>/dev/null | jq -e '.issues | map(.code) | index("V28")' >/dev/null \
  && ok "without a triage it is refused, with the reason" || bad "no V28: $(python3 "$BIN/pipeline-tool.py" validate "$TMP/nt" 2>&1 | head -c 400)"
mkdir -p "$TMP/nc"
jq '.edges |= map(if .from == "design.brief" then .to = "review.work" else . end) | del(.nodes[] | select(.id == "deliver")) | .edges |= map(select(.from != "deliver.work"))' \
  "$M/pipeline.json" > "$TMP/nc/pipeline.json"
python3 "$BIN/pipeline-tool.py" validate "$TMP/nc" 2>/dev/null | jq -e '.issues | map(.code) | index("V29")' >/dev/null \
  && ok "Codex's part with nobody after it is refused" || bad "no V29: $(python3 "$BIN/pipeline-tool.py" validate "$TMP/nc" 2>&1 | head -c 400)"

# ------------------------------------------------------------------------------------ the triage
echo "===== the triage chooses the steps for this task ====="
ART="$TMP/art"; mkdir -p "$ART"
argv=(); while IFS= read -r a; do argv+=("$a"); done < <(stage context | jq -r '.run[]')
( cd "$PROJ" && bash "$BIN/${argv[0]}" --art "$ART" "${argv[@]:1}" "$PROJ" "Онови вигляд картки товару" ) >/dev/null 2>&1
jq -e '.roles | map({(.id): .run}) | add == {"ba": false, "design": true}' "$ART/roles-chosen.json" >/dev/null 2>&1 \
  && ok "it keeps the triage's choice: no analyst, the designer yes" || bad "roles-chosen.json: $(cat "$ART/roles-chosen.json" 2>&1)"
p="$(grep -l "THE STEPS TO DECIDE ABOUT" "$REC"/codex-*.prompt 2>/dev/null | head -1)"
[ -n "$p" ] && grep -q "Бізнес-аналітик" "$p" && grep -q "DESIGN-PROMPT-SENTINEL" "$p" && grep -q "Онови вигляд картки товару" "$p" \
  && ok "and it chose from each step's name and prompt, and the task" || bad "the pick prompt: $(head -c 400 "$p" 2>/dev/null)"
grep -q -- "--sandbox read-only" "$(dirname "$p")/$(basename "$p" .prompt).argv" 2>/dev/null \
  && ok "the triage only reads" || bad "the pick ran without the read-only sandbox"

ART2="$TMP/art2"; mkdir -p "$ART2"
( cd "$PROJ" && STUB_PICK='{"roles":[{"id":"ba","run":false,"why":"x"}]}' bash "$BIN/${argv[0]}" --art "$ART2" "${argv[@]:1}" "$PROJ" "Онови вигляд картки товару" ) >/dev/null 2>&1
[ ! -e "$ART2/roles-chosen.json" ] && ok "an answer that leaves a step out of the choice is not used: every step runs" || bad "a partial answer was kept: $(cat "$ART2/roles-chosen.json")"

# ------------------------------------------------------------------------------------ Codex's part
echo "===== Codex writes its part as a patch; the brief hands it to Claude ====="
printf 'BRIEF-SENTINEL — план і тест-кейси\n' > "$ART/composed.txt"
dargv=(); while IFS= read -r a; do dargv+=("$a"); done < <(stage design | jq -r '.run[]')
PIPE_IDIR="$TMP/idir" PIPE_ART="$ART" PIPE_STAGE=design bash "$BIN/${dargv[0]}" "${dargv[@]:1}" --art "$ART" "$PROJ" "Онови вигляд картки товару" >/dev/null 2>&1; rc=$?
mkdir -p "$TMP/idir"
[ "$rc" = 0 ] && ok "the part is done (exit 0)" || bad "exit $rc: $(cat "$ART/.unavailable-design" 2>/dev/null)"
git -C "$PROJ" diff --quiet && ok "Codex did not change the folder itself" || bad "the folder changed: $(git -C "$PROJ" diff --stat)"
git -C "$PROJ" apply --check --recount "$ART/codex-part-design.patch" 2>/dev/null && ok "its patch applies to the folder" || bad "the patch: $(cat "$ART/codex-part-design.patch" 2>&1)"
grep -q "ЧАСТИНА, ЯКУ НАПИСАВ CODEX: «Дизайнер»" "$ART/composed.txt" && grep -q "codex-part-design.patch" "$ART/composed.txt" \
  && grep -q "DESIGN-NOTE-SENTINEL" "$ART/composed.txt" && grep -q "style.css" "$ART/composed.txt" \
  && ok "Claude's brief names the patch, its files and Codex's note" || bad "brief: $(cat "$ART/composed.txt")"
head -1 "$ART/composed.txt" | grep -q BRIEF-SENTINEL && ok "after the brief, not instead of it" || bad "the brief lost its start"
dp="$(grep -l "DESIGN-PROMPT-SENTINEL: зроби вигляд для Онови вигляд картки товару" "$REC"/codex-*.prompt 2>/dev/null | head -1)"
[ -n "$dp" ] && grep -q "BRIEF-SENTINEL" "$dp" && ok "Codex got its step's prompt and the brief" || bad "the part prompt"
grep -q -- "--sandbox read-only" "$(dirname "$dp")/$(basename "$dp" .prompt).argv" 2>/dev/null \
  && ok "and ran read-only" || bad "the part ran without the read-only sandbox: $(cat "$(dirname "$dp")/$(basename "$dp" .prompt).argv" 2>/dev/null)"

printf 'BRIEF\n' > "$ART/composed.txt"; rm -f "$ART/.unavailable-design"
STUB_BAD_PATCH=1 PIPE_IDIR="$TMP/idir" PIPE_ART="$ART" PIPE_STAGE=design bash "$BIN/${dargv[0]}" "${dargv[@]:1}" --art "$ART" "$PROJ" "x" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "не накладається" "$ART/.unavailable-design" 2>/dev/null \
  && ok "a patch that does not apply fails the step, with the reason" || bad "bad patch: rc=$rc $(cat "$ART/.unavailable-design" 2>/dev/null)"
grep -q "НЕ НАКЛАДАЄТЬСЯ" "$ART/composed.txt" && ok "and the brief tells Claude to do that part itself" || bad "brief after a bad patch: $(cat "$ART/composed.txt")"

# ------------------------------------------------------------------------------------ consult --patch
echo "===== Claude asks Codex to write a change: consult-codex --patch ====="
. "$BIN/supervisor-lib.sh"
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' RUN-P > "$IDIR/run-id"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
jq -n '{id:"D-1",task:"онови вигляд картки"}' > "$IDIR/dispatch.json"
out="$( cd "$PROJ" && ORCHESTRATOR_RUN_ID=RUN-P bash "$BIN/consult-codex.sh" --patch "зроби стиль картки" 2>&1 )"; rc=$?
[ "$rc" = 0 ] && ok "it answers (exit 0)" || bad "exit $rc: $out"
pf="$IDIR/consultations/RUN-P/0001/change.patch"
[ -s "$pf" ] && git -C "$PROJ" apply --check --recount "$pf" && ok "with a patch on disk that applies" || bad "no applicable patch at $pf"
case "$out" in *"Накладається чисто"*"$pf"*) ok "and tells Claude where it is and that it applies" ;; *) bad "said: $out" ;; esac
git -C "$PROJ" diff --quiet && ok "Codex itself changed nothing" || bad "the folder changed"
cp="$(grep -l "WHAT CLAUDE ASKS YOU TO WRITE" "$REC"/codex-*.prompt | tail -1)"
grep -q -- "--sandbox read-only" "$(dirname "$cp")/$(basename "$cp" .prompt).argv" 2>/dev/null \
  && ok "and the call was read-only" || bad "consult --patch ran without the read-only sandbox"
out2="$( cd "$PROJ" && ORCHESTRATOR_RUN_ID=RUN-P STUB_BAD_PATCH=1 bash "$BIN/consult-codex.sh" --patch "зламаний" 2>&1 )"; rc=$?
[ "$rc" = 3 ] && case "$out2" in *"НЕ накладається"*) true ;; *) false ;; esac \
  && ok "a patch that does not apply is said so (exit 3)" || bad "bad patch: rc=$rc $out2"
out3="$( cd "$PROJ" && ORCHESTRATOR_RUN_ID=RUN-P bash "$BIN/consult-codex.sh" "звичайне питання" 2>&1 )"; rc=$?
[ "$rc" = 0 ] && case "$out3" in *"change.patch"*|*"Накладається"*) false ;; *) true ;; esac \
  && ok "a plain question is still a plain consultation (exit 0, no patch)" || bad "plain question: rc=$rc $out3"

echo "===== a choice belongs to its task: retried, replaced, never inherited ====="
: > "$ART/role-ba.skipped"; printf 'stale\n' > "$ART/role-ba.skipped"
( cd "$PROJ" && bash "$BIN/${argv[0]}" --art "$ART" "${argv[@]:1}" "$PROJ" "Онови вигляд картки товару" ) >/dev/null 2>&1
[ ! -e "$ART/role-ba.skipped" ] && ok "a retry clears the skip markers of the attempt before" || bad "a stale skip marker survived the retry"
[ -s "$IDIR/roles-chosen.json" ] && ok "the opening task's choice is kept beside the run for its follow-ups" || bad "the choice was not published to the run"
python3 "$BIN/pipeline-tool.py" compile "$ROOT/supervisor/pipelines/manifests/adaptive-peer" --out "$TMP/ap.json" --snapshot "$TMP/apsnap" >/dev/null 2>&1
apargv=(); while IFS= read -r a; do apargv+=("$a"); done < <(jq -c '.stages[] | select(.id == "context") | .run' "$TMP/ap.json" | jq -r '.[]')
mkdir -p "$TMP/art-next"
( cd "$PROJ" && bash "$BIN/${apargv[0]}" --art "$TMP/art-next" "${apargv[@]:1}" "$PROJ" "Інша задача без вибору ролей" ) >/dev/null 2>&1
[ ! -e "$IDIR/roles-chosen.json" ] && ok "a new task without such steps drops the previous task's choice" || bad "the previous choice leaks into the next task"

echo "===== the agreement when the triage left roles out ====="
AA="$TMP/align"; mkdir -p "$AA"; printf 'контекст\n' > "$AA/context.md"
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$AA/.preflight-deadline"
printf 'дрібна правка\n' > "$AA/role-ba.skipped"; printf 'Claude впав\n' > "$AA/role-qa.unavailable"
PIPE_STAGE=agree PIPE_STAGE_HOLDS=1 bash "$BIN/preflight.sh" --art "$AA" --stage align --roles ba,qa "$PROJ" "задача" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "one role left out and the other failed is a failure, not «nothing to agree»" || bad "a failed role passed as left out (exit 0)"
rm -f "$AA/role-qa.unavailable" "$AA/.skip-agree"; printf 'не потрібен\n' > "$AA/role-qa.skipped"
PIPE_STAGE=agree PIPE_STAGE_HOLDS=1 bash "$BIN/preflight.sh" --art "$AA" --stage align --roles ba,qa "$PROJ" "задача" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -s "$AA/.skip-agree" ] && ok "every role left out: nothing to agree, said as a skip" || bad "all left out: rc=$rc skip=$(cat "$AA/.skip-agree" 2>/dev/null)"
[ ! -s "$AA/degraded.md" ] && ok "and not reported as a disagreement" || bad "degraded: $(cat "$AA/degraded.md")"

echo "===== the command handed to Claude works where the paths have spaces ====="
SP="$TMP/a project"; mkdir -p "$SP"; git -C "$SP" init -q
printf 'body { color: black; }\n' > "$SP/style.css"; git -C "$SP" add -A; git -C "$SP" -c user.email=t@t -c user.name=t commit -qm i
SA="$TMP/art with space"; mkdir -p "$SA"; printf 'BRIEF\n' > "$SA/composed.txt"
PIPE_IDIR="$TMP/idir" PIPE_ART="$SA" PIPE_STAGE=design bash "$BIN/pipeline-codex-part.sh" --node design --title Дизайнер --art "$SA" "$SP" "x" >/dev/null 2>&1
cmd="$(grep -o 'git -C [^`]*apply --recount [^`]*' "$SA/composed.txt" | head -1)"
[ -n "$cmd" ] && bash -c "$cmd" 2>/dev/null && grep -q '.card' "$SP/style.css" \
  && ok "the brief's own command applies the patch: $cmd" || bad "the command did not apply: $cmd"
rm -f "$SA/composed.txt"
PIPE_IDIR="$TMP/idir" PIPE_ART="$SA" PIPE_STAGE=design bash "$BIN/pipeline-codex-part.sh" --node design --title Дизайнер --art "$SA" "$PROJ" "ЗАВДАННЯ-БЕЗ-БРИФУ" >/dev/null 2>&1
head -1 "$SA/composed.txt" | grep -q "ЗАВДАННЯ-БЕЗ-БРИФУ" && ok "with no brief yet, his words come first and the patch after" || bad "brief without a task: $(head -3 "$SA/composed.txt")"

echo
[ "$fails" = 0 ] && echo "✅ triage and Codex's part: all passed" || echo "❌ triage and Codex's part: $fails failure(s)"
exit "$fails"
