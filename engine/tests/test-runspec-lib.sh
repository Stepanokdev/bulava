#!/bin/bash
# §11.1 — RunSpec helpers + glob engine + abs_target (pure-lib unit tests).
# Covers: runspec_present/mode/get/write_paths on valid|missing|empty-arg|malformed;
# glob_to_regex/path_matches_glob truth table (* stays in segment, ** crosses /,
# trailing / = subtree, absolute + '..' globs dropped); abs_target for a NOT-yet-
# existing nested path (regression #3 — must NOT collapse to /basename).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

WORK="$(mktemp -d)"
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$WORK"; }
trap cleanup EXIT

pm(){ path_matches_glob "$1" "$2"; }
mkspec(){ mkdir -p "$1"; printf '%s' "$2" > "$1/runspec.json"; }

# --- runspec_present / mode / get / write_paths -----------------------------
VALID="$WORK/valid"
mkspec "$VALID" '{"schema":1,"mode":"patch","objective":"o","surface":{"user_facing_copy":true},"write_paths":["src/**","/abs/x","../escape","ok.txt"]}'
MISSING="$WORK/missing"; mkdir -p "$MISSING"                      # dir, no runspec.json
BAD="$WORK/bad"; mkdir -p "$BAD"; printf '%s' '{not json,,' > "$BAD/runspec.json"
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"; : > "$EMPTY/runspec.json" # zero-byte file
NOMODE="$WORK/nomode"; mkspec "$NOMODE" '{"schema":1,"objective":"o"}'

echo "== runspec_present =="
check "valid runspec present"          'runspec_present "$VALID"'
check "missing runspec absent"         '! runspec_present "$MISSING"'
check "empty-arg absent"               '! runspec_present ""'
check "malformed JSON treated absent"  '! runspec_present "$BAD"'
check "zero-byte file absent"          '! runspec_present "$EMPTY"'

echo "== runspec_mode (fail-open broad) =="
check "valid → patch"                  '[ "$(runspec_mode "$VALID")" = patch ]'
check "missing → broad"                '[ "$(runspec_mode "$MISSING")" = broad ]'
check "malformed → broad"              '[ "$(runspec_mode "$BAD")" = broad ]'
check "empty-arg → broad"              '[ "$(runspec_mode "")" = broad ]'
check "no .mode field → broad"         '[ "$(runspec_mode "$NOMODE")" = broad ]'

echo "== runspec_get =="
check "get objective"                  '[ "$(runspec_get "$VALID" ".objective")" = o ]'
check "get surface flag"               '[ "$(runspec_get "$VALID" ".surface.user_facing_copy")" = true ]'
check "get absent field → empty"       '[ -z "$(runspec_get "$VALID" ".nonexistent")" ]'
check "get on missing file → empty"    '[ -z "$(runspec_get "$MISSING" ".mode")" ]'

echo "== runspec_write_paths (drops absolute + parent-escaping) =="
WP="$(runspec_write_paths "$VALID")"
check "keeps src/**"                    'printf "%s\n" "$WP" | grep -qx "src/\*\*"'
check "keeps ok.txt"                    'printf "%s\n" "$WP" | grep -qx "ok.txt"'
check "drops absolute /abs/x"           '! printf "%s\n" "$WP" | grep -q "/abs/x"'
check "drops ../escape"                 '! printf "%s\n" "$WP" | grep -q "escape"'
check "exactly two globs survive"       '[ "$(printf "%s\n" "$WP" | grep -c .)" = 2 ]'
check "missing runspec → no output"     '[ -z "$(runspec_write_paths "$MISSING")" ]'

echo "== glob truth table: * stays within a segment =="
check "src/*.js matches src/a.js"           'pm "src/a.js" "src/*.js"'
check "src/*.js NOT across / (src/x/a.js)"  '! pm "src/sub/a.js" "src/*.js"'
check "*.txt matches top-level a.txt"       'pm "a.txt" "*.txt"'
check "*.txt NOT match x/a.txt"             '! pm "x/a.txt" "*.txt"'

echo "== glob truth table: ** crosses / =="
check "src/** matches src/a.js"             'pm "src/a.js" "src/**"'
check "src/** matches src/deep/x/a.js"      'pm "src/deep/x/a.js" "src/**"'
check "app/**/ui/** matches nested ui"      'pm "app/main/ui/Screen.kt" "app/**/ui/**"'
check "app/**/ui/** NOT match non-ui"       '! pm "app/main/data/Repo.kt" "app/**/ui/**"'

echo "== glob truth table: trailing / = whole subtree =="
check "src/ matches src/deep/x/a.js"        'pm "src/deep/x/a.js" "src/"'
check "src/ matches src/a.js"               'pm "src/a.js" "src/"'
check "src/ NOT match bare src (no child)"  '! pm "src" "src/"'

echo "== glob: exact file + ? =="
check "a.txt matches a.txt exactly"         'pm "a.txt" "a.txt"'
check "a.txt NOT match ab.txt"              '! pm "ab.txt" "a.txt"'
check "? matches one non-slash char"        'pm "a.c" "?.c"'
check "? NOT match a slash"                 '! pm "a/c" "?.c"'

echo "== abs_target: not-yet-existing nested path (regression #3) =="
DIR="$WORK/proj"; mkdir -p "$DIR"
DABS="$(cd "$DIR" && pwd -P)"                                    # canonical (macOS /var→/private)
AT="$(abs_target "$DIR" "sub/nested/New.kt")"                   # parents do NOT exist yet
check "resolves under existing dir"         '[ "$AT" = "$DABS/sub/nested/New.kt" ]'
check "did NOT collapse to /basename"       '[ "$AT" != "/New.kt" ]'
check "relative leaf in existing dir"       '[ "$(abs_target "$DIR" "x.txt")" = "$DABS/x.txt" ]'
check "absolute existing dir + missing tail" '[ "$(abs_target "$DIR" "$DABS/a/b.txt")" = "$DABS/a/b.txt" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
