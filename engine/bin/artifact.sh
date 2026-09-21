#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

IDIR_SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${1:-}"
PROJ="${2:-}"

if [ -z "$REPORT_DIR" ]; then
  rk="$(jq -r '.report_key // empty' "$IDIR_SELF/dispatch.json" 2>/dev/null || true)"
  [ -n "$rk" ] && REPORT_DIR="$SUP_STATE/reports/$rk"
  [ -z "$PROJ" ] && PROJ="$(cat "$IDIR_SELF/project" 2>/dev/null || true)"
fi
[ -n "$REPORT_DIR" ] || { echo "❌ не знаю, де звіт цього прогону — виклич як \$IDIR/artifact або передай теку" >&2; exit 1; }
[ -f "$REPORT_DIR/report.json" ] || {
  echo "❌ у $REPORT_DIR немає report.json — спершу напиши маніфест звіту" >&2; exit 1; }
if [ -z "$PROJ" ]; then PROJ="$(pwd -P)"; fi
PROJ="$(canon_path "$PROJ")"
[ -d "$PROJ" ] || { echo "❌ нема такої теки проєкту: $PROJ" >&2; exit 1; }

title="$(jq -r '.title // ""' "$REPORT_DIR/report.json" 2>/dev/null || true)"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9а-яґєії]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-48 | sed 's/-\{1,\}$//')"
[ -n "$slug" ] || slug="run"
stamp="$(date '+%Y-%m-%d-%H%M')"
OUT="$PROJ/artifacts/$stamp-$slug"

if [ -d "$PROJ/.git" ] || git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$PROJ" check-ignore -q "artifacts/x" 2>/dev/null; then
    gi="$PROJ/.gitignore"
    [ -f "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ] && printf '\n' >> "$gi"
    printf '# Артефакти нічних прогонів — вивід, не джерело\nartifacts/\n' >> "$gi"
    echo "· додав artifacts/ у .gitignore"
  fi
fi

mkdir -p "$OUT" || { echo "❌ не створив $OUT" >&2; exit 1; }
index="$(python3 "$BIN_DIR/artifact.py" "$REPORT_DIR" "$OUT" --title "$title" 2>&1)" || {
  echo "❌ артефакт не зібрався: $index" >&2; exit 1; }

ln -sfn "$stamp-$slug" "$PROJ/artifacts/latest" 2>/dev/null || true
printf '%s\n' "$index" > "$REPORT_DIR/artifact-path" 2>/dev/null || true

echo "✅ артефакт: $index"
echo "   відкрити: open \"$index\""
