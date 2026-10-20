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

# The same request built again — the contract asks for exactly that after a correction — goes back
# into the folder it was built in, not a new dated one. A new folder each time left the chat holding
# the first one: once that was removed, "Open report" said the file was missing while the report sat
# next to it under another name. The request's own folder name is the key, kept inside the result.
REQUEST_KEY="$(basename "$REPORT_DIR")"
for marker in "$PROJ"/artifacts/*/.report-request; do
  [ -f "$marker" ] || continue
  # A link to a report folder (`latest`, or one left where an old path was) is not the folder: the
  # rebuild would replace the link and leave the real folder behind with the old page.
  [ -L "$(dirname "$marker")" ] && continue
  if [ "$(tr -d '[:space:]' < "$marker" 2>/dev/null)" = "$REQUEST_KEY" ]; then
    OUT="$(dirname "$marker")"
    break
  fi
done

if [ -d "$PROJ/.git" ] || git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1; then
  if ! git -C "$PROJ" check-ignore -q "artifacts/x" 2>/dev/null; then
    gi="$PROJ/.gitignore"
    [ -f "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ] && printf '\n' >> "$gi"
    printf '# Артефакти нічних прогонів — вивід, не джерело\nartifacts/\n' >> "$gi"
    echo "· додав artifacts/ у .gitignore"
  fi
fi

# Built beside it and put in place whole, so a page already open never shows half a rebuild.
BUILD="$PROJ/artifacts/.building-$$"
rm -rf "$BUILD"
mkdir -p "$BUILD" || { echo "❌ не створив $BUILD" >&2; exit 1; }
built="$(python3 "$BIN_DIR/artifact.py" "$REPORT_DIR" "$BUILD" --title "$title" 2>&1)" || {
  rm -rf "$BUILD"; echo "❌ артефакт не зібрався: $built" >&2; exit 1; }
printf '%s\n' "$REQUEST_KEY" > "$BUILD/.report-request"
if [ -d "$OUT" ]; then
  OLD="$PROJ/artifacts/.replaced-$$"
  mv "$OUT" "$OLD" && mv "$BUILD" "$OUT" && rm -rf "$OLD" || {
    [ -d "$OLD" ] && [ ! -d "$OUT" ] && mv "$OLD" "$OUT"
    rm -rf "$BUILD"; echo "❌ не зміг замінити $OUT" >&2; exit 1; }
else
  mv "$BUILD" "$OUT" || { rm -rf "$BUILD"; echo "❌ не створив $OUT" >&2; exit 1; }
fi
index="$OUT/${built##*/}"

ln -sfn "$(basename "$OUT")" "$PROJ/artifacts/latest" 2>/dev/null || true
printf '%s\n' "$index" > "$REPORT_DIR/artifact-path" 2>/dev/null || true

echo "✅ артефакт: $index"
echo "   відкрити: open \"$index\""
