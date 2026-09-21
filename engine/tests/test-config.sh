#!/bin/bash
# §11.7 — supervisor/config.sh defaults are the documented values, and env-first (:=)
# precedence holds (a value set BEFORE sourcing wins). This makes the invariant in
# config.sh:7-8 ("every default matches README §Settings") an enforced contract,
# not a comment — a silent default change now fails a test.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

# Resolve a default with a CLEAN slate: unset every SUPERVISOR_* var first so an ambient
# override in the caller's environment can't mask the real default.
read_default(){ ( for v in $(compgen -v | grep '^SUPERVISOR_'); do unset "$v" 2>/dev/null; done
                  . "$ROOT/supervisor/config.sh"; printf '%s' "${!1}" ); }

echo "== documented defaults (INVARIANT: code == README §Налаштування) =="
check "MAX_ROUNDS=3"                 '[ "$(read_default SUPERVISOR_MAX_ROUNDS)" = 3 ]'
check "MAX_ROUNDS_HARD=12"           '[ "$(read_default SUPERVISOR_MAX_ROUNDS_HARD)" = 12 ]'
check "STALL_LIMIT=2"                '[ "$(read_default SUPERVISOR_STALL_LIMIT)" = 2 ]'
check "USAGE_GUARD=100"              '[ "$(read_default SUPERVISOR_USAGE_GUARD)" = 100 ]'
check "USAGE_WEEK_GUARD=100"         '[ "$(read_default SUPERVISOR_USAGE_WEEK_GUARD)" = 100 ]'
check "VERIFY_GUARD=100"             '[ "$(read_default SUPERVISOR_VERIFY_GUARD)" = 100 ]'
check "MAX_REMEDIATIONS=1"           '[ "$(read_default SUPERVISOR_MAX_REMEDIATIONS)" = 1 ]'
check "OUTCOME_NUDGE_MAX=2"          '[ "$(read_default SUPERVISOR_OUTCOME_NUDGE_MAX)" = 2 ]'
check "IDLE_KILL_HOURS=4"            '[ "$(read_default SUPERVISOR_IDLE_KILL_HOURS)" = 4 ]'
check "STALE_DISABLE_HOURS=10"       '[ "$(read_default SUPERVISOR_STALE_DISABLE_HOURS)" = 10 ]'
check "VERIFIER_ENABLED=1"           '[ "$(read_default SUPERVISOR_VERIFIER_ENABLED)" = 1 ]'
check "SCOPE_GATE=1"                 '[ "$(read_default SUPERVISOR_SCOPE_GATE)" = 1 ]'
check "BOUNDED_REVIEW=1"             '[ "$(read_default SUPERVISOR_BOUNDED_REVIEW)" = 1 ]'
check "LEGACY_REPO_NOTES=0 (debt stays OUT of the reviewed repo)" \
                                     '[ "$(read_default SUPERVISOR_LEGACY_REPO_NOTES)" = 0 ]'
check "OUTCOME_PROTOCOL=1"           '[ "$(read_default SUPERVISOR_OUTCOME_PROTOCOL)" = 1 ]'
check "COLLABORATION_MODE=adaptive_peer" '[ "$(read_default SUPERVISOR_COLLABORATION_MODE)" = adaptive_peer ]'
check "CONSULT_TIMEOUT=900"          '[ "$(read_default SUPERVISOR_CONSULT_TIMEOUT)" = 900 ]'
check "PREFLIGHT_TOTAL_TIMEOUT=2400"  '[ "$(read_default SUPERVISOR_PREFLIGHT_TOTAL_TIMEOUT)" = 2400 ]'
check "PUMP_IDLE_WAIT=28800"          '[ "$(read_default SUPERVISOR_PUMP_IDLE_WAIT)" = 28800 ]'
check "KEEP_MESSAGE_ARTIFACTS=12"     '[ "$(read_default SUPERVISOR_KEEP_MESSAGE_ARTIFACTS)" = 12 ]'
check "no automatic audit tuning remains" \
                                     '! grep -q "SUPERVISOR_AUDIT_GUARD\|SUPERVISOR_AUDIT_MAX_ATTEMPTS" "$ROOT/supervisor/config.sh"'

echo "== env-first precedence: a value set BEFORE sourcing wins (:=) =="
with_override(){ SUPERVISOR_MAX_ROUNDS=99 bash -c '. "'"$ROOT"'/supervisor/config.sh"; printf "%s" "$SUPERVISOR_MAX_ROUNDS"'; }
check "pre-set SUPERVISOR_MAX_ROUNDS=99 wins" '[ "$(with_override)" = 99 ]'

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
