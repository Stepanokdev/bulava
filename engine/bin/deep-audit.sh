#!/bin/bash
set -u
unset OPENAI_API_KEY CODEX_API_KEY ANTHROPIC_API_KEY 2>/dev/null || true
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"
  case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac
done
ROOT="$(cd "$(cd -P "$(dirname "$SELF")" && pwd)/.." && pwd)"
. "$ROOT/bin/supervisor-lib.sh"   # idempotent — only defines helpers/config (slug_for, run_reports_dir, SUP_INSTANCES)
CODEX_LOG="${SUPERVISOR_CODEX_LOG:-${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}/codex.log}"

GATE=0
if [ "${1:-}" = "--gate" ]; then GATE=1; shift; fi

PROJECT_DIR="${1:-$PWD}"
EXTRA="${2:-}"
cd "$PROJECT_DIR" || { echo "no such dir: $PROJECT_DIR"; exit 1; }

REQ_HINT=""
for cand in requirements docs/requirements specs SPEC.md README.md; do
  [ -e "$cand" ] && REQ_HINT="$REQ_HINT $cand,"
done
REQ_HINT="${REQ_HINT:-папку requirements/, SPEC.md, README.md}"

_slug="$(slug_for "$PROJECT_DIR")"
_rep="$(run_reports_dir "$_slug")"
if [ -d "$SUP_INSTANCES/$_slug" ]; then mkdir -p "$_rep" 2>/dev/null; OUT="$_rep/audit-$(date +%Y%m%d-%H%M).md"
else OUT="${TMPDIR:-/tmp}/audit-$(basename "$PROJECT_DIR")-$(date +%Y%m%d-%H%M).md"; fi

AUDIT_STATE=""
if [ -d "$SUP_INSTANCES/$_slug" ]; then
  _audit_sid="$(cat "$SUP_INSTANCES/$_slug/claude-session-id" 2>/dev/null || true)"
  if [ -n "$_audit_sid" ]; then
    AUDIT_STATE="$SUP_STATE/audit-state-$_audit_sid"
    printf '%s\n' audit_running > "$AUDIT_STATE"
  fi
fi

GATE_EXTRA=""
TIME_CAP=3600
if [ "$GATE" = 1 ]; then
  GATE_EXTRA="ВАЖЛИВО: найперший рядок звіту — строго 'VERDICT: PASS' або 'VERDICT: FAIL'. FAIL — якщо є критичні розриви з вимогами, фейки/заглушки в робочих сценаріях, або робота виглядає демо замість сервісу. Дрібні побажання — не привід для FAIL."
  TIME_CAP=2400
fi

prompt=$(sed -e "s|{{REQUIREMENTS_HINT}}|$REQ_HINT|" \
             -e "s|{{EVALUATOR_CONTEXT}}|${EXTRA:-Визнач сам із вимог, хто прийматиме цю роботу.}|" \
             -e "s|{{EXTRA}}|$GATE_EXTRA|" \
             "$ROOT/supervisor/AUDIT-PROMPT.md")

if [ "$GATE" = 0 ]; then
  echo "🔍 Глибокий аудит: $PROJECT_DIR"
  echo "   Звіт буде у: $OUT"
  echo "   (прогрес Codex нижче, це може зайняти 10-30 хвилин)"
  echo ""
fi

if [ "$GATE" = 1 ]; then
  perl -e 'alarm shift; exec @ARGV' "$TIME_CAP" \
    codex exec $(codex_effort_flags) -c tools.web_search=true --sandbox read-only --skip-git-repo-check \
    "$prompt" </dev/null > "$OUT" 2>>"$CODEX_LOG"
else
  perl -e 'alarm shift; exec @ARGV' "$TIME_CAP" \
    codex exec $(codex_effort_flags) -c tools.web_search=true --sandbox read-only --skip-git-repo-check \
    "$prompt" </dev/null > "$OUT"
fi

status=$?
if [ $status -eq 0 ] && [ -s "$OUT" ]; then
  if [ -n "$AUDIT_STATE" ]; then
    _audit_verdict="$(head -3 "$OUT" | grep -m1 -oE 'VERDICT: *(PASS|FAIL)' | grep -oE 'PASS|FAIL' || true)"
    case "$_audit_verdict" in
      PASS) printf '%s\n' audit_passed > "$AUDIT_STATE" ;;
      FAIL) printf '%s\n' audit_failed > "$AUDIT_STATE" ;;
      *)    printf '%s\n' audit_complete > "$AUDIT_STATE" ;;
    esac
  fi
  if [ "$GATE" = 1 ]; then
    echo "$OUT"   # machine mode: only the report path
  else
    echo ""
    echo "✅ Аудит готовий: $OUT"
    echo "   Далі: у застосунку відкрий звіт аудиту (Review → Audit), або: cat \"$OUT\""
  fi
else
  [ -n "$AUDIT_STATE" ] && printf '%s\n' audit_inconclusive > "$AUDIT_STATE"
  rm -f "$OUT"
  [ "$GATE" = 0 ] && echo "❌ Аудит не вдався (exit $status). Перевір codex login / мережу."
  exit 1
fi
