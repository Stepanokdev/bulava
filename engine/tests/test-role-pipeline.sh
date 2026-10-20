#!/bin/bash
# A pipeline of roles: triage, then an analyst (Codex) beside a tester (Claude), then two architects
# (Claude, Codex) who read both, then an agreement, Claude does the work and Codex reviews it.
#
# What used to break it: every position got the same prompt, two Claude roles wrote the same file,
# an architect could not take the analyst's result as input at all, and the agreement read only
# `peer-claude.md` and `peer-codex.md`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------- the description
M="$TMP/m"; mkdir -p "$M"
cat > "$M/pipeline.json" <<'JSON'
{"schema":"bulava.pipeline/1","id":"roles-test","name":"Ролі","description":"тест","revision":1,
 "nodes":[
  {"id":"chat","module":"bulava/trigger.chat@1"},
  {"id":"context","module":"bulava/prep.context@1"},
  {"id":"triage","module":"bulava/prep.classify@1","title":"Тріаж"},
  {"id":"ba","module":"bulava/prep.position@1","title":"Бізнес-аналітик","params":{"engine":"codex","required":true},"prompt":"BA-PROMPT-SENTINEL: опиши вимоги до {{TASK}}"},
  {"id":"qa","module":"bulava/prep.position@1","title":"Тестувальник","params":{"engine":"claude","required":true},"prompt":"QA-PROMPT-SENTINEL: напиши тест-кейси"},
  {"id":"arch-claude","module":"bulava/prep.position@1","title":"Архітектор Claude","params":{"engine":"claude","required":true},"prompt":"ARCH-PROMPT-SENTINEL"},
  {"id":"arch-codex","module":"bulava/prep.position@1","title":"Архітектор Codex","params":{"engine":"codex","required":true},"prompt":"ARCH-PROMPT-SENTINEL"},
  {"id":"agree","module":"bulava/prep.align@1","title":"Домовленість","params":{"required":true}},
  {"id":"compose","module":"bulava/prep.compose@1"},
  {"id":"deliver","module":"bulava/agent.claude@1"},
  {"id":"review","module":"bulava/gate.review@1"},
  {"id":"merge","module":"bulava/out.merge@1"}],
 "edges":[
  {"from":"chat.task","to":"context.task"},{"from":"chat.task","to":"triage.task"},
  {"from":"context.context","to":"ba.context"},{"from":"triage.context","to":"ba.context"},
  {"from":"context.context","to":"qa.context"},{"from":"triage.context","to":"qa.context"},
  {"from":"ba.position","to":"arch-claude.context"},{"from":"qa.position","to":"arch-claude.context"},
  {"from":"ba.position","to":"arch-codex.context"},{"from":"qa.position","to":"arch-codex.context"},
  {"from":"arch-claude.position","to":"agree.positions"},{"from":"arch-codex.position","to":"agree.positions"},
  {"from":"agree.checks","to":"compose.in"},{"from":"compose.brief","to":"deliver.brief"},
  {"from":"deliver.work","to":"review.work"},{"from":"review.pass","to":"merge.work"},{"from":"review.fail","to":"deliver.feedback","loop":{"max":3}}]}
JSON

echo "===== it validates and compiles into two phases of roles ====="
python3 "$BIN/pipeline-tool.py" validate "$M" > "$TMP/v.json" 2>&1 \
  && ok "the description is valid" || bad "invalid: $(cat "$TMP/v.json" | head -c 600)"
SNAP="$TMP/snap"; mkdir -p "$SNAP"
python3 "$BIN/pipeline-tool.py" compile "$M" --out "$TMP/c.json" --snapshot "$SNAP" > /dev/null 2>"$TMP/c.err" \
  && ok "it compiles" || bad "compile failed: $(cat "$TMP/c.err")"
C="$TMP/c.json"
stage() { jq -c --arg id "$1" '.stages[] | select(.id == $id)' "$C"; }
grp() { jq -r --arg id "$1" '.stages[] | select(.id == $id) | .group // ""' "$C"; }
[ -n "$(grp ba)" ] && [ "$(grp ba)" = "$(grp qa)" ] && ok "the analyst and the tester run side by side" || bad "phase 1: $(grp ba) / $(grp qa)"
[ -n "$(grp arch-claude)" ] && [ "$(grp arch-claude)" = "$(grp arch-codex)" ] && [ "$(grp arch-claude)" != "$(grp ba)" ] \
  && ok "the two architects run side by side, after them" || bad "phase 2: $(grp arch-claude) / $(grp arch-codex)"
order="$(jq -r '[.stages[].id] | join(" ")' "$C")"
case "$order" in *"ba"*"arch-claude"*"agree"*"compose"*"deliver"*) ok "in that order: $order" ;; *) bad "order: $order" ;; esac
stage arch-claude | jq -e '.run | index("--reads") as $i | .[$i+1] | (contains("ba") and contains("qa"))' >/dev/null \
  && ok "an architect reads the analyst and the tester" || bad "reads: $(stage arch-claude)"
stage arch-claude | jq -e '.run | index("--reads") as $i | .[$i+1] | contains("arch-codex") | not' >/dev/null \
  && ok "but not the other architect" || bad "an architect reads its peer"
[ "$(stage ba | jq -r '.run | index("--role-prompt") as $i | .[$i+1]')" != "$(stage qa | jq -r '.run | index("--role-prompt") as $i | .[$i+1]')" ] \
  && ok "each role has its own prompt" || bad "the roles share a prompt"
[ "$(stage ba | jq -r .optional)" = false ] && [ "$(stage agree | jq -r .optional)" = false ] \
  && ok "required roles and the agreement are not optional" || bad "optional: $(stage ba | jq -r .optional) $(stage agree | jq -r .optional)"
stage agree | jq -e '.run | index("--roles") as $i | .[$i+1] | (contains("ba") and contains("qa") and contains("arch-claude") and contains("arch-codex"))' >/dev/null \
  && ok "the agreement reads every role" || bad "agree: $(stage agree)"
[ "$(jq -r '.brief.roles | map(.title) | join(",")' "$C")" = "Бізнес-аналітик,Тестувальник,Архітектор Claude,Архітектор Codex" ] \
  && ok "the brief names the roles" || bad "brief roles: $(jq -c .brief.roles "$C")"

echo
echo "===== the classic two positions are left exactly as they were ====="
python3 "$BIN/pipeline-tool.py" compile "$ROOT/supervisor/pipelines/manifests/adaptive-peer" --out "$TMP/a.json" --snapshot "$TMP/asnap" >/dev/null 2>&1
jq -e '[.stages[] | select(.run | index("--role"))] | length == 0' "$TMP/a.json" >/dev/null \
  && ok "no roles in the built-in pipeline" || bad "the built-in pipeline turned into roles"
jq -e '.stages[] | select(.id == "peer-claude") | .optional == true' "$TMP/a.json" >/dev/null \
  && ok "and its positions stay optional" || bad "built-in positions changed"

echo
echo "===== the roles run: own prompt, own result, the later phase reads the earlier one ====="
PROJ="$TMP/proj"; mkdir -p "$PROJ"; ( cd "$PROJ" && git init -q )
ART="$TMP/art"; mkdir -p "$ART" "$TMP/stub" "$TMP/rec"
export REC="$TMP/rec"
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
prompt=""; for a in "$@"; do prompt="$a"; done
n=$(( $(ls "$REC" | grep -c '^claude-') + 1 ))
printf '%s' "$prompt" > "$REC/claude-$n.prompt"
title="$(printf '%s' "$prompt" | sed -n 's/^# ТВОЯ РОЛЬ: //p' | head -1)"
printf 'RESULT-OF %s from claude\n' "${title:-?}"
STUB
cat > "$TMP/stub/codex" <<'STUB'
#!/bin/bash
[ "${1:-}" = login ] && { echo "Logged in using ChatGPT"; exit 0; }
out=""; prev=""; prompt=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prompt="$a"; prev="$a"; done
n=$(( $(ls "$REC" | grep -c '^codex-') + 1 ))
printf '%s' "$prompt" > "$REC/codex-$n.prompt"
title="$(printf '%s' "$prompt" | sed -n 's/^# ТВОЯ РОЛЬ: //p' | head -1)"
[ -n "$out" ] && printf 'RESULT-OF %s from codex\n' "${title:-AGREEMENT}" > "$out"
STUB
chmod +x "$TMP/stub/claude" "$TMP/stub/codex"
export PATH="$TMP/stub:$PATH" SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true SUPERVISOR_CLAUDE_USAGE_CMD=/usr/bin/true SUPERVISOR_PEER_POLL=1
run() {  # the stage's own argv from the compiled description
  local -a argv=(); local a
  while IFS= read -r a; do argv+=("$a"); done < <(stage "$1" | jq -r '.run[]')
  "$BIN/${argv[0]}" --art "$ART" "${argv[@]:1}" "$PROJ" "Додай експорт у CSV" >/dev/null 2>&1
}
echo "контекст задачі" > "$ART/context.md"
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$ART/.preflight-deadline"
run ba; run qa
grep -q "RESULT-OF Бізнес-аналітик from codex" "$ART/role-ba.md" 2>/dev/null && ok "the analyst's result is its own file" || bad "role-ba.md: $(cat "$ART/role-ba.md" 2>&1)"
grep -q "RESULT-OF Тестувальник from claude" "$ART/role-qa.md" 2>/dev/null && ok "so is the tester's" || bad "role-qa.md: $(cat "$ART/role-qa.md" 2>&1)"
grep -l "BA-PROMPT-SENTINEL" "$REC"/codex-*.prompt >/dev/null 2>&1 && grep -q "Додай експорт у CSV" "$(grep -l BA-PROMPT-SENTINEL "$REC"/codex-*.prompt)" \
  && ok "the analyst got its own prompt, with the task in it" || bad "the analyst's prompt"
grep -l "QA-PROMPT-SENTINEL" "$REC"/claude-*.prompt >/dev/null 2>&1 && ! grep -q "BA-PROMPT-SENTINEL" "$REC"/claude-*.prompt \
  && ok "the tester got its own, not the analyst's" || bad "the tester's prompt"
run arch-claude; run arch-codex
a="$(grep -l "ARCH-PROMPT-SENTINEL" "$REC"/claude-*.prompt | head -1)"
grep -q "RESULT-OF Бізнес-аналітик" "$a" && grep -q "RESULT-OF Тестувальник" "$a" \
  && ok "an architect reads what the analyst and the tester concluded" || bad "the architect did not see phase 1"
grep -q "RESULT-OF Тестувальник from claude" "$ART/role-qa.md" && grep -q "Архітектор Claude" "$ART/role-arch-claude.md" \
  && ok "two Claude roles keep separate results" || bad "a Claude role overwrote another"
# Two Claude roles at once, as two in one phase run: each must come back with its own answer. A
# shared stream file let the second call's truncation and output land in the first one's answer.
rm -f "$ART/role-qa.md" "$ART/role-arch-claude.md"
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
prompt=""; for a in "$@"; do prompt="$a"; done
title="$(printf '%s' "$prompt" | sed -n 's/^# ТВОЯ РОЛЬ: //p' | head -1)"
case "$title" in Тестувальник) sleep 3 ;; *) sleep 1 ;; esac
printf 'RESULT-OF %s from claude\n' "${title:-?}"
STUB
chmod +x "$TMP/stub/claude"
run qa & run arch-claude & wait
grep -q "RESULT-OF Тестувальник" "$ART/role-qa.md" 2>/dev/null && ! grep -q "Архітектор" "$ART/role-qa.md" \
  && grep -q "RESULT-OF Архітектор Claude" "$ART/role-arch-claude.md" 2>/dev/null && ! grep -q "Тестувальник" "$ART/role-arch-claude.md" \
  && ok "two Claude roles running at once each keep their own answer" \
  || bad "concurrent Claude roles mixed: qa=«$(cat "$ART/role-qa.md" 2>&1)» arch=«$(cat "$ART/role-arch-claude.md" 2>&1)»"
run agree; rc=$?
[ "$rc" = 0 ] && [ -s "$ART/peer-alignment.md" ] && ok "the agreement is written" || bad "agreement rc=$rc"
p="$(ls -t "$REC"/codex-*.prompt | head -1)"
for t in "Бізнес-аналітик" "Тестувальник" "Архітектор Claude" "Архітектор Codex"; do
  grep -q "Роль «${t}»" "$p" || bad "the agreement did not get ${t}"
done
grep -q "Роль «Архітектор Codex»" "$p" && ok "it is made from every role's result" || true
cmp -s "$ART/plan.md" "$ART/peer-alignment.md" && ok "and it becomes the plan the work and the review follow" || bad "plan.md is not the agreement"

echo
echo "===== a required role that fails stops the pipeline, and says why ====="
cat > "$TMP/stub/claude" <<'STUB'
#!/bin/bash
echo "boom" >&2; exit 1
STUB
chmod +x "$TMP/stub/claude"
run qa; rc=$?
[ "$rc" != 0 ] && ok "the stage reports the failure (exit $rc), so the runner stops on a required role" || bad "a failed role exited 0"
[ -s "$ART/role-qa.unavailable" ] && ok "and the reason is written under the role's name" || bad "no reason for the tester"

echo
[ "$fails" = 0 ] && { echo "✅ role pipeline: all passed"; exit 0; } || { echo "❌ role pipeline: $fails failure(s)"; exit 1; }
