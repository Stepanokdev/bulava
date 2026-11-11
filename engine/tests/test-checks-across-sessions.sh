#!/bin/bash
# The checks a worker registered go on with the conversation, the whole way, with Jev off.
#
# A conversation continued in a new session started with no checks (Tenders 5 and 6 Nov, VSO-2023):
# the run folder that held them was gone. Kept and brought back by the resume, they then met the
# first message — "go on" — which the engine, with no task record to continue (Jev off), takes for
# a new task, and set them aside again. Pinned, through the real start, stop, resume, pipeline and
# verifier:
#   1. stop → resume → "go on" → the verifier runs the checks registered before the stop;
#   2. a new task said outright after the resume sets them aside, as for any new task;
#   3. a check removed after a resume does not come back with the next one;
#   4. checks set aside by a new task do not come back with the next resume.
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$SRC/tests/lib-tmux.sh"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_JEV_MODE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP SUPERVISOR_PLAIN_FOLDER SUPERVISOR_UNATTENDED TYPESAFE_API_KEY
export SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# The engine as it is, with one pipeline that only composes — no stage reaches a model or the pane.
ENG="$TMP/engine"; mkdir -p "$ENG"; cp -R "$SRC/bin" "$SRC/supervisor" "$SRC/hooks" "$ENG/" 2>/dev/null
cat > "$ENG/supervisor/pipelines/compose-only.json" <<'JSON'
{"name":"compose-only","stages":[{"id":"compose","run":["pipeline-compose.sh"]}]}
JSON
NS="$ENG/bin/night-shift.sh"; ADD="$ENG/bin/add-check.sh"
. "$ENG/bin/supervisor-lib.sh"
[ "$(jev_mode)" = off ] && ok "Jev is off, as by default" || bad "Jev is $(jev_mode)"

P="$TMP/reports-api"; mkdir -p "$P"
( cd "$P" && git init -q && git config user.email t@t && git config user.name t && echo x > f.txt && git add -A && git commit -qm init )
SLUG="$(slug_for "$(canon_path "$P")")"; IDIR="$(instance_dir "$SLUG")"; SES="$(session_name "$SLUG")"
APP=(env SUPERVISOR_RUN_ENV_FROM_APP=1 "SUPERVISOR_APP_ANSWERS=dirty mcp git heavy")
n=0
message() {   # $1 = text — through the pipeline, as the engine relays it, with the relation it would bind
  n=$((n + 1))
  local rel; rel="$(thread_bind "$IDIR" "$1" "m$n" "$((90 + n))" | awk '{print $1}')"
  jq -nc --arg m "$1" --arg id "dddddddd-0000-0000-0000-00000000000$n" --arg seq "$((90 + n))" --arg rel "$rel" \
     '{message:$m, message_id:$id, seq:$seq, pipeline:"compose-only", relation:$rel}' > "$TMP/env.json"
  bash "$ENG/bin/pipeline.sh" "$IDIR" "$TMP/env.json" >/dev/null 2>&1
  LAST_REL="$rel"
}
stop_it() { bash "$NS" stop "$P" >/dev/null 2>&1; tmux kill-session -t "$SES" 2>/dev/null; }
resume_it() { SUPERVISOR_ENABLE_RESUME=1 bash "$NS" resume "$P" "00000000-0000-4000-8000-00000000c0$1" - --no-attach >/dev/null 2>&1; }
names() { jq -r '.criterion' "$IDIR/checks.jsonl" 2>/dev/null | sort | tr '\n' '|'; }

echo "===== 1. stop → resume → «go on» → the verifier runs the checks from before the stop ====="
"${APP[@]}" bash "$NS" start "$P" --no-attach >/dev/null 2>&1
message "Додай фільтр звітів за статусом"
( cd "$P" && IDIR="$IDIR" bash "$ADD" "фільтр звітів працює" -- true filter >/dev/null 2>&1 )
[ "$(names)" = "фільтр звітів працює|" ] && ok "registered" || bad "not registered: $(names)"
stop_it
[ -d "$IDIR" ] && bad "the run folder is still there" || ok "stopped: the run folder that held them is gone"
resume_it 01
[ "$(names)" = "фільтр звітів працює|" ] && ok "the resume brought them back" || bad "the resume did not: $(names)"
message "продовжуй"
[ "$LAST_REL" = new ] && ok "with Jev off, the engine took «продовжуй» for a new task (no task record)" || bad "relation was $LAST_REL"
[ "$(names)" = "фільтр звітів працює|" ] && ok "and still the checks are this conversation's" || bad "set aside by the first message: $(names)"
bash "$ENG/bin/verify.sh" "$P" sess-1 "$IDIR" "$(git -C "$P" rev-parse HEAD)" >/dev/null 2>&1
jq -e '.criteria[] | select(.criterion == "фільтр звітів працює") | .status == "pass"' "$IDIR/evidence/sess-1/evidence.json" >/dev/null 2>&1 \
  && ok "the verifier ran it" || bad "the verifier did not run it"
message "і ще відступ поправ"
[ "$(names)" = "фільтр звітів працює|" ] && ok "a later message of the new session keeps them like any follow-up" || bad "lost later: $(names) (relation $LAST_REL)"

echo "===== 2. a new task said outright after the resume sets them aside ====="
stop_it; resume_it 02
[ "$(names)" = "фільтр звітів працює|" ] && ok "brought back again" || bad "not brought back: $(names)"
message "Це нова задача: експорт у CSV"
[ -z "$(names)" ] && ok "a new task said outright: set aside" || bad "kept for a new task: $(names)"
ls "$IDIR"/dispatches/*.checks.jsonl >/dev/null 2>&1 && ok "kept under the task they belonged to" || bad "not on disk"

echo "===== 4. set aside by a new task, they do not come back with the next resume ====="
stop_it; resume_it 03
[ -z "$(names)" ] && ok "nothing came back" || bad "came back: $(names)"

echo "===== 3. a check removed after a resume stays removed ====="
( cd "$P" && IDIR="$IDIR" bash "$ADD" "CSV відкривається в Excel" -- true csv >/dev/null 2>&1 )
stop_it; resume_it 04
[ "$(names)" = "CSV відкривається в Excel|" ] && ok "the new task's check came back" || bad "not back: $(names)"
( cd "$P" && IDIR="$IDIR" bash "$ADD" --remove "CSV відкривається в Excel" >/dev/null 2>&1 )
[ -z "$(names)" ] && ok "removed" || bad "not removed: $(names)"
stop_it; resume_it 05
[ -z "$(names)" ] && ok "and the next resume does not bring it back" || bad "it came back: $(names)"
stop_it

[ "$fails" -eq 0 ] && { echo "✅ checks across sessions: all passed"; exit 0; } || { echo "❌ checks across sessions: $fails failed"; exit 1; }
