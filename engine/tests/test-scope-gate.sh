#!/bin/bash
# §11.3 — post-run scope-gate backstop. In a temp git repo with a patch-mode RunSpec
# (one write_path), make in-scope + out-of-scope changes across every class (committed,
# unstaged, untracked, a deletion, a rename), run scope-gate.sh, and assert:
#   • out-of-scope reverted/removed, in-scope preserved
#   • a scope-gate revert COMMIT exists on HEAD and BASE..HEAD shows no out-of-scope
#     path (regression #5 — an uncommitted revert would replay on a squash/merge)
#   • scope-violation.json.count correct, reports/quarantine.log written
# Plus no-op guarantees: broad / no-runspec / kill-switch ⇒ nothing reverted, no commit.
# Bash-3.2-safe throughout (no mapfile).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
SG="$ROOT/bin/scope-gate.sh"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

# Build a fresh repo with a base commit; echo its slug's IDIR + BASE via globals.
mkrepo(){
  REPO="$(mktemp -d)"; REPOS+=("$REPO")
  ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src \
      && echo base > src/app.txt && echo base > root.txt && echo del > del.txt && echo old > old.txt \
      && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$REPO")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$REPO")" > "$IDIR/project"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
  printf '%s\n' "$BASE" > "$IDIR/base-sha"
}
setspec(){ printf '%s' "$1" > "$IDIR/runspec.json"; }

echo "== patch mode: quarantine out-of-scope across all change classes =="
mkrepo
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
# in-scope changes (kept):
echo change >> "$REPO/src/app.txt"; git -C "$REPO" commit -qam "worker: in-scope commit" >/dev/null   # committed
echo new > "$REPO/src/new.txt"                                                                          # untracked, in scope
# out-of-scope changes (must be reverted/removed):
echo evil >> "$REPO/root.txt"                                                                           # unstaged tracked mod
echo evil2 > "$REPO/evil.txt"                                                                           # untracked
rm "$REPO/del.txt"                                                                                       # out-of-scope deletion
git -C "$REPO" mv old.txt new_out.txt && git -C "$REPO" commit -qm "worker: rename out-of-scope" >/dev/null  # rename (committed)

"$SG" "$REPO" "$IDIR" "$BASE" >/dev/null 2>&1

check "in-scope src/app.txt kept (has change)"  'grep -q change "$REPO/src/app.txt"'
check "in-scope src/new.txt kept"               '[ -f "$REPO/src/new.txt" ]'
check "out-of-scope root.txt restored to base"  '[ "$(cat "$REPO/root.txt")" = base ]'
check "out-of-scope evil.txt removed"           '[ ! -f "$REPO/evil.txt" ]'
check "out-of-scope deletion del.txt restored"  '[ -f "$REPO/del.txt" ]'
check "rename old side old.txt restored"        '[ -f "$REPO/old.txt" ]'
check "rename new side new_out.txt removed"     '[ ! -f "$REPO/new_out.txt" ]'

echo "== #5: revert is COMMITTED (survives a replay/squash merge) =="
check "scope-gate revert commit on HEAD" \
  'git -C "$REPO" log -1 --pretty=%s | grep -q "scope-gate: revert out-of-scope"'
DIFF="$(git -C "$REPO" diff "$BASE"..HEAD --name-only)"
check "BASE..HEAD keeps in-scope src/app.txt" 'printf "%s\n" "$DIFF" | grep -qx "src/app.txt"'
check "BASE..HEAD has NO out-of-scope new_out.txt" '! printf "%s\n" "$DIFF" | grep -qx "new_out.txt"'
check "BASE..HEAD has NO out-of-scope old.txt"     '! printf "%s\n" "$DIFF" | grep -qx "old.txt"'
check "BASE..HEAD has NO out-of-scope root.txt"    '! printf "%s\n" "$DIFF" | grep -qx "root.txt"'

echo "== marker + trail =="
check "scope-violation.json written"     '[ -s "$IDIR/scope-violation.json" ]'
# out-of-scope paths quarantined: root.txt, evil.txt, del.txt, old.txt, new_out.txt = 5
check "scope-violation.json count == 5"  '[ "$(jq -r .count "$IDIR/scope-violation.json")" = 5 ]'
check "mode recorded in marker"          '[ "$(jq -r .mode "$IDIR/scope-violation.json")" = patch ]'
check "quarantine.log written"           '[ -s "$IDIR/reports/quarantine.log" ]'

echo "== no-op: broad runspec ⇒ nothing reverted, no commit =="
mkrepo
setspec '{"schema":1,"mode":"broad","write_paths":["src/**"]}'
echo evil > "$REPO/rogue.txt"                                   # out-of-scope untracked
HEAD_BEFORE="$(git -C "$REPO" rev-parse HEAD)"
"$SG" "$REPO" "$IDIR" "$BASE" >/dev/null 2>&1
check "broad: rogue.txt untouched"       '[ -f "$REPO/rogue.txt" ]'
check "broad: no new commit"             '[ "$(git -C "$REPO" rev-parse HEAD)" = "$HEAD_BEFORE" ]'
check "broad: no scope-violation.json"   '[ ! -f "$IDIR/scope-violation.json" ]'

echo "== no-op: no runspec ⇒ backward compat no-op =="
mkrepo                                                          # no setspec
echo evil > "$REPO/rogue.txt"
"$SG" "$REPO" "$IDIR" "$BASE" >/dev/null 2>&1
check "no-runspec: rogue.txt untouched"  '[ -f "$REPO/rogue.txt" ]'
check "no-runspec: no scope-violation.json" '[ ! -f "$IDIR/scope-violation.json" ]'

echo "== no-op: kill switch SUPERVISOR_SCOPE_GATE=0 =="
mkrepo
setspec '{"schema":1,"mode":"patch","write_paths":["src/**"]}'
echo evil > "$REPO/rogue.txt"
SUPERVISOR_SCOPE_GATE=0 "$SG" "$REPO" "$IDIR" "$BASE" >/dev/null 2>&1
check "kill-switch: rogue.txt untouched"     '[ -f "$REPO/rogue.txt" ]'
check "kill-switch: no scope-violation.json" '[ ! -f "$IDIR/scope-violation.json" ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
