#!/bin/bash
# Every finished run leaves something the director can OPEN.
#
# A report used to be an LLM pass over a diff (report.sh), generated on demand. So a run that
# ended with nothing to show — blocked on an account it doesn't have, nothing to change, a
# research answer, a plain failure — produced no artifact at all. The card said "Needs you",
# opening it showed an empty screen, and the night's real answer lived in a terminal nobody
# reads. Two nights in a row that was the director's whole experience: "not a single report".
#
# worker-outcome.sh now writes a deterministic receipt (no model, facts already on disk) on
# EVERY terminal outcome. This suite locks in: it exists, it carries the verdict and the
# worker's own words, a blocker names the action that lifts it, partial work is shown as
# evidence, and the channel's internal vocabulary never reaches the surface.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"

PROJ="$TMP/repo"; mkdir -p "$PROJ"
. "$BIN_DIR/supervisor-lib.sh"
# Matched by canonical path — a temp dir lives behind /var -> /private/var.
PROJ="$(canon_path "$PROJ")"

# A real repo with a base commit, so the receipt has genuine git facts to report.
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
printf 'one\n' > "$PROJ/a.txt"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm "base"
BASE="$(git -C "$PROJ" rev-parse HEAD)"

SLUG="$(slug_for "$PROJ")"
IDIR="$(instance_dir "$SLUG")"
mkdir -p "$IDIR"
printf '%s' "$PROJ" > "$IDIR/project"
RUN_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
printf '%s' "$RUN_ID" > "$IDIR/run-id"
printf '%s' "$BASE" > "$IDIR/base-sha"
printf '%s' "test-session" > "$IDIR/session"
# The hook engages only when the run-id in the environment matches the instance's — that
# equality is what keeps an unrelated session from being treated as supervised.
export ORCHESTRATOR_RUN_ID="$RUN_ID"

RECEIPT="$IDIR/report/report.html"

run_outcome() {  # $1 = result, rest = summary
  local result="$1"; shift
  rm -rf "$IDIR/report" "$IDIR/done"
  ( cd "$PROJ" && bash "$BIN_DIR/worker-outcome.sh" "$result" "$@" ) >/dev/null 2>&1
}

echo "===== a blocked run still produces a report ====="

SUM="Синк зробив, тести не запустив — немає доступу на запис у бекенд."
SUM="$(printf '%b' "$SUM")"
UNBLOCK="Дай доступ на запис у teach-me-backend, або скажи працювати лише в мобільному репо."
UNBLOCK="$(printf '%b' "$UNBLOCK")"

# The DURABLE copy, exactly as the question hook writes it. `ask-user.json` is deliberately NOT
# used here: it is removed when the hook returns, which is always before the worker records its
# outcome — a test that left it in place was testing a state that never happens.
jq -nc --arg u "$UNBLOCK" '{reason_code:"missing_authority", unblock_action:$u}' > "$IDIR/last-decision.json"
run_outcome blocked "$SUM"

if [ -f "$RECEIPT" ]; then ok "report.html written for a run with nothing to review"
else bad "no receipt - a blocked run is still a blank screen"; fi

body="$(cat "$RECEIPT" 2>/dev/null || true)"
grep -q "$(printf '%b' 'Застрягло')" "$RECEIPT" 2>/dev/null \
  && ok "the verdict is named in the director's language" || bad "verdict missing from the receipt"
grep -q "$(printf '%b' 'немає доступу на запис')" "$RECEIPT" 2>/dev/null \
  && ok "the worker's own words are carried through" || bad "the declared summary is not in the receipt"
grep -q "$(printf '%b' 'Дай доступ на запис')" "$RECEIPT" 2>/dev/null \
  && ok "the one action that lifts the blocker is stated" || bad "a blocker with no unblock action - the defect R3 forbids"

echo "===== partial work is shown as evidence, not claimed in prose ====="

git -C "$PROJ" checkout -q -b night/test
printf 'two\n' >> "$PROJ/a.txt"
printf 'export\n' > "$PROJ/b.txt"
COMMIT_MSG="$(printf '%b' 'Taskly: експорт звичок у CSV')"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm "$COMMIT_MSG"
run_outcome blocked "$(printf '%b' 'Крок 1 зробив, на кроці 2 застряг.')"
grep -q "$COMMIT_MSG" "$RECEIPT" 2>/dev/null \
  && ok "the commit that DID land is listed" || bad "work already in the branch is invisible"
grep -qE "files? changed" "$RECEIPT" 2>/dev/null \
  && ok "the diffstat is shown" || bad "no diffstat - he cannot see how much landed"

echo "===== findings appear as notes, in his vocabulary ====="

{ jq -nc '{kind:"needs_scope", text:"src/store.py"}'
  jq -nc --arg t "$(printf '%b' 'немає токена для стейджингу')" '{kind:"blocker", text:$t}'
} > "$IDIR/findings.jsonl"
run_outcome blocked "$(printf '%b' 'Застряг.')"
grep -q "$(printf '%b' 'поза межами')" "$RECEIPT" 2>/dev/null \
  && ok "needs_scope is named in words, not as an enum" || bad "the finding kind did not reach the receipt readably"
grep -q "needs_scope" "$RECEIPT" 2>/dev/null \
  && bad "the raw enum leaked onto a surface the director reads" || ok "no internal enum on the surface (R6)"
grep -q "$(printf '%b' 'немає токена')" "$RECEIPT" 2>/dev/null \
  && ok "the finding's text is carried" || bad "finding text missing"

echo "===== the receipt speaks the director's language, not one hard-coded one ====="

# The page was Ukrainian regardless of the app's setting, which made this artifact monolingual
# while the app itself ships three languages.
for pair in "Ukrainian:Очікує перевірки" "Russian:Ожидает проверки" "English:Awaiting review"; do
  lang="${pair%%:*}"; want="${pair#*:}"
  rm -rf "$IDIR/report"
  ( cd "$PROJ" && SUPERVISOR_REPORT_LANGUAGE="$lang" bash "$BIN_DIR/worker-outcome.sh" \
      succeeded_changes "зробив" ) >/dev/null 2>&1
  if grep -q "$(printf '%b' "$want")" "$RECEIPT" 2>/dev/null; then
    ok "$lang renders in $lang"
  else
    bad "$lang did not render ($want missing)"
  fi
done
rm -f "$IDIR/done"

echo "===== a declaration is not an acceptance ====="

# The receipt is written when the worker declares its outcome — before the review gate has looked
# at the diff. It used to say "Done" there, over work the reviewer could still refuse, and it
# stayed wrong when the review ended in debt.
rm -f "$IDIR/ask-user.json" "$IDIR/last-decision.json" "$IDIR/findings.jsonl"
run_outcome succeeded_changes "$(printf '%b' 'Зробив експорт у CSV.')"
grep -q "$(printf '%b' 'Очікує перевірки')" "$RECEIPT" 2>/dev/null \
  && ok "declared changes read as awaiting review, not as done" \
  || bad "a worker's declaration is shown as an accepted result"
grep -q "$(printf '%b' '>Зроблено<')" "$RECEIPT" 2>/dev/null \
  && bad "claims done before the gate decided" || ok "does not claim done yet"
[ -f "$IDIR/report/receipt.json" ] && ok "the facts are kept so the gate can restamp them" \
                                   || bad "no receipt.json — the gate cannot restamp the verdict"

# What the gate does with it, for each verdict it can reach.
restamp() {  # $1 = review state
  jq -c --arg rv "$1" '.review = $rv' "$IDIR/report/receipt.json" > "$TMP/r.json" \
    && mv -f "$TMP/r.json" "$IDIR/report/receipt.json"
  python3 "$BIN_DIR/receipt-render.py" "$RECEIPT" < "$IDIR/report/receipt.json" >/dev/null 2>&1
}

restamp passed
grep -q "$(printf '%b' 'перевірена')" "$RECEIPT" 2>/dev/null \
  && ok "a PASS earns the accepted wording" || bad "a passed review is not reflected"

restamp debt
grep -q "$(printf '%b' 'не перевірено')" "$RECEIPT" 2>/dev/null \
  && ok "review debt says so plainly" || bad "debt still reads as a clean success"

restamp failed
grep -q "$(printf '%b' 'Не прийнято')" "$RECEIPT" 2>/dev/null \
  && ok "a refused review says not accepted" || bad "a failed review reads as success"

# The other outcomes are the worker's own to declare — no review state applies.
run_outcome succeeded_research "$(printf '%b' 'Так, можна.')"
grep -q "$(printf '%b' 'Очікує перевірки')" "$RECEIPT" 2>/dev/null \
  && bad "research was made to wait for a review it never needs" \
  || ok "research is not held behind a review"

echo "===== no machine identity in the header ====="

grep -q "$RUN_ID" "$RECEIPT" 2>/dev/null \
  && bad "the run id is printed on the page he reads (R6)" \
  || ok "no run id on the surface — that lives behind Details"

echo "===== the quiet outcomes get a verdict too ====="

rm -f "$IDIR/ask-user.json" "$IDIR/last-decision.json" "$IDIR/findings.jsonl"
run_outcome succeeded_no_change "$(printf '%b' 'Перевірив — робити нічого.')"
grep -q "$(printf '%b' 'Нічого не потрібно')" "$RECEIPT" 2>/dev/null \
  && ok "nothing-to-change is a verdict, not silence" || bad "succeeded_no_change produced no readable verdict"

run_outcome succeeded_research "$(printf '%b' 'Так, можна — але тільки через API v2.')"
grep -q "$(printf '%b' 'Відповідь готова')" "$RECEIPT" 2>/dev/null \
  && ok "research finishes with its answer on screen" || bad "succeeded_research produced no readable verdict"
grep -q "API v2" "$RECEIPT" 2>/dev/null \
  && ok "the research answer itself is in the receipt" || bad "the research conclusion is missing"

echo "===== the receipt can never break the outcome ====="

# The outcome protocol is load-bearing: a run that cannot record how it finished hangs forever.
# Rendering is best-effort - knock the renderer out and the outcome must still be recorded.
mv "$BIN_DIR/receipt-render.py" "$TMP/renderer-away.py"
rm -rf "$IDIR/report" "$IDIR/outcome.json"
( cd "$PROJ" && bash "$BIN_DIR/worker-outcome.sh" failed "tried and could not" ) >/dev/null 2>&1
rc=$?
mv "$TMP/renderer-away.py" "$BIN_DIR/receipt-render.py"
[ "$rc" -eq 0 ] && ok "a broken renderer does not fail the outcome" \
                || bad "the receipt took the outcome down with it (rc=$rc)"
[ -f "$IDIR/outcome.json" ] && ok "outcome.json still recorded without a renderer" \
                            || bad "outcome lost when the renderer is missing"

echo "===== an unsupervised run stays a no-op ====="

( cd "$TMP" && ORCHESTRATOR_RUN_ID= bash "$BIN_DIR/worker-outcome.sh" blocked "not here" ) >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "outside a supervised run it exits quietly" \
               || bad "an unsupervised call must not fail"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
