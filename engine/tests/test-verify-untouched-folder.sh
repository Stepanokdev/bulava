#!/bin/bash
# A folder the work never touched does not run its test suite.
#
# The review only reaches the verifier when something changed — in the primary folder or in one of
# the product's other repositories. So a primary folder with no change of its own means the work
# was done next door, and the heavy `npm test` that used to run there anyway (an hour of a big
# monorepo's suite, after a fix in a sibling repository) could not fail because of anything this
# run did. Nor can it fail because a README was edited.
#
# What must still run: anything that is not prose. A `.ts` file, a `.yaml` config, a mixed diff, a
# rename that moved code into a `.md` name — and any run whose base commit is unknown, because then
# nobody can say what changed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
VERIFY="$ROOT/bin/verify.sh"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

STUB="$(mktemp -d)"
CALLS="$STUB/calls.log"
for tool in npm go pytest; do
  cat > "$STUB/$tool" <<SH
#!/bin/bash
echo "$tool \$*" >> "$CALLS"; exit 0
SH
  chmod +x "$STUB/$tool"
done
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$STUB" ${REPOS:-}; }
trap cleanup EXIT
REPOS=""

# A fresh repository holding `files` (name=content pairs), committed. Prints its path.
make_repo(){
  local dir; dir="$(mktemp -d)"; REPOS="$REPOS $dir"
  ( cd "$dir" && git init -q && git config user.email t@t && git config user.name t
    while [ $# -gt 0 ]; do mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; shift 2; done
    git add -A && git commit -qm init >/dev/null )
  printf '%s' "$dir"
}

# Runs the verifier against `dir` from its committed HEAD. Sets EV.
verify_from_head(){
  local dir="$1" sid="$2" idir base
  idir="$(instance_dir "$(slug_for "$dir")")"; mkdir -p "$idir"
  printf '%s\n' "$(canon_path "$dir")" > "$idir/project"
  base="$(git -C "$dir" rev-parse HEAD)"
  : > "$CALLS"
  EV="$(PATH="$STUB:$PATH" "$VERIFY" "$dir" "$sid" "$idir" "$base" 2>/dev/null)"
}
status_of(){ jq -r --arg c "$1" '[.criteria[]|select(.criterion==$c)|.status]|first // "absent"' "$EV" 2>/dev/null; }
note_of(){ jq -r --arg c "$1" '[.criteria[]|select(.criterion==$c)|.note]|first // ""' "$EV" 2>/dev/null; }
called(){ grep -qF -- "$1" "$CALLS" 2>/dev/null; }

PKG='{"name":"heavy","scripts":{"build":"true","test":"true","lint":"true"}}'

echo "== JS: nothing changed in this folder ⇒ test and lint are not run =="
P="$(make_repo package.json "$PKG" README.md "hello")"
verify_from_head "$P" js-untouched
check "evidence produced"                   '[ -n "$EV" ] && [ -f "$EV" ]'
check "npm test was never called"           '! called "npm run test"'
check "npm lint was never called"           '! called "npm run lint"'
check "tests recorded as skipped"           '[ "$(status_of "tests pass")" = skipped ]'
check "lint recorded as skipped"            '[ "$(status_of "lint clean")" = skipped ]'
check "the skip says why"                   '[ -n "$(note_of "tests pass")" ]'
check "nothing passed, so overall is not pass" '[ "$(jq -r .overall_status "$EV")" != pass ]'
check "nothing next door, so nothing unchecked" '[ "$(jq -r ".unverified_elsewhere | length" "$EV")" = 0 ]'
check "and no criterion is inconclusive"    '[ "$(jq "[.criteria[]|select(.status==\"inconclusive\")]|length" "$EV")" = 0 ]'

echo "== the work was next door: the skip names that repository, and the review does not bank it as debt =="
SIB="$(make_repo lib.ts "export const s = 1")"
SIB_BASE="$(git -C "$SIB" rev-parse HEAD)"
SIB_DIGEST="$(repo_work_digest "$SIB" "$SIB_BASE")"
printf 'export const s = 2\n' > "$SIB/lib.ts"
PIDIR="$(instance_dir "$(slug_for "$P")")"
printf '%s\037%s\037%s\0370\n' "$(canon_path "$SIB")" "$SIB_BASE" "$SIB_DIGEST" > "$PIDIR/extra-repos"
verify_from_head "$P" js-next-door
check "npm test was never called"           '! called "npm run test"'
check "the skip names the sibling"          'note_of "tests pass" | grep -qF "$(canon_path "$SIB")"'
# The same expression review-gate.sh uses to tell "nothing here to build or test" from a gap in the
# evidence. Read out of the gate itself, so a change there is a change here.
NTV="$(awk '/^nothing_to_verify\(\) \{/,/^\}/' "$ROOT/hooks/review-gate.sh")"
check "the gate reads it as nothing to verify" '[ -n "$NTV" ] && ( eval "$NTV"; verify_json="$(cat "$EV")"; nothing_to_verify )'
# As data too, for the app to say so under the answer and offer to check it.
check "evidence says the primary was untouched" '[ "$(jq -r .primary_untouched "$EV")" = true ]'
check "evidence names the unchecked sibling"    'jq -e --arg s "$(canon_path "$SIB")" ".unverified_elsewhere | index(\$s)" "$EV" >/dev/null'

echo "== night-shift verify-elsewhere: the sibling, checked on request, from the run's base =="
NS="$ROOT/bin/night-shift.sh"
SIB2="$(make_repo package.json "$PKG" src/round.ts "export const r = 1")"
SIB2_BASE="$(git -C "$SIB2" rev-parse HEAD)"
printf '%s\037%s\037%s\0370\037\n' "$(canon_path "$SIB2")" "$SIB2_BASE" "$(repo_work_digest "$SIB2" "$SIB2_BASE")" >> "$PIDIR/extra-repos"
printf 'export const r = 2\n' > "$SIB2/src/round.ts"
: > "$CALLS"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P" "$SIB2" 2>/dev/null)"; RC=$?
EV="$OUT"
check "it ran and printed an evidence file"     '[ "$RC" = 0 ] && [ -f "$EV" ]'
check "the evidence is about the sibling"      '[ "$(jq -r .project_dir "$EV")" = "$(canon_path "$SIB2")" ]'
check "measured from the base the run recorded" '[ "$(jq -r .base_sha "$EV")" = "$SIB2_BASE" ]'
check "its suite really ran"                    'called "npm run test" && [ "$(status_of "tests pass")" = pass ]'
check "kept apart from the primary evidence"  'case "$EV" in "$PIDIR/elsewhere/"*) true ;; *) false ;; esac'
check "and not offered again as unchecked"      '[ "$(jq -r ".unverified_elsewhere | length" "$EV")" = 0 ]'
STRANGER="$(make_repo package.json "$PKG")"
: > "$CALLS"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P" "$STRANGER" 2>/dev/null)"; RC=$?
check "a repository this run was not given is refused" '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q not-in-run'
check "and nothing was run in it"               '! called "npm"'
rm -f "$PIDIR/extra-repos"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P" "$SIB2" 2>/dev/null)"; RC=$?
check "with no record of the run, it says so"   '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q no-run'

echo "== a sibling this same pass verified is not named as unchecked =="
# The other repositories are verified in the same pass when they have something to run, and a
# repository covered by the worker's own registered checks counts as verified too. Naming either as
# "not checked" under the answer was untrue — and offered to run the same suite a second time.
P3="$(make_repo package.json "$PKG" README.md "hello")"
P3IDIR="$(instance_dir "$(slug_for "$P3")")"; mkdir -p "$P3IDIR"
MK="$(make_repo Makefile $'test:\n\ttrue' lib.c "int a = 1;")"
MK_BASE="$(git -C "$MK" rev-parse HEAD)"
BARE="$(make_repo lib.ts "export const b = 1")"
BARE_BASE="$(git -C "$BARE" rev-parse HEAD)"
{ printf '%s\037%s\037%s\0370\n' "$(canon_path "$MK")" "$MK_BASE" "$(repo_work_digest "$MK" "$MK_BASE")"
  printf '%s\037%s\037%s\0370\n' "$(canon_path "$BARE")" "$BARE_BASE" "$(repo_work_digest "$BARE" "$BARE_BASE")"
} > "$P3IDIR/extra-repos"
printf 'int a = 2;\n' > "$MK/lib.c"
printf 'export const b = 2\n' > "$BARE/lib.ts"
verify_from_head "$P3" covered
check "make test ran in the sibling that has one" '[ "$(status_of "$(basename "$MK"): make test")" = pass ]'
check "so it is not named as unchecked"           '! jq -e --arg s "$(canon_path "$MK")" ".unverified_elsewhere | index(\$s)" "$EV" >/dev/null'
check "a sibling with nothing to run still is"    'jq -e --arg s "$(canon_path "$BARE")" ".unverified_elsewhere | index(\$s)" "$EV" >/dev/null'
check "with the digest of its tree as it is now"  '[ "$(jq -r --arg s "$(canon_path "$BARE")" ".unverified_elsewhere_digests[\$s] // empty" "$EV")" = "$(work_tree_digest "$(canon_path "$BARE")")" ]'
check "and only for what is named"                '[ "$(jq -r ".unverified_elsewhere_digests | length" "$EV")" = 1 ]'
check "the skip still says where the change is"   'note_of "tests pass" | grep -qF "$(canon_path "$BARE")"'
check "without claiming it went unverified"       '! note_of "tests pass" | grep -q "not verified"'
printf '{"criterion":"lib type-checks","argv":["true"],"cwd":"%s"}\n' "$(canon_path "$BARE")" > "$P3IDIR/checks.jsonl"
verify_from_head "$P3" covered-by-worker
check "a sibling the worker's own check is about is not named either" \
  '! jq -e --arg s "$(canon_path "$BARE")" ".unverified_elsewhere | index(\$s)" "$EV" >/dev/null'
rm -f "$P3IDIR/checks.jsonl"
SUPERVISOR_EXTRA_REPO_AUTOVERIFY=0 verify_from_head "$P3" autoverify-off
check "with the same-pass check switched off, both are named" \
  '[ "$(jq -r ".unverified_elsewhere | length" "$EV")" = 2 ]'

echo "== verify-elsewhere: in the run whose answer it is, or not at all =="
printf 'RUN-A\n' > "$P3IDIR/run-id"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P3" "$BARE" RUN-A 2>/dev/null)"; RC=$?
check "the run named holds the folder: it checks" '[ "$RC" = 0 ] && [ -f "$OUT" ]'
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P3" "$MK" RUN-OLD 2>/dev/null)"; RC=$?
check "another run holds it now: refused, by name" '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q run-ended'
check "and nothing was checked from that run"     '[ ! -e "$P3IDIR/elsewhere/$(slug_for "$(canon_path "$MK")")" ]'
# The folder changes hands while the check runs: this sibling's own test hands it to RUN-B.
SWAP="$(make_repo Makefile "$(printf 'test:\n\tprintf "RUN-B\\n" > "%s"' "$P3IDIR/run-id")" lib.c "int s = 1;")"
SWAP_BASE="$(git -C "$SWAP" rev-parse HEAD)"
printf '%s\037%s\037%s\0370\n' "$(canon_path "$SWAP")" "$SWAP_BASE" "$(repo_work_digest "$SWAP" "$SWAP_BASE")" >> "$P3IDIR/extra-repos"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P3" "$SWAP" RUN-A 2>/dev/null)"; RC=$?
check "a run replaced while its check ran is refused" '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q run-ended'
check "and its result is not left for the new run"    '[ ! -f "$P3IDIR/elsewhere/$(slug_for "$(canon_path "$SWAP")")/evidence/check/evidence.json" ]'
printf 'RUN-A\n' > "$P3IDIR/run-id"

echo "== a stop keeps the checks made from the chat with the run's archive =="
bash "$NS" stop "$P3" --yes >/dev/null 2>&1
check "the instance is gone"                      '[ ! -d "$P3IDIR" ]'
check "the check of the sibling is in the archive" \
  '[ -f "$(run_dir RUN-A)/elsewhere/$(slug_for "$(canon_path "$BARE")")/evidence/check/evidence.json" ]'

echo "== JS: only prose changed (tracked README + new notes.md) ⇒ not run =="
printf 'more\n' >> "$P/README.md"; printf 'notes\n' > "$P/notes.md"
verify_from_head "$P" js-docs
check "npm test was never called"           '! called "npm run test"'
check "tests recorded as skipped"           '[ "$(status_of "tests pass")" = skipped ]'

echo "== JS: a code change still runs the suite =="
P="$(make_repo package.json "$PKG" src/a.ts "export const a = 1")"
printf 'export const a = 2\n' > "$P/src/a.ts"
verify_from_head "$P" js-code
check "npm test ran"                        'called "npm run test"'
check "tests pass recorded as pass"         '[ "$(status_of "tests pass")" = pass ]'

echo "== JS: a config change outside the build regex still runs the suite =="
P="$(make_repo package.json "$PKG" config/app.yaml "a: 1")"
printf 'a: 2\n' > "$P/config/app.yaml"
verify_from_head "$P" js-yaml
check "npm test ran for a .yaml change"     'called "npm run test"'
check "npm lint ran for a .yaml change"     'called "npm run lint"'

echo "== JS: prose plus anything else is not prose-only =="
P="$(make_repo package.json "$PKG" README.md "x" .env.example "A=1")"
printf 'y\n' >> "$P/README.md"; printf 'A=2\n' > "$P/.env.example"
verify_from_head "$P" js-mixed
check "npm test ran for a mixed diff"       'called "npm run test"'

echo "== JS: code renamed to a .md name is a deletion of code, not a doc edit =="
P="$(make_repo package.json "$PKG" src/b.ts "export const b = 1")"
( cd "$P" && git mv src/b.ts src/b.md )
verify_from_head "$P" js-rename
check "npm test ran after a rename away from .ts" 'called "npm run test"'

echo "== JS: no base commit known ⇒ nothing can be said, the suite runs =="
P="$(make_repo package.json "$PKG" README.md "x")"
: > "$CALLS"
EV="$(PATH="$STUB:$PATH" "$VERIFY" "$P" js-nobase 2>/dev/null)"
check "npm test ran without a base"         'called "npm run test"'

echo "== Go: an untouched folder does not run go test =="
P="$(make_repo go.mod "module x" main.go "package main")"
verify_from_head "$P" go-untouched
check "go test was never called"            '! called "go test"'
check "go tests recorded as skipped"        '[ "$(status_of "go tests pass")" = skipped ]'
printf 'package main\n// x\n' > "$P/main.go"
verify_from_head "$P" go-code
check "go test ran for a .go change"        'called "go test"'

echo "== Python: an untouched folder does not run pytest or the compile step =="
P="$(make_repo pyproject.toml "[project]" app.py "x = 1")"
verify_from_head "$P" py-untouched
check "pytest was never called"             '! called "pytest"'
check "compile step recorded as skipped"   '[ "$(status_of "python compiles")" = skipped ]'
check "pytest recorded as skipped"          '[ "$(status_of "pytest passes")" = skipped ]'
printf 'x = 2\n' > "$P/app.py"
verify_from_head "$P" py-code
check "pytest ran for a .py change"         'called "pytest"'
check "and the project compiled for real"   '[ "$(status_of "python compiles")" = pass ]'

echo "== a project's own verify.sh is NOT governed by this — it may check nested repositories =="
P="$(make_repo verify.sh "#!/bin/bash
echo own >> \"$CALLS\"; exit 0" README.md "x")"
chmod +x "$P/verify.sh"; ( cd "$P" && git add -A && git commit -qm x >/dev/null )
verify_from_head "$P" own-verify
check "the project's verify.sh still ran"   'called "own"'

echo "== a sibling left to the worker's checks counts only when one of them reached a verdict =="
# Registering a check is not running it. A check whose tool is missing, that ran out of the
# verifier's budget, or that timed out said nothing about the repository: it stays unchecked.
P4="$(make_repo package.json "$PKG" README.md "hello")"
P4IDIR="$(instance_dir "$(slug_for "$P4")")"; mkdir -p "$P4IDIR"
W="$(make_repo lib.ts "export const w = 1")"
W_BASE="$(git -C "$W" rev-parse HEAD)"
printf '%s\037%s\037%s\0370\n' "$(canon_path "$W")" "$W_BASE" "$(repo_work_digest "$W" "$W_BASE")" > "$P4IDIR/extra-repos"
printf 'export const w = 2\n' > "$W/lib.ts"
named(){ jq -e --arg s "$(canon_path "$W")" ".unverified_elsewhere | index(\$s)" "$EV" >/dev/null; }
register(){ printf '{"criterion":"%s","argv":%s,"cwd":"%s"}\n' "$1" "$2" "$(canon_path "$W")" > "$P4IDIR/checks.jsonl"; }

register "w missing tool" '["no-such-tool-for-this-test"]'
verify_from_head "$P4" by-checks-missing-tool
check "missing tool: the check is inconclusive"     '[ "$(status_of "w missing tool")" = inconclusive ]'
check "missing tool: the sibling is still named"    'named'

register "w over budget" '["true"]'
SUPERVISOR_VERIFY_TOTAL_TIMEOUT=0 verify_from_head "$P4" by-checks-budget
check "out of budget: the check is inconclusive"    '[ "$(status_of "w over budget")" = inconclusive ]'
check "out of budget: the sibling is still named"   'named'

register "w timed out" '["sleep","5"]'
SUPERVISOR_VERIFY_STEP_TIMEOUT=1 verify_from_head "$P4" by-checks-timeout
check "timed out: the check is inconclusive"        '[ "$(status_of "w timed out")" = inconclusive ]'
check "timed out: the sibling is still named"       'named'

register "w fails" '["false"]'
verify_from_head "$P4" by-checks-fail
check "a check that ran and failed did look"        '[ "$(status_of "w fails")" = fail ] && ! named'

register "w passes" '["true"]'
verify_from_head "$P4" by-checks-pass
check "a check that ran and passed did look"        '[ "$(status_of "w passes")" = pass ] && ! named'
rm -f "$P4IDIR/checks.jsonl"

echo "== verify-elsewhere without a run id: the run holding the folder at the start is the one =="
P5="$(make_repo package.json "$PKG" README.md "hello")"
P5IDIR="$(instance_dir "$(slug_for "$P5")")"; mkdir -p "$P5IDIR"
printf 'RUN-X\n' > "$P5IDIR/run-id"
SWAP2="$(make_repo Makefile "$(printf 'test:\n\tprintf "RUN-Y\\n" > "%s"' "$P5IDIR/run-id")" lib.c "int s = 1;")"
SWAP2_BASE="$(git -C "$SWAP2" rev-parse HEAD)"
printf '%s\037%s\037%s\0370\n' "$(canon_path "$SWAP2")" "$SWAP2_BASE" "$(repo_work_digest "$SWAP2" "$SWAP2_BASE")" > "$P5IDIR/extra-repos"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P5" "$SWAP2" 2>/dev/null)"; RC=$?
check "no run id, run replaced while it checked: refused" '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q run-ended'
check "and its result is not left for the new run"        '[ ! -f "$P5IDIR/elsewhere/$(slug_for "$(canon_path "$SWAP2")")/evidence/check/evidence.json" ]'
rm -f "$P5IDIR/run-id"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P5" "$SWAP2" 2>/dev/null)"; RC=$?
check "no run at the start, one started while it checked: refused" '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q run-ended'
STAY="$(make_repo Makefile $'test:\n\ttrue' lib.c "int t = 1;")"
STAY_BASE="$(git -C "$STAY" rev-parse HEAD)"
printf 'RUN-Z\n' > "$P5IDIR/run-id"
printf '%s\037%s\037%s\0370\n' "$(canon_path "$STAY")" "$STAY_BASE" "$(repo_work_digest "$STAY" "$STAY_BASE")" >> "$P5IDIR/extra-repos"
printf 'int t = 2;\n' > "$STAY/lib.c"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P5" "$STAY" 2>/dev/null)"; RC=$?
check "no run id, the same run throughout: it checks"     '[ "$RC" = 0 ] && [ -f "$OUT" ]'

echo "== a run's instance with no base commit: no full-tree build, but the suites run =="
P6="$(make_repo package.json "$PKG" src/c.ts "export const c = 1")"
P6IDIR="$(instance_dir "$(slug_for "$P6")")"; mkdir -p "$P6IDIR"
printf '%s\n' "$(canon_path "$P6")" > "$P6IDIR/project"
rm -f "$P6IDIR/base-sha"
: > "$CALLS"
EV="$(PATH="$STUB:$PATH" "$VERIFY" "$P6" nobase-instance "$P6IDIR" 2>/dev/null)"
check "the missing base is said, as inconclusive"   '[ "$(status_of "automated verification")" = inconclusive ] && note_of "automated verification" | grep -q "base"'
check "the full-tree build is not run"              '! called "npm run build" && [ "$(status_of "web build succeeds")" = skipped ]'
check "the build skip names the missing base"       'note_of "web build succeeds" | grep -q "no base commit"'
check "npm test ran"                                'called "npm run test" && [ "$(status_of "tests pass")" = pass ]'
check "npm lint ran"                                'called "npm run lint"'
check "and the whole is not a pass"                 '[ "$(jq -r .overall_status "$EV")" != pass ]'

echo "== verify-elsewhere for a sibling whose base the run never recorded: its suite runs =="
P7="$(make_repo package.json "$PKG" README.md "hello")"
P7IDIR="$(instance_dir "$(slug_for "$P7")")"; mkdir -p "$P7IDIR"
NB="$(make_repo package.json "$PKG" src/n.ts "export const n = 1")"
printf '%s\037-\037-\0370\n' "$(canon_path "$NB")" > "$P7IDIR/extra-repos"
printf 'export const n = 2\n' > "$NB/src/n.ts"
: > "$CALLS"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P7" "$NB" 2>/dev/null)"; RC=$?
EV="$OUT"
check "it checked and printed evidence"             '[ "$RC" = 0 ] && [ -f "$EV" ]'
check "with no base recorded"                       '[ "$(jq -r .base_sha "$EV")" = "" ]'
check "its suite really ran"                        'called "npm run test" && [ "$(status_of "tests pass")" = pass ]'
check "and the missing base is said"                '[ "$(status_of "automated verification")" = inconclusive ]'

echo "== native: an instance with no base runs xcodebuild test, never a separate build =="
# A stub that answers the two questions verify.sh asks (-list -json, -showBuildSettings) as a macOS
# project with a test target would, and logs every build or test it is asked for.
cat > "$STUB/xcodebuild" <<SH
#!/bin/bash
case " \$* " in
  *" -list "*) echo '{"project":{"name":"App","schemes":["App"],"targets":["App","AppTests"]}}' ;;
  *" -showBuildSettings "*) echo '    SDKROOT = macosx' ;;
  *) echo "xcodebuild \$*" >> "$CALLS" ;;
esac
exit 0
SH
chmod +x "$STUB/xcodebuild"
P8="$(make_repo App.swift "let a = 1")"
mkdir -p "$P8/App.xcodeproj"
P8IDIR="$(instance_dir "$(slug_for "$P8")")"; mkdir -p "$P8IDIR"
printf '%s\n' "$(canon_path "$P8")" > "$P8IDIR/project"
rm -f "$P8IDIR/base-sha"
: > "$CALLS"
EV="$(PATH="$STUB:$PATH" "$VERIFY" "$P8" native-nobase "$P8IDIR" 2>/dev/null)"
check "xcodebuild test ran"                         'called "xcodebuild test -scheme App" && [ "$(status_of "unit tests pass")" = pass ]'
check "no separate xcodebuild build"                '! called "xcodebuild build"'
check "the build is recorded as refused, by name"   'note_of "app builds (platform=macOS)" | grep -q "no base commit"'
check "the missing base is said"                    '[ "$(status_of "automated verification")" = inconclusive ]'
check "and the whole is not a pass"                 '[ "$(jq -r .overall_status "$EV")" != pass ]'

echo "== native: with a base and a Swift change, build and test both run, as before =="
P9="$(make_repo App.swift "let a = 1")"
mkdir -p "$P9/App.xcodeproj"
printf 'let a = 2\n' > "$P9/App.swift"
verify_from_head "$P9" native-code
check "xcodebuild build ran"                        'called "xcodebuild build -scheme App"'
check "xcodebuild test ran"                         'called "xcodebuild test -scheme App"'
( cd "$P9" && git add -A && git commit -qm x >/dev/null )
verify_from_head "$P9" native-untouched
check "untouched: neither build nor test"           '! called "xcodebuild build" && ! called "xcodebuild test"'

echo "== native: a change outside the build list still runs the tests, without a separate build =="
for kind in yaml txt mixed prose; do
  P11="$(make_repo App.swift "let a = 1" README.md "x" config/settings.yaml "a: 1" Tests/fixture.txt "f")"
  mkdir -p "$P11/App.xcodeproj"
  case "$kind" in
    yaml)  printf 'a: 2\n' > "$P11/config/settings.yaml" ;;
    txt)   printf 'g\n' > "$P11/Tests/fixture.txt" ;;
    mixed) printf 'y\n' >> "$P11/README.md"; printf 'a: 3\n' > "$P11/config/settings.yaml" ;;
    prose) printf 'y\n' >> "$P11/README.md"; printf 'notes\n' > "$P11/NOTES.md" ;;
  esac
  verify_from_head "$P11" "native-$kind"
  if [ "$kind" = prose ]; then
    check "prose only: no xcodebuild test"           '! called "xcodebuild test"'
    check "prose only: the tests are recorded as skipped" '[ "$(status_of "unit tests pass")" = skipped ]'
  else
    check "$kind: xcodebuild test ran"                'called "xcodebuild test -scheme App" && [ "$(status_of "unit tests pass")" = pass ]'
    check "$kind: no separate build"                  '! called "xcodebuild build"'
  fi
done

echo "== native: verify-elsewhere for a sibling with no recorded base runs its tests =="
P10="$(make_repo package.json "$PKG" README.md "hello")"
P10IDIR="$(instance_dir "$(slug_for "$P10")")"; mkdir -p "$P10IDIR"
NAT="$(make_repo App.swift "let n = 1")"
mkdir -p "$NAT/App.xcodeproj"
printf '%s\037-\037-\0370\n' "$(canon_path "$NAT")" > "$P10IDIR/extra-repos"
printf 'let n = 2\n' > "$NAT/App.swift"
: > "$CALLS"
OUT="$(PATH="$STUB:$PATH" bash "$NS" verify-elsewhere "$P10" "$NAT" 2>/dev/null)"; RC=$?
EV="$OUT"
check "it checked and printed evidence"             '[ "$RC" = 0 ] && [ -f "$EV" ]'
check "xcodebuild test ran in the sibling"          'called "xcodebuild test -scheme App" && [ "$(status_of "unit tests pass")" = pass ]'
check "no separate build in the sibling"            '! called "xcodebuild build"'
rm -f "$STUB/xcodebuild"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
