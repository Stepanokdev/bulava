#!/bin/bash
# The harness creates no branch. Ever.
#
# `start` used to cut `night/<ts>` whenever the checkout sat on main — which is where a repository
# normally sits — so every start, every restart and every resume left another branch behind, and the
# director had to delete them by hand. His instruction is the policy: branches are the foreman's
# decision, taken only when the work needs one, and communicated by NAME. That named ask is the only
# path on which this engine creates a branch.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"
mkdir -p "$SUPERVISOR_STATE_DIR"
. "$BIN_DIR/supervisor-lib.sh"

decide() {  # $1=current branch  [$2=mode]  [$3=requested branch]
  SUPERVISOR_BRANCH_MODE="${2:-current}" SUPERVISOR_WORK_BRANCH="${3:-}" \
    choose_branch_action "$1"
}

echo "===== on main, nothing is created ====="

got="$(decide main)"
[ "$got" = "reuse main" ] && ok "main is worked on directly, not branched away from" \
                          || bad "got '$got' — the harness still wants a branch on main"

got="$(decide feature/x)"
[ "$got" = "reuse feature/x" ] && ok "a feature branch is reused as-is" || bad "got '$got'"

got="$(decide night/20260805-180717)"
[ "$got" = "reuse night/20260805-180717" ] && ok "an existing night branch is reused, not multiplied" \
                                           || bad "got '$got'"

echo "===== a detached HEAD is worked in place, not branched ====="

got="$(decide "")"
[ "$got" = "inplace" ] && ok "detached HEAD stays detached" \
                       || bad "got '$got' — a branch would be created for a detached HEAD"

echo "===== the foreman's named ask is the only creation path ====="

got="$(decide main current "variant/2-dark-hero")"
[ "$got" = "use variant/2-dark-hero" ] && ok "a named branch is honoured" || bad "got '$got'"

got="$(decide feature/x current "variant/1")"
[ "$got" = "use variant/1" ] && ok "and it wins over the branch already checked out" || bad "got '$got'"

got="$(decide "" current "variant/1")"
[ "$got" = "use variant/1" ] && ok "even from a detached HEAD" || bad "got '$got'"

echo "===== the legacy always-branch mode still exists, but only when asked for ====="

got="$(decide main new)"
[ "$got" = "new" ] && ok "mode=new still cuts a night branch" || bad "got '$got'"
got="$(decide main)"
[ "$got" = "reuse main" ] && ok "and it is NOT the default" || bad "the default still creates"

echo "===== the config default is 'create nothing' ====="

out="$(env -u SUPERVISOR_BRANCH_MODE -u SUPERVISOR_WORK_BRANCH \
       bash -c '. "'"$BIN_DIR"'/../supervisor/config.sh" >/dev/null 2>&1; printf "%s|%s" "$SUPERVISOR_BRANCH_MODE" "$SUPERVISOR_WORK_BRANCH"')"
[ "$out" = "current|" ] && ok "config ships mode=current with no branch requested" \
                        || bad "config default is '$out'"

echo "===== start's own creation site is behind the named ask ====="

# Only one `checkout -qb` may remain outside the legacy mode, and it must be in the `use` branch.
grep -q 'Створив гілку .* — на замовлення бригадира' "$BIN_DIR/night-shift.sh" \
  && ok "the creation is attributed to the foreman's request" \
  || bad "no evidence the creation is gated on a request"
grep -q 'Гілку не створюю' "$BIN_DIR/night-shift.sh" \
  && ok "and a detached HEAD says so out loud" || bad "in-place start is silent"
grep -q '\-\-branch' "$BIN_DIR/night-shift.sh" \
  && ok "start accepts --branch" || bad "there is no way to ask for a branch by name"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
