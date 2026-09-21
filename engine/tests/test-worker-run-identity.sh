#!/bin/bash
# A worker's tools follow the WORKER, not the folder it happens to be standing in.
#
# The engine hands a worker `--add-dir` repositories to read and its own instance folder to keep
# notes in. Both were places where the run "disappeared": the scope was resolved by matching $PWD
# against the instance's project path, so the moment Claude stepped out of the project
#
#   - `consult-codex` refused with "available only inside the active supervised run", and Claude
#     wrote "I am deciding this myself" as though that were an engineering judgement;
#   - `report-outcome` and `report-finding` printed a notice to stderr and exited ZERO, so the
#     worker believed it had declared a result while nothing had been written and the run sat in
#     Executing until a watchdog parked it;
#   - `add-check` and `challenge-criterion` failed from a mere SUBFOLDER of the project, because
#     they matched the path exactly.
#
# What this pins: the run is identified by ORCHESTRATOR_RUN_ID — stamped on the launch line, not
# guessable — so every tool works from anywhere; a token that names no live run fails LOUDLY
# instead of pretending; and no token at all still refuses, exactly as before.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN/supervisor-lib.sh"

mk_repo() {   # $1=path
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  printf 'one\n' > "$1/a.txt"; git -C "$1" add -A; git -C "$1" commit -qm base
}

PROJ="$TMP/repo"; mk_repo "$PROJ"; PROJ="$(canon_path "$PROJ")"
mkdir -p "$PROJ/sub/deeper"
NEIGHBOUR="$TMP/other-repo"; mk_repo "$NEIGHBOUR"; NEIGHBOUR="$(canon_path "$NEIGHBOUR")"

RID="11111111-2222-3333-4444-555555555555"
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf '%s\n' "$RID"  > "$IDIR/run-id"
printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
jq -n --arg id D-1 --arg task "полагодь консультацію" '{id:$id,task:$task}' > "$IDIR/dispatch.json"

# A SECOND live run, on the neighbouring repository. Nothing addressed to the first may ever land
# in it — that is the whole security property the old folder match was providing.
RID2="99999999-8888-7777-6666-555555555555"
IDIR2="$(instance_dir "$(slug_for "$NEIGHBOUR")")"; mkdir -p "$IDIR2"
printf '%s\n' "$NEIGHBOUR" > "$IDIR2/project"
printf '%s\n' "$RID2"      > "$IDIR2/run-id"

# Every place a worker legitimately finds itself.
WHERE="$PROJ|$PROJ/sub/deeper|$IDIR|$NEIGHBOUR|$TMP"

echo "===== report-finding lands from every folder a worker is given ====="
n=0
IFS='|'; for d in $WHERE; do unset IFS
  n=$((n + 1))
  ( cd "$d" && ORCHESTRATOR_RUN_ID="$RID" bash "$BIN/report-finding.sh" pre_existing "finding from $d" ) >/dev/null 2>&1 \
    || bad "report-finding refused from $d"
done
got="$(grep -c . "$IDIR/findings.jsonl" 2>/dev/null || echo 0)"
[ "$got" = "$n" ] && ok "$n findings recorded from $n different folders" \
                  || bad "expected $n findings, got $got"
[ -s "$IDIR2/findings.jsonl" ] && bad "a finding leaked into the OTHER run" \
                               || ok "the neighbouring run received nothing"

echo "===== report-outcome lands from the instance folder and from a neighbouring repo ====="
for d in "$IDIR" "$NEIGHBOUR"; do
  rm -f "$IDIR/outcome.json"
  ( cd "$d" && ORCHESTRATOR_RUN_ID="$RID" bash "$BIN/worker-outcome.sh" succeeded_changes "done from $d" ) >/dev/null 2>&1
  if [ -s "$IDIR/outcome.json" ]; then ok "outcome recorded from $(basename "$d")"
  else bad "outcome NOT recorded from $d"; fi
done
# The receipt describes the run's repository, never whichever tree the worker was standing in.
[ "$(jq -r '.project_name // ""' "$IDIR/report/receipt.json" 2>/dev/null)" = "$(basename "$PROJ")" ] \
  && ok "the receipt names the run's own project" \
  || bad "the receipt named $(jq -r '.project_name // "?"' "$IDIR/report/receipt.json" 2>/dev/null)"
[ -s "$IDIR2/outcome.json" ] && bad "an outcome leaked into the OTHER run" \
                             || ok "the neighbouring run has no outcome"

echo "===== add-check and challenge-criterion work from a SUBFOLDER ====="
( cd "$PROJ/sub/deeper" && ORCHESTRATOR_RUN_ID="$RID" bash "$BIN/add-check.sh" "AC-1: кнопка видима" -- /usr/bin/true ) >/dev/null 2>&1
[ -s "$IDIR/checks.jsonl" ] && ok "a check registered from a subfolder" || bad "add-check still needs the exact project path"

printf '%s' '{"schema":1,"mode":"patch","task_id":"T-1","objective":"o","acceptance":["перевір у демо-акаунті"],"write_paths":["x"]}' > "$IDIR/runspec.json"
( cd "$PROJ/sub" && ORCHESTRATOR_RUN_ID="$RID" bash "$BIN/challenge-criterion.sh" \
    AC-001 impossible_precondition "перевірити поза демо-режимом" "a.txt:1 — кнопки немає в демо" ) >/dev/null 2>&1
[ -s "$IDIR/challenges.jsonl" ] && ok "a criterion challenge filed from a subfolder" \
  || bad "challenge-criterion still needs the exact project path"

echo "===== a token that names no live run fails LOUDLY, and writes nothing ====="
before="$(grep -c . "$IDIR/findings.jsonl" 2>/dev/null || echo 0)"
( cd "$PROJ" && ORCHESTRATOR_RUN_ID=GONE-RUN bash "$BIN/report-finding.sh" blocker "з мертвого прогону" ) >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "report-finding exits non-zero (rc=$rc)" || bad "a lost run still reported success"
[ "$(grep -c . "$IDIR/findings.jsonl" 2>/dev/null || echo 0)" = "$before" ] \
  && ok "and recorded nothing" || bad "it wrote into a run it does not belong to"

rm -f "$IDIR/outcome.json"
( cd "$PROJ" && ORCHESTRATOR_RUN_ID=GONE-RUN bash "$BIN/worker-outcome.sh" succeeded_changes "x" ) >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "report-outcome exits non-zero (rc=$rc)" || bad "the outcome protocol still fakes success"
[ -e "$IDIR/outcome.json" ] && bad "it wrote an outcome anyway" || ok "and recorded nothing"

echo "===== no token at all stays a quiet no-op — a hand-run owes nobody a result ====="
( cd "$PROJ" && env -u ORCHESTRATOR_RUN_ID bash "$BIN/worker-outcome.sh" succeeded_changes "hand run" ) >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "worker-outcome exits 0 outside a run" || bad "an unsupervised call must not fail (rc=$rc)"
[ -e "$IDIR/outcome.json" ] && bad "an unsupervised shell recorded an outcome" || ok "and nothing was written"

echo "===== a run replaced under the tool's feet is refused, not overwritten ====="
# Resolve, then let a NEW run take the same folder before the write. The old process must not file
# its result as the verdict on the new one.
printf '%s\n' "$RID" > "$IDIR/run-id"
( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" bash -c '
    . "'"$BIN"'/supervisor-lib.sh"
    printf "%s\n" "a-brand-new-run" > "'"$IDIR"'/run-id"
    exec bash "'"$BIN"'/report-finding.sh" blocker "stale" ' ) >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "a superseded run cannot write (rc=$rc)" || bad "a stale process wrote into the new run"
printf '%s\n' "$RID" > "$IDIR/run-id"

echo "===== consult-codex: reachable from anywhere, and honest when Codex is not ====="
mkdir -p "$TMP/stub"
cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0,"window_minutes":300}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
EOF
# Answers normally, and records the directory it was actually started in.
cat > "$TMP/stub/codex" <<'EOF'
#!/bin/bash
pwd > "$CODEX_CWD_RECORD"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf 'RECOMMENDATION — ok\nCONFIDENCE — high\n' > "$out"
echo '{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":2}}'
EOF
# Exits cleanly and says nothing at all.
cat > "$TMP/stub/codex-mute" <<'EOF'
#!/bin/bash
exit 0
EOF
# Signed out: answers `login status` the way a real Codex does when the session is gone.
cat > "$TMP/stub/codex-signedout" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then echo "Not logged in" >&2; exit 1; fi
sleep 20   # a real signed-out Codex retries the websocket for twenty seconds before giving up
exit 1
EOF
# An older CLI that has no `login` subcommand at all, and one whose probe hangs. Neither may be
# read as "signed out": inventing a wall that is not there would lose Codex for a whole run.
cat > "$TMP/stub/codex-nologincmd" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "error: unrecognized subcommand 'login'" >&2; exit 2; fi
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf 'RECOMMENDATION — ok\nCONFIDENCE — high\n' > "$out"
echo '{"type":"turn.completed"}'
EOF
cat > "$TMP/stub/codex-proberhangs" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then sleep 120; fi     # never answers
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf 'RECOMMENDATION — ok\nCONFIDENCE — high\n' > "$out"
echo '{"type":"turn.completed"}'
EOF
# Fails the way an expired login fails.
cat > "$TMP/stub/codex-loggedout" <<'EOF'
#!/bin/bash
echo "Reading additional input from stdin..." >&2
echo 'ERROR: not signed in - run: codex login' >&2
exit 1
EOF
chmod +x "$TMP/stub"/*
export CODEX_CWD_RECORD="$TMP/codex-cwd"

consult() {   # $1=cwd  $2=codex stub  rest=question
  local d="$1" bin="$2"; shift 2
  ( cd "$d" && ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_CODEX_BIN="$TMP/stub/$bin" \
      SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage" bash "$BIN/consult-codex.sh" "$@" )
}

out="$(consult "$IDIR" codex "питання з теки прогону" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "a consultation from the instance folder succeeds" \
              || bad "still refused from the instance folder (rc=$rc): $out"
[ "$(canon_path "$(cat "$CODEX_CWD_RECORD" 2>/dev/null)")" = "$PROJ" ] \
  && ok "and Codex was pointed at the project, not at the state folder" \
  || bad "Codex was started in $(cat "$CODEX_CWD_RECORD" 2>/dev/null)"

out="$(consult "$NEIGHBOUR" codex "питання про сусідній репозиторій" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "a consultation from an allowed neighbouring repo succeeds" || bad "refused from a neighbouring repo (rc=$rc)"
[ "$(canon_path "$(cat "$CODEX_CWD_RECORD" 2>/dev/null)")" = "$NEIGHBOUR" ] \
  && ok "and Codex looked at the repository the question is about" \
  || bad "Codex was sent to the wrong repository"

out="$(consult "$PROJ" codex-mute "мовчазний codex" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "an empty answer is a FAILED consultation (rc=$rc)" \
               || bad "exit 0 with no answer still reads as a successful consultation"
last="$(ls -d "$IDIR/consultations/$RID"/[0-9]* | tail -1)"
if [ "$(jq -r '.status' "$last/metrics.json" 2>/dev/null)" = empty ]; then
  ok "recorded as status=empty, with the reason on file"
else
  bad "status: $(jq -r '.status // "?"' "$last/metrics.json" 2>/dev/null)"
fi

out="$(consult "$PROJ" codex-loggedout "codex без логіну" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "a crashed Codex is a failure (rc=$rc)" || bad "a crash reported success"
case "$out" in *"not signed in"*) ok "and the REASON reaches the reader, not just a numeric code" ;;
               *) bad "the reader still gets only a code: $out" ;; esac
case "$out" in *"підписку не авторизовано"*) ok "an auth failure is named as one, not left looking like a crash" ;;
               *) bad "a login problem still reads as a code fault" ;; esac

echo "===== a signed-out Codex is named at once, not after the whole call times out ====="
# The usage meter reads the last SUCCESSFUL measurement, so a login that died an hour ago still
# shows a half-full window and every call sets off on it. Asking Codex itself costs milliseconds.
started_at="$(date +%s)"
out="$(consult "$PROJ" codex-signedout "чи авторизований codex" 2>&1)"; rc=$?
took=$(( $(date +%s) - started_at ))
[ "$rc" = 75 ] && ok "refused as UNAVAILABLE (rc=75), not as a code failure" \
                || bad "a signed-out Codex came back as rc=$rc"
[ "$took" -lt 5 ] && ok "and it took ${took}s, not the full doomed call" \
                  || bad "still spent ${took}s finding out nobody is logged in"
case "$out" in *"не авторизований"*) ok "the reason names the login, not a status code" ;;
               *) bad "the reader is told nothing useful: $out" ;; esac
last="$(ls -d "$IDIR/consultations/$RID"/[0-9]* | tail -1)"
[ "$(jq -r '.provider_state' "$last/metrics.json" 2>/dev/null)" = signed_out ] \
  && ok "and the record says which kind of unavailable it was" \
  || bad "recorded as $(jq -r '.provider_state // "?"' "$last/metrics.json" 2>/dev/null)"

echo "===== the probe never invents a wall, and never becomes one ====="
# Two ways the probe itself could take Codex away. An older CLI that does not know `login status`
# must not be read as signed out, and a probe that hangs must be abandoned rather than waited on.
out="$(consult "$PROJ" codex-nologincmd "старий CLI без login" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "a CLI with no login subcommand still gets asked the question" \
              || bad "an unrecognised subcommand became a refusal (rc=$rc): $out"

started_at="$(date +%s)"
out="$( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_CODEX_BIN="$TMP/stub/codex-proberhangs" \
        SUPERVISOR_CODEX_AUTH_PROBE_TIMEOUT=2 SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage" \
        bash "$BIN/consult-codex.sh" "probe, що зависає" 2>&1 )"; rc=$?
took=$(( $(date +%s) - started_at ))
[ "$rc" = 0 ] && ok "a hanging probe is abandoned and the consultation goes ahead" \
              || bad "the probe became the failure (rc=$rc): $out"
[ "$took" -lt 15 ] && ok "and it cost ${took}s, not the probe's own patience" \
                   || bad "the hanging probe held the call for ${took}s"

echo "===== consultations asked at the same moment do not share a record ====="
# The counter is a mkdir mutex; two questions in flight must be two numbered folders, not one
# overwriting the other.
before_n="$(ls -d "$IDIR/consultations/$RID"/[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
for q in одночасне-1 одночасне-2 одночасне-3; do
  consult "$PROJ" codex "$q" >/dev/null 2>&1 &
done
wait
after_n="$(ls -d "$IDIR/consultations/$RID"/[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
[ "$((after_n - before_n))" = 3 ] \
  && ok "three parallel consultations left three separate records" \
  || bad "parallel calls collided: $before_n → $after_n"

echo "===== a refusal leaves a witness ====="
LOGF="$SUPERVISOR_STATE_DIR/supervisor.log"
before_n="$(grep -c 'consult-codex' "$LOGF" 2>/dev/null || echo 0)"
( cd "$PROJ" && ORCHESTRATOR_RUN_ID=GONE-RUN bash "$BIN/consult-codex.sh" "хто я" ) >/dev/null 2>&1
rc=$?
[ "$rc" != 0 ] && ok "a consultation from a dead run is refused (rc=$rc)" || bad "a dead run consulted anyway"
[ "$(grep -c 'consult-codex' "$LOGF" 2>/dev/null || echo 0)" -gt "$before_n" ] \
  && ok "and the refusal is written to supervisor.log" \
  || bad "the refusal left no trace at all — exactly how this lived for five days"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
