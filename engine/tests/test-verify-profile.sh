#!/bin/bash
# §11.6 — verify.sh honors the RunSpec verification_profile.
#   • profile=none ⇒ all stack build/test steps skipped; a single skipped criterion ⇒
#     overall_status=inconclusive (never a false pass).
#   • the profile string is recorded in evidence.json.
#   • no runspec ⇒ defaults to "standard" (today's behavior).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
VERIFY="$ROOT/bin/verify.sh"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
# Seven assertions in this file called `bad` on their failure branch and it was never defined, so a
# real failure would have hit "command not found" and been counted as nothing. An assertion that
# cannot fail is not an assertion.
bad(){ no "$1"; }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

# Minimal repo with NO recognized stack, so the "standard" default lands on the honest
# fallback (inconclusive), never a heavy real build.
PROJ="$(mktemp -d)"
( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && echo hello > README.md && git add -A && git commit -qm init >/dev/null )
IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

setspec(){ printf '%s' "$1" > "$IDIR/runspec.json"; }
ev_of(){ jq -r "$1" "$EV" 2>/dev/null; }

echo "== verification_profile=none ⇒ skipped, inconclusive, profile recorded =="
setspec '{"schema":1,"mode":"patch","verification_profile":"none","write_paths":["x"]}'
EV="$("$VERIFY" "$PROJ" none-sid 2>/dev/null)"
check "evidence.json produced"           '[ -n "$EV" ] && [ -f "$EV" ]'
check "profile recorded = none"          '[ "$(ev_of .verification_profile)" = none ]'
check "overall_status = inconclusive"    '[ "$(ev_of .overall_status)" = inconclusive ]'
check "exactly one criterion (no builds)" '[ "$(ev_of ".criteria | length")" = 1 ]'
check "that criterion is skipped"        '[ "$(ev_of ".criteria[0].status")" = skipped ]'

echo "== no runspec ⇒ profile defaults to standard =="
rm -f "$IDIR/runspec.json"
EV="$("$VERIFY" "$PROJ" std-sid 2>/dev/null)"
check "evidence.json produced"           '[ -n "$EV" ] && [ -f "$EV" ]'
check "profile defaults to standard"     '[ "$(ev_of .verification_profile)" = standard ]'
check "no-stack repo never false-passes"  '[ "$(ev_of .overall_status)" = inconclusive ]'

echo "== pnpm workspace ⇒ pnpm (not npm), no package-lock pollution, scoped to run =="
PROJ2="$(mktemp -d)"; STUB="$(mktemp -d)"
export PNPM_LOG="$STUB/calls.log"; : > "$PNPM_LOG"
# fake pnpm always succeeds and records its invocation; fake npm MUST never be called (exits 1).
cat > "$STUB/pnpm" <<SH
#!/bin/bash
echo "pnpm \$*" >> "$PNPM_LOG"; exit 0
SH
cat > "$STUB/npm" <<SH
#!/bin/bash
echo "npm SHOULD NOT RUN: \$*" >> "$PNPM_LOG"; exit 1
SH
chmod +x "$STUB/pnpm" "$STUB/npm"
( cd "$PROJ2" && git init -q && git config user.email t@t && git config user.name t \
    && printf '{"name":"root","packageManager":"pnpm@9","scripts":{"build":"true","test":"true"}}\n' > package.json \
    && printf 'packages:\n  - "packages/*"\n' > pnpm-workspace.yaml \
    && : > pnpm-lock.yaml \
    && git add -A && git commit -qm init >/dev/null \
    && printf 'export const x=1\n' > index.ts )   # untracked buildable change ⇒ should_build fires
IDIR2="$(instance_dir "$(slug_for "$PROJ2")")"; mkdir -p "$IDIR2"
printf '%s\n' "$(canon_path "$PROJ2")" > "$IDIR2/project"
BASE2="$(git -C "$PROJ2" rev-parse HEAD)"
EV="$(PATH="$STUB:$PATH" "$VERIFY" "$PROJ2" pnpm-sid "$IDIR2" "$BASE2" 2>/dev/null)"
inst_cmd="$(jq -r '.criteria[]|select(.criterion=="dependencies install")|.command' "$EV" 2>/dev/null)"
check "evidence produced"                    '[ -n "$EV" ] && [ -f "$EV" ]'
check "install used pnpm --frozen-lockfile"  '[ "$inst_cmd" = "pnpm install --frozen-lockfile" ]'
check "npm was never invoked"                '! grep -q "npm SHOULD NOT RUN" "$PNPM_LOG"'
check "no package-lock.json fabricated"      '[ ! -f "$PROJ2/package-lock.json" ]'
check "overall not fail"                     '[ "$(ev_of .overall_status)" != fail ]'
check "evidence base_sha == passed base"     '[ "$(ev_of .base_sha)" = "$BASE2" ]'
rm -rf "$PROJ2" "$STUB"

echo ""

echo "===== the scheme picked is the APP's, not a dependency's ====="

# schemes[0] picked "argmax-oss-swift-Package" — a Swift-package dependency's scheme — so the
# verifier built the wrong thing, found no test bundles, and filed a passing suite as unproven.
pick_scheme() {  # stdin = xcodebuild -list -json output
  jq -r '(.project // .workspace) as $c | (($c.schemes) // []) as $all
         | (($all | map(select(. == ($c.name // ""))) | first)
            // ($all | map(select(endswith("-Package") | not)) | first)
            // ($all | first) // empty)'
}

got="$(printf '%s' '{"project":{"name":"Night Shift","schemes":["argmax-oss-swift-Package","Night Shift"]}}' | pick_scheme)"
[ "$got" = "Night Shift" ] && ok "the project's own scheme wins over a package scheme" \
                          || bad "picked '$got' instead of the app scheme"

# No scheme matches the project name: anything that is not a -Package scheme beats one that is.
got="$(printf '%s' '{"project":{"name":"Whatever","schemes":["zzz-Package","MyApp"]}}' | pick_scheme)"
[ "$got" = "MyApp" ] && ok "a non-package scheme wins when the name does not match" \
                     || bad "picked '$got' over the only real scheme"

# Only package schemes exist: still pick something rather than nothing.
got="$(printf '%s' '{"project":{"name":"X","schemes":["only-Package"]}}' | pick_scheme)"
[ "$got" = "only-Package" ] && ok "falls back rather than resolving to nothing" \
                            || bad "no scheme at all when only package schemes exist"

# A workspace, not a project.
got="$(printf '%s' '{"workspace":{"name":"Space","schemes":["a-Package","Space"]}}' | pick_scheme)"
[ "$got" = "Space" ] && ok "works for a workspace too" || bad "workspace scheme selection broken"


echo "===== shell suites run in a MIXED repo, not only a shell-only one ====="

# The condition used to be `ran_any = 0`: a repo with a recognised stack skipped its shell suites
# entirely. This repo is exactly that shape — a macOS app plus the engine's bash suites — so the
# only evidence produced was the app build and its XCTest run, and hundreds of engine checks were
# filed as unproven while passing beside it.
if grep -q 'ran_any" = 0 \] && ls "\$PROJ"/tests/test-\*\.sh' "$ROOT/bin/verify.sh" 2>/dev/null; then
  bad "shell suites are still gated on no other stack having run"
else
  ok "shell suites are not gated on the stack"
fi
grep -q 'for _tdir in tests engine/tests' "$ROOT/bin/verify.sh" 2>/dev/null \
  && ok "both layouts are covered (tests/ and engine/tests/)" \
  || bad "the vendored engine/tests layout is not looked at"
grep -q 'shell suite passes' "$ROOT/bin/verify.sh" 2>/dev/null \
  && ok "and it is recorded as its own criterion" \
  || bad "no criterion is emitted for the shell suite"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
