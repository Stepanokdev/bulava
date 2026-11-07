#!/bin/bash
# The verifier's "python compiles" step checks the project's own files and nothing else.
#
# It used to run `compileall .`, which walked into the project's .venv: a dependency written for
# Python 2 failed there, and a piece Codex had passed was failed for a file nobody wrote
# (Tenders automation, 2026-11-05).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
VERIFY="$ROOT/bin/verify.sh"
PYC="$ROOT/bin/lib/py-compile-project.py"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

TMPS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "${TMPS[@]}"; }
trap cleanup EXIT

# A python project with a committed good module and a .venv holding Python 2 code.
newproj(){
  local p; p="$(mktemp -d)"; TMPS+=("$p")
  ( cd "$p" && git init -q && git config user.email t@t && git config user.name t
    printf 'requests\n' > requirements.txt
    printf 'def ok():\n    return 1\n' > app.py
    mkdir -p .venv/lib/python3.12/site-packages/olefile
    printf 'print "python 2"\n' > .venv/lib/python3.12/site-packages/olefile/olefile2.py
    git add requirements.txt app.py && git commit -qm init >/dev/null )
  printf '%s' "$p"
}
status_of(){   # $1=evidence.json → status of the python step
  jq -r '.criteria[] | select(.criterion == "python compiles") | .status' "$1" 2>/dev/null
}
run_verify(){  # $1=project → evidence.json path
  local idir; idir="$(instance_dir "$(slug_for "$1")")"; mkdir -p "$idir"
  printf '%s\n' "$(canon_path "$1")" > "$idir/project"
  # The run's base is the project's first commit; without one the verifier refuses a full build.
  git -C "$1" rev-list --max-parents=0 HEAD > "$idir/base-sha"
  "$VERIFY" "$1" "py-$RANDOM" 2>/dev/null
}

echo "== broken Python inside an untracked, un-ignored .venv does not fail the step =="
P="$(newproj)"
check "helper ignores .venv"             '[ "$(python3 "$PYC" "$P" --count)" = 1 ]'
check "helper passes"                    'python3 "$PYC" "$P" >/dev/null'
EV="$(run_verify "$P")"
check "verifier step passes"             '[ "$(status_of "$EV")" = pass ]'
check "no __pycache__ left in the tree"  '[ -z "$(find "$P" -name __pycache__ -not -path "*/.venv/*")" ]'

echo "== a broken tracked file whose name has a space fails =="
P="$(newproj)"
printf 'def broken(:\n' > "$P/my module.py"; git -C "$P" add "my module.py"; git -C "$P" commit -qm b >/dev/null
OUT="$(python3 "$PYC" "$P")"; rc=$?
check "helper exits non-zero"            '[ "$rc" -ne 0 ]'
check "names the file"                   'grep -q "my module.py" <<<"$OUT"'
EV="$(run_verify "$P")"
check "verifier step fails"              '[ "$(status_of "$EV")" = fail ]'

echo "== a broken new, untracked project file fails =="
P="$(newproj)"
printf 'x = (\n' > "$P/new_thing.py"
check "helper exits non-zero"            '! python3 "$PYC" "$P" >/dev/null'
EV="$(run_verify "$P")"
check "verifier step fails"              '[ "$(status_of "$EV")" = fail ]'

echo "== an ignored file is not the project's =="
P="$(newproj)"
printf 'generated/\n' > "$P/.gitignore"; mkdir -p "$P/generated"; printf 'print "x"\n' > "$P/generated/old.py"
check "helper passes"                    'python3 "$PYC" "$P" >/dev/null'

echo "== a tracked file deleted from the working tree is not compiled =="
P="$(newproj)"
rm "$P/app.py"
check "helper passes with nothing left"  'python3 "$PYC" "$P" >/dev/null'
check "count is 0"                       '[ "$(python3 "$PYC" "$P" --count)" = 0 ]'

echo "== a python project with no .py files is skipped, not failed =="
P="$(newproj)"
git -C "$P" rm -q app.py && git -C "$P" commit -qm rm >/dev/null
EV="$(run_verify "$P")"
check "verifier step skipped"            '[ "$(status_of "$EV")" = skipped ]'

echo "== outside git the walk still leaves the .venv out =="
P="$(mktemp -d)"; TMPS+=("$P")
mkdir -p "$P/.venv/x" "$P/src"
printf 'print "py2"\n' > "$P/.venv/x/a.py"; printf 'y = 2\n' > "$P/src/b.py"
check "count is 1"                       '[ "$(python3 "$PYC" "$P" --count)" = 1 ]'
check "helper passes"                    'python3 "$PYC" "$P" >/dev/null'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
