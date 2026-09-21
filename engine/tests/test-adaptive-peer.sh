#!/bin/bash
# The experimental collaboration flow: independent views before work and an uncapped precise
# consultation channel while Claude implements. Model calls are stubbed; orchestration is real.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✅ $1"; }
bad(){ echo "  ❌ $1"; fails=$((fails + 1)); }

mkdir -p "$TMP/state" "$TMP/project" "$TMP/stub"
export SUPERVISOR_STATE_DIR="$TMP/state"
cat > "$TMP/stub/claude" <<'EOF'
#!/bin/bash
echo 'REAL GOAL — finished
APPROACH — repository pattern
MISSED REQUIREMENTS AND EDGE CASES — lifecycle
REPOSITORY EVIDENCE — source
PROOF — test'
EOF
cat > "$TMP/stub/codex" <<'EOF'
#!/bin/bash
# Not a turn. The engine asks the real CLI this before spending a call, and a stub that
# treated it as a brief would record "login status" as the run's prompt and depth.
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; json=0; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  [ "$a" = "--json" ] && json=1
  prev="$a"
done
answer='RECOMMENDATION — inspect both paths
MISSED RISKS — cleanup
REPOSITORY EVIDENCE — source
PROOF — focused test
CONFIDENCE — high'
[ -n "$out" ] && printf '%s\n' "$answer" > "$out"
if [ "$json" = 1 ]; then
  echo '{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":7}}'
else
  printf '%s\n' "$answer"
fi
EOF
cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0,"window_minutes":300}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
EOF
chmod +x "$TMP/stub/claude" "$TMP/stub/codex" "$TMP/stub/usage"

echo "===== even a small task gets two independent positions ====="
PATH="$TMP/stub:$PATH" SUPERVISOR_DESIGN_RESEARCH=0 SUPERVISOR_PLAN_TIMEOUT=20 \
  bash "$BIN/preflight.sh" "$TMP/project" "Виправ опечатку" >/dev/null 2>&1
. "$BIN/supervisor-lib.sh"
IDIR="$(instance_dir "$(slug_for "$TMP/project")")"
for f in peer-claude.md peer-codex.md peer-alignment.md plan.md; do
  [ -s "$IDIR/$f" ] && ok "$f produced" || bad "$f missing"
done

echo "===== the worker gets alignment and an uncapped consultation channel ====="
ln -s "$BIN/consult-codex.sh" "$IDIR/consult-codex"
prompt="$(compose_task_prompt "$IDIR" "Виправ опечатку")"
for f in peer-claude.md peer-codex.md peer-alignment.md; do case "$prompt" in *"$f"*) :;; *) bad "$f absent from worker prompt";; esac; done
case "$prompt" in *"Числового ліміту консультацій НЕМАЄ"*) ok "prompt explicitly has no numeric cap";; *) bad "consultations appear capped";; esac
case "$prompt" in *"фінальне рішення за тобою"*) ok "Claude remains the decision maker";; *) bad "decision ownership is unclear";; esac

echo "===== repeated consultations are recorded, never rejected by a call budget ====="
printf '%s\n' RUN-TEST > "$IDIR/run-id"
printf '%s\n' "$(canon_path "$TMP/project")" > "$IDIR/project"
jq -n --arg id D-1 --arg task test '{id:$id,task:$task}' > "$IDIR/dispatch.json"
for n in 1 2 3; do
  ( cd "$TMP/project" && PATH="$TMP/stub:$PATH" ORCHESTRATOR_RUN_ID=RUN-TEST \
      SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage" bash "$BIN/consult-codex.sh" "question $n" ) >/dev/null 2>&1 \
    || bad "consultation $n was refused"
done
[ "$(find "$IDIR/consultations/RUN-TEST" -name metrics.json | wc -l | tr -d ' ')" = 3 ] \
  && ok "three calls have separate metrics" || bad "consultation records are incomplete"
jq -e '.usage.input_tokens == 11 and .usage.output_tokens == 7' \
  "$IDIR/consultations/RUN-TEST/0003/metrics.json" >/dev/null 2>&1 \
  && ok "token usage is retained" || bad "token usage missing"

echo "===== the night dispatcher and the chat run the SAME pipeline ====="
#
# This section used to grep prepare-and-inject.sh for the word "preflight" and call that proof that
# "direct app dispatch performs preflight before injection". It passed on the night the chat shipped
# a raw task to the worker, because the chat does not go through prepare-and-inject.sh at all. What
# is asserted now is the shape of the pipeline itself, and the guard is executed rather than read.
grep -q 'prepare-and-inject.sh' "$BIN/dispatch.sh" && ok "dispatch uses the prepared path" || bad "dispatch still bypasses it"
grep -q 'pipeline.sh' "$BIN/prepare-and-inject.sh" && ok "and the prepared path is the shared runner" || bad "the dispatcher has its own private route again"
grep -q -- '--pipeline' "$BIN/worker-send.sh" && ok "a message from the app can name its pipeline" || bad "worker-send.sh cannot be asked to prepare anything"

DEFS="$(cd "$BIN/.." && pwd)/supervisor/pipelines"
for name in adaptive-peer dispatch; do
  order="$(jq -r '[.stages[].id] | join(" ")' "$DEFS/$name.json" 2>/dev/null)"
  case "$order" in
    *"peer-claude peer-codex align"*) ok "$name: the comparison comes after both positions" ;;
    *) bad "$name stages are out of order: $order" ;;
  esac
  case "$order" in
    *"align compose deliver") ok "$name: composition and hand-over come last" ;;
    *) bad "$name does not end with compose → deliver: $order" ;;
  esac
  [ "$(jq -r '[.stages[] | select(.group == "peers") | .id] | length' "$DEFS/$name.json")" = 2 ] \
    && ok "$name: the two positions are one parallel group" || bad "$name does not run the positions together"
done

echo "===== a superseded dispatch cannot inject, even after its preflight finishes ====="
mkdir -p "$TMP/guard"
printf '%s\n' "$(canon_path "$TMP/project")" > "$IDIR/project"
printf '%s\n' "night-guard-test" > "$IDIR/session"
jq -nc '{id:"NEWER-DISPATCH"}' > "$IDIR/dispatch.json"
jq -nc '{seq:"guard", pipeline:"plain", intent:"conversation", message:"stale work",
         dispatch_id:"OLDER-DISPATCH", guard_dispatch:"OLDER-DISPATCH"}' > "$TMP/guard/envelope.json"
cat > "$TMP/guard/inject" <<'EOF'
#!/bin/bash
echo "INJECTED" >> "$GUARD_MARK"
EOF
chmod +x "$TMP/guard/inject"
GUARD_MARK="$TMP/guard/injected" SUPERVISOR_INJECT_CMD="$TMP/guard/inject" \
  bash "$BIN/pipeline.sh" "$IDIR" "$TMP/guard/envelope.json" >/dev/null 2>&1
rc=$?
[ "$rc" = 7 ] && ok "the runner stops a superseded dispatch (exit 7)" || bad "a superseded dispatch ran on (exit $rc)"
[ -s "$TMP/guard/injected" ] && bad "it injected anyway" || ok "and nothing reached the worker"

echo
[ "$fails" = 0 ] && echo "✅ adaptive peer: all passed" || echo "❌ adaptive peer: $fails failure(s)"
exit "$fails"
