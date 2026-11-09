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

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
