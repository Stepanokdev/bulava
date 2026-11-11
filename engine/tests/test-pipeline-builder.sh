#!/bin/bash
# Pipelines somebody built — described, checked, compiled and actually run.
#
# What this pins, in the order a director meets it:
#   1. the description format and its one validator (pipeline-tool.py): the built-in "Claude + Codex"
#      compiles to EXACTLY the stage list the engine has always run, and every broken description
#      fails with its own code — the same codes Bulava's editor shows;
#   2. edits are transactional: a patch made against an old revision changes nothing, a layout-only
#      save does not count as a change, built-ins cannot be written;
#   3. a pipeline from the engine's state folder runs through the real send → queue → pump → runner
#      path: its graph decides the stages, its prompts reach the stages, its brief reaches the
#      worker, its gates reach the dispatch record, and every step leaves an event the chat can show;
#   4. a name that does not exist is refused at the door instead of being prepared as `plain`;
#   5. a REQUIRED stage that fails inside a parallel group stops the run.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ENGINE_ROOT="$(cd "$BIN/.." && pwd)"
TOOL="$BIN/pipeline-tool.py"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-builder.XXXXXXXX")" || exit 1
KEEP_TMP="${KEEP_TMP:-0}"
cleanup() {
  [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null
  [ "$KEEP_TMP" = 1 ] && { echo "kept: $TMP"; return 0; }
  rm -rf "$TMP"
}
trap cleanup EXIT
unset SUPERVISOR_RUN_ENV_FROM_APP SUPERVISOR_CLAUDE_MODEL SUPERVISOR_CLAUDE_EFFORT SUPERVISOR_CODEX_MODEL SUPERVISOR_CODEX_EFFORT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude/sessions"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
PY="$(command -v python3)"
tool() { "$PY" "$TOOL" "$@"; }

echo "===== the built-in compiles to the stage list the engine has always run ====="
tool validate "$ENGINE_ROOT/supervisor/pipelines/manifests/adaptive-peer" > "$TMP/v.json"; rc=$?
[ "$rc" = 0 ] && jq -e '.ok and (.issues|length)==0' "$TMP/v.json" >/dev/null && ok "the built-in description is valid" || bad "the built-in does not validate: $(cat "$TMP/v.json")"
jq -e '[.guarantees[].k] == ["review","scope","verify"]' "$TMP/v.json" >/dev/null && ok "its guarantees: Codex reviews, scope, build proof" || bad "guarantees: $(jq -c '[.guarantees[].k]' "$TMP/v.json")"
tool compile "$ENGINE_ROOT/supervisor/pipelines/manifests/adaptive-peer" --out "$TMP/c.json" >/dev/null
proj='[.stages[] | {id, run, group:(.group // null), optional:(.optional // false), skip:(.skip_when_followup // false)}]'
if [ "$(jq -c "$proj" "$TMP/c.json")" = "$(jq -c "$proj" "$ENGINE_ROOT/supervisor/pipelines/adaptive-peer.json")" ]; then
  ok "compiled stages equal adaptive-peer.json — ids, commands, parallel group, optional, follow-up skips"
else
  bad "compiled stages differ from adaptive-peer.json"
fi
jq -e '.gates.review == true and .gates.maxRounds == 3 and (.needs == ["codex"])' "$TMP/c.json" >/dev/null \
  && ok "and its gates say: reviewed, up to 3 rounds; it needs Codex" || bad "gates/needs: $(jq -c '{gates,needs}' "$TMP/c.json")"

echo "===== the built-in with a review team: the same stages, a team at the review ====="
RT="$ENGINE_ROOT/supervisor/pipelines/manifests/review-team"
[ "$(tool resolve review-team)" = "manifest:$RT" ] && ok "it runs from its description" || bad "resolve review-team: $(tool resolve review-team)"
[ "$(tool resolve adaptive-peer)" = "legacy:$ENGINE_ROOT/supervisor/pipelines/adaptive-peer.json" ] \
  && ok "Claude + Codex still runs its proven stage list" || bad "resolve adaptive-peer: $(tool resolve adaptive-peer)"
tool check review-team && ok "it can be chosen: the door lets it through" || bad "check review-team refused it"
tool validate "$RT" > "$TMP/vt.json"
jq -e '.ok and (.issues|length)==0 and ([.guarantees[].k] == ["review","team","scope","verify"]) and ([.guarantees[]|select(.k=="team")][0].t.uk == "Команда з 3")' "$TMP/vt.json" >/dev/null \
  && ok "valid, and it says a team of 3 reviews" || bad "validate review-team: $(jq -c '{issues,guarantees}' "$TMP/vt.json")"
tool compile "$RT" --out "$TMP/ct.json" >/dev/null
[ "$(jq -c "$proj" "$TMP/ct.json")" = "$(jq -c "$proj" "$ENGINE_ROOT/supervisor/pipelines/adaptive-peer.json")" ] \
  && ok "its stages are exactly Claude + Codex's" || bad "review-team stages differ from adaptive-peer.json"
jq -e '.gates.review == true and .gates.maxRounds == 3 and .gates.reviewTeam == "contract security state"' "$TMP/ct.json" >/dev/null \
  && ok "its gates: reviewed, 3 rounds, by contract, security and state" || bad "review-team gates: $(jq -c .gates "$TMP/ct.json")"
jq -e '.gates | has("reviewTeam") | not' "$TMP/c.json" >/dev/null && ok "Claude + Codex names no team: the engine decides, as before" || bad "adaptive-peer gates name a team"
tool list | jq -e '[.pipelines[] | select(.id=="review-team")][0] | .kind == "builtin" and .name == "Claude + команда Codex" and .i18n.en.name == "Claude + a Codex team"' >/dev/null \
  && ok "the library lists it as built in, named in both languages" || bad "library entry: $(tool list | jq -c '.pipelines[]|select(.id=="review-team")')"
tool save review-team --in "$RT/pipeline.json" >/dev/null 2>&1 && bad "a built-in could be overwritten" || ok "and it cannot be overwritten"
for t in one specialists specialists-general all; do
  "$PY" - "$ENGINE_ROOT/supervisor/pipelines/manifests/adaptive-peer/pipeline.json" "$t" > "$TMP/m-$t.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1])); m.pop("builtin", None); m.pop("executes", None)
next(n for n in m["nodes"] if n["id"] == "review")["params"] = {"team": sys.argv[2]}
print(json.dumps(m))
PYEOF
  mkdir -p "$TMP/p-$t"; cp "$TMP/m-$t.json" "$TMP/p-$t/pipeline.json"
  tool compile "$TMP/p-$t" --out "$TMP/c-$t.json" >/dev/null
done
[ "$(jq -r .gates.reviewTeam "$TMP/c-one.json")" = off ] && ok "one reviewer is said as off, so a server default does not apply" || bad "one: $(jq -c .gates "$TMP/c-one.json")"
[ "$(jq -r .gates.reviewTeam "$TMP/c-specialists-general.json")" = "contract security state general" ] && ok "the specialists and an ordinary reviewer" || bad "specialists-general"
[ "$(jq -r .gates.reviewTeam "$TMP/c-all.json" | wc -w | tr -d ' ')" = 7 ] && ok "all seven focuses" || bad "all: $(jq -c .gates "$TMP/c-all.json")"
tool registry | jq -e '.modules["gate.review"].p[0] | .k == "team" and .type == "select" and .default == "one" and (.options | length) == 4 and .ol.specialists.uk != null' >/dev/null 2>&1 \
  && ok "the editor gets the choice with its labels" || bad "registry gate.review: $(tool registry | jq -c '.modules["gate.review"].p' 2>/dev/null)"

echo "===== every broken description fails with its own code ====="
"$PY" - "$TOOL" "$ENGINE_ROOT" > "$TMP/cases.txt" 2>&1 <<'PYEOF'
import json, subprocess, sys, copy, os
tool, root = sys.argv[1], sys.argv[2]
base = json.load(open(os.path.join(root, "supervisor/pipelines/manifests/adaptive-peer/pipeline.json")))
def run(m):
    p = subprocess.run([sys.executable, tool, "validate", "-"], input=json.dumps(m), capture_output=True, text=True)
    return json.loads(p.stdout), p.returncode
def node(m, i): return next(n for n in m["nodes"] if n["id"] == i)
def case(name, expect, f):
    m = copy.deepcopy(base); m.pop("builtin", None); m.pop("executes", None); f(m)
    v, rc = run(m)
    codes = sorted(set(i["code"] for i in v["issues"] if i["level"] == "error"))
    good = (rc == 0 and not codes) if not expect else (rc == 1 and all(c in codes for c in expect))
    print(("PASS" if good else "FAIL") + " %s expected=%s got=%s" % (name, expect, codes))
case("valid copy", [], lambda m: None)
case("unknown module", ["V1"], lambda m: node(m, "context").update(module="acme/run-shell@1"))
def wrong_type(m):
    m["edges"] = [e for e in m["edges"] if e["to"] != "verify.work"] + [{"from": "chat.task", "to": "verify.work"}]
case("incompatible port", ["V2"], wrong_type)
def unbounded(m):
    for e in m["edges"]:
        e.pop("loop", None)
case("loop without a bound", ["V5"], unbounded)
def too_many(m):
    next(e for e in m["edges"] if e.get("loop"))["loop"]["max"] = 20
case("loop over the ceiling", ["V6"], too_many)
def cross(m):
    m["edges"].append({"from": "review.fail", "to": "align.positions", "loop": {"max": 2}})
case("loop across phases", ["V7"], cross)
def orphan(m):
    m["nodes"].append({"id": "crit", "module": "bulava/prep.context@1", "title": "x"})
case("unreachable step with an empty input", ["V4", "V3"], orphan)
case("a key in a prompt", ["V8"], lambda m: node(m, "compose").update(prompt="token " + "sk-ant-" + "x" * 24))
def codex_skill(m):
    node(m, "deliver")["module"] = "bulava/agent.codex@1"
    m["nodes"].append({"id": "skl", "module": "bulava/skill.require@1", "params": {"skill": "minimalist-ui"}})
    m["edges"] = [e for e in m["edges"] if e["to"] != "deliver.brief"] + [{"from": "compose.brief", "to": "skl.brief"}, {"from": "skl.brief", "to": "deliver.brief"}]
case("required skill for Codex", ["V9"], codex_skill)
def two_aesthetics(m):
    m["nodes"] += [{"id": "s1", "module": "bulava/skill.require@1", "params": {"skill": "minimalist-ui"}},
                   {"id": "s2", "module": "bulava/skill.require@1", "params": {"skill": "high-end-visual-design"}}]
    m["edges"] = [e for e in m["edges"] if e["to"] != "deliver.brief"] + [{"from": "compose.brief", "to": "s1.brief"}, {"from": "s1.brief", "to": "s2.brief"}, {"from": "s2.brief", "to": "deliver.brief"}]
case("two aesthetics", ["V10"], two_aesthetics)
def unattended_no_review(m):
    node(m, "chat").update(module="bulava/trigger.schedule@1")
    m["nodes"] = [n for n in m["nodes"] if n["id"] != "review"]
    m["edges"] = [e for e in m["edges"] if not e["from"].startswith("review.") and not e["to"].startswith("review.")] + [{"from": "verify.work", "to": "merge.work"}, {"from": "verify.work", "to": "report.in"}]
case("automation without review", ["V13"], unattended_no_review)
case("newer module", ["V16"], lambda m: node(m, "review").update(module="bulava/gate.review@2"))
def armed_import(m):
    m["origin"] = {"kind": "github", "repo": "a/b"}; m["armed"] = True
case("import with its trigger on", ["V12"], armed_import)
def no_trigger(m):
    m["nodes"] = [n for n in m["nodes"] if n["id"] != "chat"]; m["edges"] = [e for e in m["edges"] if not e["from"].startswith("chat.")]
case("no trigger", ["V11"], no_trigger)
case("a module this engine cannot run", ["V18"], lambda m: node(m, "deliver").update(module="bulava/agent.codex@1"))
case("an unknown review team", ["V30"], lambda m: node(m, "review").update(params={"team": "everyone"}))
case("a known review team", [], lambda m: node(m, "review").update(params={"team": "specialists-general"}))
PYEOF
while IFS= read -r line; do
  case "$line" in PASS*) ok "${line#PASS }" ;; FAIL*) bad "${line#FAIL }" ;; *) bad "validator harness: $line" ;; esac
done < "$TMP/cases.txt"

echo "===== edits are transactions ====="
tool duplicate adaptive-peer my-flow --name "Моя копія" > "$TMP/d.json"
jq -e '.ok and .revision == 1' "$TMP/d.json" >/dev/null && [ -s "$SUPERVISOR_STATE_DIR/pipelines/my-flow/pipeline.json" ] \
  && ok "duplicating the built-in gives an editable copy in the engine's STATE folder" || bad "duplicate: $(cat "$TMP/d.json")"
jq -e '.origin.kind == "fork" and .origin.of == "adaptive-peer" and (.builtin|not)' "$SUPERVISOR_STATE_DIR/pipelines/my-flow/pipeline.json" >/dev/null \
  && ok "the copy knows where it came from and is not a built-in" || bad "the copy's origin is wrong"
echo '[{"op":"test","path":"/revision","value":1},{"op":"replace","path":"/name","value":"Нова назва"}]' | tool patch my-flow > "$TMP/p1.json"
jq -e '.ok and .revision == 2' "$TMP/p1.json" >/dev/null && ok "a patch against the current revision applies and bumps it" || bad "patch: $(cat "$TMP/p1.json")"
before="$(cat "$SUPERVISOR_STATE_DIR/pipelines/my-flow/pipeline.json")"
echo '[{"op":"test","path":"/revision","value":1},{"op":"replace","path":"/name","value":"Застаріле"}]' | tool patch my-flow > "$TMP/p2.json"; rc=$?
[ "$rc" = 6 ] && jq -e '.code == "test-failed"' "$TMP/p2.json" >/dev/null && ok "a patch made for an old revision is refused (exit 6)" || bad "stale patch: rc=$rc $(cat "$TMP/p2.json")"
[ "$before" = "$(cat "$SUPERVISOR_STATE_DIR/pipelines/my-flow/pipeline.json")" ] && ok "and nothing was written — not even partly" || bad "a refused patch changed the file"
echo '[{"op":"test","path":"/revision","value":2},{"op":"remove","path":"/nodes/9"}]' | tool patch my-flow > "$TMP/p3.json"; rc=$?
[ "$rc" = 7 ] && ok "a patch that would break the pipeline is refused with the reason" || bad "breaking patch: rc=$rc $(cat "$TMP/p3.json")"
tool show my-flow | jq '.pipeline | (.nodes[0].x = 999)' > "$TMP/moved.json"
tool save my-flow --expect-revision 2 < "$TMP/moved.json" > "$TMP/s1.json"
jq -e '.revision == 2' "$TMP/s1.json" >/dev/null && ok "moving a box on the canvas is layout, not a new revision" || bad "layout save: $(cat "$TMP/s1.json")"
jq -e '.nodes.chat.x == 999' "$SUPERVISOR_STATE_DIR/pipelines/my-flow/layout.json" >/dev/null && ok "and the position lives in layout.json" || bad "the position did not reach layout.json"
tool show my-flow | jq '.pipeline | (.nodes[5].prompt = "Пиши коротко.")' > "$TMP/prompt.json"
tool save my-flow --expect-revision 2 < "$TMP/prompt.json" > "$TMP/s2.json"
jq -e '.revision == 3' "$TMP/s2.json" >/dev/null && [ "$(cat "$SUPERVISOR_STATE_DIR/pipelines/my-flow/prompts/compose.md")" = "Пиши коротко." ] \
  && ok "a changed prompt is a change, written to prompts/<node>.md" || bad "prompt save: $(cat "$TMP/s2.json")"
tool save my-flow --expect-revision 2 < "$TMP/prompt.json" > "$TMP/s3.json"; rc=$?
[ "$rc" = 6 ] && ok "a save against an old revision is refused" || bad "stale save: rc=$rc"
echo '[]' | tool patch adaptive-peer > /dev/null 2>&1; rc=$?
[ "$rc" = 5 ] && ok "the built-in cannot be written" || bad "the built-in accepted a patch (rc=$rc)"
tool delete my-flow > "$TMP/del.json"
[ ! -e "$SUPERVISOR_STATE_DIR/pipelines/my-flow" ] && [ -d "$(jq -r .trash "$TMP/del.json")" ] \
  && ok "deleting moves it aside, it is not destroyed" || bad "delete: $(cat "$TMP/del.json")"

echo "===== names that do not run are refused at the door ====="
tool check nope 2>/dev/null; [ $? = 3 ] && ok "an unknown name: exit 3" || bad "unknown name was accepted"
mkdir -p "$SUPERVISOR_STATE_DIR/pipelines/broken"
jq '.id="broken" | del(.builtin,.executes) | .nodes[1].module="acme/x@1"' "$ENGINE_ROOT/supervisor/pipelines/manifests/adaptive-peer/pipeline.json" \
  > "$SUPERVISOR_STATE_DIR/pipelines/broken/pipeline.json"
why="$(tool check broken 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 4 ] && case "$why" in *"не можна запустити"*) true ;; *) false ;; esac && ok "an invalid one: exit 4, with the reason" || bad "invalid check: rc=$rc $why"

# ------------------------------------------------------------------------- a real run of a built pipeline
command -v tmux >/dev/null 2>&1 || { echo "⚠️  нема tmux — пропускаю запуск"; [ "$fails" = 0 ] && exit 0 || exit 1; }
export SUPERVISOR_DESIGN_RESEARCH=0 SUPERVISOR_PLAN_TIMEOUT=60 SUPERVISOR_TURN_PROBE_GAP=0
export SUPERVISOR_PUMP_POLL=1 SUPERVISOR_PUMP_GRACE=1 SUPERVISOR_WATCHDOG_POLL=1 STUB_SLEEP=1
export SUPERVISOR_PROMPT_WAIT=2 SUPERVISOR_INJECT_CALM=0 SUPERVISOR_INJECT_TYPE_TRIES=1 SUPERVISOR_ENTER_CONFIRM_WAIT=1
REC="$TMP/rec"; mkdir -p "$REC"; export REC
PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
: > "$PROJ/README.md"; git -C "$PROJ" add -A 2>/dev/null; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
. "$BIN/supervisor-lib.sh"
SLUG="$(slug_for "$PROJ")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"
mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"; printf '%s\n' "$SESSION" > "$IDIR/session"
printf 'RUN-PB-1\n' > "$IDIR/run-id"; printf 'sid-pb-1\n' > "$IDIR/claude-session-id"; printf 'main\n' > "$IDIR/branch"
: > "$IDIR/started-at"; : > "$IDIR/direct-chat"
tmux new-session -d -s "$SESSION" 'while :; do sleep 1; done' 2>/dev/null
tmux has-session -t "$SESSION" 2>/dev/null || { echo "⚠️  tmux не піднявся — пропускаю запуск"; [ "$fails" = 0 ] && exit 0 || exit 1; }
sleep 0.3
cat > "$HOME/.claude/sessions/worker.json" <<JSON
{"pid":$$,"sessionId":"sid-pb-1","tmux":"$SESSION:@1.%1","status":"idle"}
JSON
mkdir -p "$TMP/stub"
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
prompt=""; for a in "$@"; do prompt="$a"; done
n=$(( $(ls "$REC" | grep -c '^claude-.*\.prompt$') + 1 ))
printf '%s' "$prompt" > "$REC/claude-$n.prompt"
sleep "${STUB_SLEEP:-1}"
printf 'REAL GOAL — CLAUDE-POSITION-SENTINEL\nAPPROACH — x\nMISSED REQUIREMENTS AND EDGE CASES — x\nREPOSITORY EVIDENCE — x\nPROOF — x\n'
STUB
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; prev=""; prompt=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prompt="$a"; prev="$a"; done
n=$(( $(ls "$REC" | grep -c '^codex-.*\.prompt$') + 1 ))
printf '%s' "$prompt" > "$REC/codex-$n.prompt"
sleep "${STUB_SLEEP:-1}"
[ -n "$out" ] && printf '{"topic":"t","findings":[],"open_questions":[]}\n' > "$out"
echo ok
STUB
cat > "$TMP/stub/inject" <<'STUB'
#!/bin/bash
say() { printf '%s\n' "$1" > "$INJECT_PHASE_FILE"; printf '%s %s\n' "$(date '+%F %T.000')" "$1" >> "$INJECT_PHASE_FILE.log"; }
say waiting; say typing; say typed; say submitting
cat "$2" >> "$REC/injected.txt"; printf '\n===INJECT-BOUNDARY===\n' >> "$REC/injected.txt"
say submitted; say confirmed
STUB
chmod +x "$TMP/stub/"*
export SUPERVISOR_INJECT_CMD="$TMP/stub/inject" PATH="$TMP/stub:$PATH"

# A research pipeline, the shape the director asked for: web research, one position, a brief with
# its own instructions, Claude writing a report, and Codex reviewing the report.
P="$SUPERVISOR_STATE_DIR/pipelines/research-flow"; mkdir -p "$P/prompts"
cat > "$P/pipeline.json" <<'JSON'
{"schema":"bulava.pipeline/1","id":"research-flow","name":"Дослідження","revision":4,
 "nodes":[
  {"id":"ask","module":"bulava/trigger.chat@1"},
  {"id":"web","module":"bulava/prep.research@1","prompt":"prompts/web.md"},
  {"id":"pos","module":"bulava/prep.position@1","params":{"engine":"claude"}},
  {"id":"brf","module":"bulava/prep.compose@1","prompt":"prompts/brf.md"},
  {"id":"res","module":"bulava/agent.researcher@1"},
  {"id":"rr","module":"bulava/gate.reportReview@1","prompt":"prompts/rr.md"},
  {"id":"rep","module":"bulava/out.report@1"}],
 "edges":[
  {"from":"ask.task","to":"web.in"},{"from":"web.context","to":"pos.context"},{"from":"pos.position","to":"brf.in"},
  {"from":"brf.brief","to":"res.brief"},{"from":"res.report","to":"rr.report"},{"from":"rr.pass","to":"rep.in"},
  {"from":"rr.fail","to":"res.feedback","loop":{"max":2}}]}
JSON
printf 'RESEARCH-PROMPT-SENTINEL про {{TASK}}\n' > "$P/prompts/web.md"
printf 'PIPELINE-EXTRA-SENTINEL: пиши українською.\n' > "$P/prompts/brf.md"
printf 'Кожне твердження з джерелом.\n' > "$P/prompts/rr.md"
tool validate "$P" >/dev/null && ok "the research pipeline is valid" || bad "the research pipeline does not validate: $(tool validate "$P")"

send() { bash "$BIN/worker-send.sh" --mode conversation --message-id "$2" --pipeline "$3" "$PROJ" "sid-pb-1" "-" "RUN-PB-1" "$1" 2>&1; }
wait_quiet() {
  local i=0 max=$(( ${1:-60} * 4 ))
  while [ "$i" -lt "$max" ]; do
    if [ "$(pending_count "$IDIR")" = 0 ] && ! pipeline_running "$IDIR" && [ ! -d "$IDIR/pump.lock" ]; then return 0; fi
    sleep 0.25; i=$((i + 1))
  done
  return 1
}

echo "===== an unknown pipeline is refused before anything is queued ====="
out="$(send "Привіт" "00000000-0000-0000-0000-00000000dead" "no-such-flow")"; rc=$?
[ "$rc" != 0 ] && [ "$rc" != 5 ] && case "$out" in *"не знайдено"*) true ;; *) false ;; esac \
  && ok "worker-send refuses it with the reason, and the app gets an error to show" || bad "unknown pipeline: rc=$rc $out"
[ "$(pending_count "$IDIR")" = 0 ] && ok "and nothing was queued" || bad "an envelope was queued for a pipeline that does not exist"

echo "===== a built pipeline runs through the real route ====="
MID="aaaaaaaa-1111-2222-3333-444444444444"
out="$(send "Порівняй конструктори пайплайнів" "$MID" "research-flow")"; rc=$?
case "$out" in *"TIER=preparing"*) ok "it is accepted for preparation" ;; *) bad "send: rc=$rc $out" ;; esac
wait_quiet 90 || bad "the pump never finished"
ART="$(find "$IDIR/messages" -maxdepth 1 -type d -name "*-$MID" | head -1)"
[ -s "$ART/pipeline.compiled.json" ] && ok "the run compiled its own copy of the description" || bad "no compiled description in $ART"
[ -s "$ART/pipeline/pipeline.json" ] && [ -s "$ART/pipeline/prompts/web.md" ] && ok "and keeps a snapshot of it, prompts included" || bad "no snapshot"
[ "$(jq -c '[.stages[].id]' "$ART/pipeline.compiled.json")" = '["context","pos","brf","res"]' ] \
  && ok "the graph decided the stages: context → position → brief → worker" || bad "stages: $(jq -c '[.stages[].id]' "$ART/pipeline.compiled.json")"
[ "$(jq -r '[.[] | .stage] | join(",")' < <(jq -s . "$ART/stages.jsonl"))" = "context,pos,brf,res" ] \
  && ok "and the runner executed exactly those" || bad "executed: $(jq -s -c '[.[] | .stage]' "$ART/stages.jsonl")"
grep -l "RESEARCH-PROMPT-SENTINEL про Порівняй конструктори пайплайнів" "$REC"/codex-*.prompt >/dev/null 2>&1 \
  && ok "the research node forced web research, with the pipeline's own prompt and the task filled in" || bad "research was not run with the pipeline's prompt"
ls "$REC"/claude-*.prompt >/dev/null 2>&1 && ok "the one Claude position was formed" || bad "no position"
inj="$(cat "$REC/injected.txt" 2>/dev/null)"
case "$inj" in *"PIPELINE-EXTRA-SENTINEL"*) ok "the brief carries the pipeline's own text" ;; *) bad "the pipeline's brief text did not reach the worker" ;; esac
case "$inj" in *"[ДОСЛІДЖЕННЯ]"*) ok "and says this is research: a report, not code" ;; *) bad "no research section" ;; esac
case "$inj" in *"[ЗАВЕРШЕННЯ]"*) ok "while the outcome protocol is still there — a pipeline cannot talk it away" ;; *) bad "the outcome protocol was lost" ;; esac
jq -e '.pipeline == "research-flow" and .pipeline_gates.reportReview == true and .pipeline_gates.research == true and .pipeline_gates.reportMaxRounds == 2' "$IDIR/dispatch.json" >/dev/null \
  && ok "the dispatch record carries the gates the review must apply" || bad "dispatch gates: $(jq -c '{pipeline,pipeline_gates}' "$IDIR/dispatch.json")"

echo "===== every step left an event the chat can show ====="
EV="$IDIR/run-events.jsonl"
mine="$(jq -c --arg m "$MID" 'select(.message_id == $m) | [.stage, .state] | join(":")' "$EV" 2>/dev/null | tr -d '"' | tr '\n' ' ')"
for want in "pipeline:running" "context:running" "context:done" "pos:running" "pos:done" "brf:done" "res:running" "res:delivered" "pipeline:done"; do
  case " $mine " in *" $want "*) ok "event $want" ;; *) bad "missing event $want (have: $mine)" ;; esac
done
jq -e --arg m "$MID" 'select(.message_id == $m and .stage == "pipeline" and .state == "running") | .kind == "manifest" and (.stages | length) == 4' "$EV" >/dev/null 2>&1 \
  && ok "the opening event names the stages, so the chat can draw them before they run" || bad "the opening event is incomplete"
jq -e --arg m "$MID" 'select(.message_id == $m) | (.run_id == "RUN-PB-1") and (.dispatch_id | length > 0)' "$EV" >/dev/null 2>&1 \
  && ok "and each one is signed with its run and dispatch" || bad "events are not bound to the run"
first_ms="$(jq -r --arg m "$MID" 'select(.message_id == $m) | .ms' "$EV" | head -1)"
last_ms="$(jq -r --arg m "$MID" 'select(.message_id == $m) | .ms' "$EV" | tail -1)"
[ -n "$first_ms" ] && [ "$first_ms" -le "$last_ms" ] && ok "in the order they happened" || bad "events out of order"

echo "===== the snapshot is what the run used, whatever happens to the file later ====="
printf 'CHANGED-AFTER\n' > "$P/prompts/web.md"
grep -q RESEARCH-PROMPT-SENTINEL "$ART/pipeline/prompts/web.md" && ok "editing the pipeline afterwards does not touch the run's copy" || bad "the snapshot followed the live file"

echo "===== the built-in review team runs through the same route and hands its team to the gate ====="
MID2="bbbbbbbb-1111-2222-3333-444444444444"
out="$(send "Додай перевірку пароля" "$MID2" "review-team")"; rc=$?
case "$out" in *"TIER=preparing"*) ok "review-team is accepted for preparation" ;; *) bad "send review-team: rc=$rc $out" ;; esac
wait_quiet 120 || bad "the pump never finished review-team"
ART2="$(find "$IDIR/messages" -maxdepth 1 -type d -name "*-$MID2" | head -1)"
[ "$(jq -c '[.stages[].id]' "$ART2/pipeline.compiled.json" 2>/dev/null)" = '["context","peer-claude","peer-codex","align","compose","deliver"]' ] \
  && ok "it compiled Claude + Codex's stages from the engine's own description" || bad "review-team stages: $(jq -c '[.stages[].id]' "$ART2/pipeline.compiled.json" 2>/dev/null)"
jq -e '.pipeline == "review-team" and .pipeline_gates.reviewTeam == "contract security state" and .pipeline_gates.maxRounds == 3' "$IDIR/dispatch.json" >/dev/null \
  && ok "the dispatch record names the team the gate must use" || bad "dispatch gates: $(jq -c '{pipeline,pipeline_gates}' "$IDIR/dispatch.json")"

echo "===== a required stage failing inside a parallel group stops the run ====="
ENG="$TMP/engine"; mkdir -p "$ENG"
cp -R "$ENGINE_ROOT/bin" "$ENGINE_ROOT/supervisor" "$ENG/" 2>/dev/null
cat > "$ENG/bin/stage-fails.sh" <<'S'
#!/bin/bash
exit 1
S
cat > "$ENG/bin/stage-ok.sh" <<'S'
#!/bin/bash
sleep 1; exit 0
S
chmod +x "$ENG/bin/stage-fails.sh" "$ENG/bin/stage-ok.sh"
cat > "$ENG/supervisor/pipelines/grp-test.json" <<'JSON'
{"name":"grp-test","stages":[
 {"id":"a","group":"g","run":["stage-ok.sh"]},
 {"id":"b","group":"g","run":["stage-fails.sh"]},
 {"id":"c","run":["stage-ok.sh"]}]}
JSON
printf '{"message":"x","message_id":"bbbbbbbb-0000-0000-0000-000000000001","seq":"77","pipeline":"grp-test"}\n' > "$TMP/env.json"
bash "$ENG/bin/pipeline.sh" "$IDIR" "$TMP/env.json" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "the runner stops with an error" || bad "the runner went on (rc=$rc)"
ART2="$(find "$IDIR/messages" -maxdepth 1 -type d -name '77-*' | head -1)"
grep -q '"stage":"c"' "$ART2/stages.jsonl" 2>/dev/null && bad "the stage after the group still ran" || ok "and the stage after the group never ran"
jq -e 'select(.message_id == "bbbbbbbb-0000-0000-0000-000000000001" and .stage == "b") | .state == "failed"' "$EV" >/dev/null 2>&1 \
  && ok "the failed stage is an event, not a silence" || bad "no failed event for stage b"
sed -i.bak 's/"group":"g","run":\["stage-fails.sh"\]/"group":"g","optional":true,"run":["stage-fails.sh"]/' "$ENG/supervisor/pipelines/grp-test.json" && rm -f "$ENG/supervisor/pipelines/grp-test.json.bak"
printf '{"message":"x","message_id":"bbbbbbbb-0000-0000-0000-000000000002","seq":"78","pipeline":"grp-test"}\n' > "$TMP/env.json"
bash "$ENG/bin/pipeline.sh" "$IDIR" "$TMP/env.json" >/dev/null 2>&1; rc=$?
ART3="$(find "$IDIR/messages" -maxdepth 1 -type d -name '78-*' | head -1)"
[ "$rc" = 0 ] && grep -q '"stage":"c"' "$ART3/stages.jsonl" 2>/dev/null && ok "an OPTIONAL failure in the group still lets the run go on" || bad "optional group failure: rc=$rc"

echo "===== a new task sets the previous task's checks aside, and its brief names them ====="
cat > "$ENG/supervisor/pipelines/compose-only.json" <<'JSON'
{"name":"compose-only","stages":[{"id":"compose","run":["pipeline-compose.sh"]}]}
JSON
printf '{"id":"PREV-DISPATCH"}\n' > "$IDIR/dispatch.json"
printf '%s\n' '{"criterion":"форма зберігається","argv":["true"],"cwd":"/x"}' '{"criterion":"звіт будується","argv":["true","r"],"cwd":"/x"}' > "$IDIR/checks.jsonl"
printf '{"message":"Зовсім інша задача: логотип","message_id":"cccccccc-0000-0000-0000-000000000001","seq":"79","pipeline":"compose-only","relation":"new"}\n' > "$TMP/env.json"
bash "$ENG/bin/pipeline.sh" "$IDIR" "$TMP/env.json" >/dev/null 2>&1; rc=$?
ART4="$(find "$IDIR/messages" -maxdepth 1 -type d -name '79-*' | head -1)"
[ ! -s "$IDIR/checks.jsonl" ] && [ -s "$IDIR/dispatches/PREV-DISPATCH.checks.jsonl" ] \
  && ok "the previous task's checks are set aside under its dispatch" || bad "not set aside (rc=$rc)"
grep -q "«форма зберігається», «звіт будується»" "$ART4/composed.txt" 2>/dev/null \
  && ok "the new task's brief names them" || bad "the brief does not name them: $(grep -n 'Перевірки' "$ART4/composed.txt" 2>/dev/null)"
grep -q -- "--restore-all" "$ART4/composed.txt" 2>/dev/null && ok "with the way back" || bad "no way back in the brief"
printf '%s\n' '{"criterion":"цієї задачі","argv":["true","n"],"cwd":"/x"}' > "$IDIR/checks.jsonl"
printf '{"message":"Ще поправ відступ","message_id":"cccccccc-0000-0000-0000-000000000002","seq":"80","pipeline":"compose-only","relation":"continue"}\n' > "$TMP/env.json"
bash "$ENG/bin/pipeline.sh" "$IDIR" "$TMP/env.json" >/dev/null 2>&1
ART5="$(find "$IDIR/messages" -maxdepth 1 -type d -name '80-*' | head -1)"
grep -q "цієї задачі" "$IDIR/checks.jsonl" && ok "a follow-up keeps its own checks" || bad "a follow-up lost its checks"
grep -q "відкладено" "$ART5/composed.txt" 2>/dev/null && bad "a follow-up's brief repeats the set-aside note" || ok "and its brief does not repeat the note"

echo
if [ "$fails" = 0 ]; then echo "✅ pipeline builder: all passed"; exit 0; fi
echo "❌ pipeline builder: $fails failed"; exit 1
