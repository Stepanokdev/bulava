#!/bin/bash
# One logo, three renderings.
#
# The `b` is described once, in the app (Night Shift/Design/BulavaGlyph.swift). The Dock icon is cut
# from it, the sidebar draws it, and the engine's HTML documents embed it as an SVG asset that
# `tools/icongen` writes out. That asset is the only copy Python can see, so it is also the only place
# the mark can silently drift: someone nudges a curve in Swift, the app and the icon move, and every
# report keeps shipping last month's logo.
#
# So: regenerate the asset and require it to match what is committed, and check that both documents
# actually carry it.
set -u
# The engine can be installed on its own, without the app checkout it was cut from. Everything the
# engine itself renders is still checked; only the comparison against the app's Swift geometry
# needs that checkout, and it says so rather than reporting a failure the installer cannot fix.
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ENGINE/bin"
ROOT="$(cd "$ENGINE/.." && pwd)"
APP_TREE=0
[ -f "$ROOT/tools/icongen/build.sh" ] && [ -d "$ROOT/Night Shift/Design" ] && APP_TREE=1

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf '  \xe2\x9e\x96 %s\n' "$1"; }

ASSET="$ENGINE/assets/brand-mark.svg"

echo "===== the shared asset exists and is a single filled path ====="

if [ -s "$ASSET" ]; then ok "assets/brand-mark.svg is present"; else bad "the asset is missing"; fi
svg="$(cat "$ASSET" 2>/dev/null)"
case "$svg" in *'viewBox="324 216 402 591"'*) ok "it carries the glyph's ink bounds" ;;
  *) bad "unexpected viewBox: ${svg:0:80}" ;; esac
case "$svg" in *'fill="currentColor"'*) ok "it inherits its colour from CSS" ;;
  *) bad "the mark hard-codes a colour" ;; esac
# ONE contour. The mark's negative space is a bay entered from the top, not a hole, so the traced
# outline is a single closed loop — a second `M` would mean someone broke it into pieces again.
subpaths="$(printf '%s' "$svg" | grep -o 'M[0-9]' | wc -l | tr -d ' ')"
if [ "$subpaths" = 1 ]; then ok "the outline is one closed contour"; else bad "expected 1 contour, got $subpaths"; fi
points="$(printf '%s' "$svg" | grep -o 'L[0-9]' | wc -l | tr -d ' ')"
if [ "$points" -gt 80 ]; then ok "it kept its detail ($points segments)"; else bad "the outline was flattened to $points segments"; fi

echo
echo "===== it has not drifted from the app's geometry ====="

if [ "$APP_TREE" = 0 ]; then
  skip "the app checkout is not here — the geometry it would be compared against is not installed"
elif command -v swiftc >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/icons"
  # Regenerated into a temp path: the check must not repair what it is checking.
  if (cd "$ROOT" && bash tools/icongen/build.sh "$TMP/icons" "$TMP/brand-mark.svg" >/dev/null 2>&1); then
    if diff -q "$ASSET" "$TMP/brand-mark.svg" >/dev/null 2>&1; then
      ok "the committed asset is what the current geometry produces"
    else
      bad "the asset and the geometry disagree — run tools/icongen/build.sh and commit the result"
    fi
    # The icon set is generated from the same file; a size that stops rendering is a broken release.
    count="$(ls "$TMP/icons"/*.png 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" = 10 ]; then ok "the icon set regenerates at all ten sizes"; else bad "icon set produced $count file(s)"; fi
  else
    bad "tools/icongen/build.sh failed"
  fi
else
  skip "swiftc not available — cannot check the asset against the geometry"
fi

echo
echo "===== every document Bulava produces carries the mark ====="

TMP2="$(mktemp -d)"
trap 'rm -rf "${TMP:-/nonexistent}" "$TMP2"' EXIT
mkdir -p "$TMP2/media"
jq -nc '{generated_human:"now", project_name:"p", project_dir:"/x", session_id:"s", branch:"main",
         base_sha:"aaaaaaaa", head_sha:"bbbbbbbb", language:"English", task:"t", narrative:"n",
         diffstat:"", files_changed:0, insertions:0, deletions:0, commits:[], media:[],
         evidence:null, stacks:[], format:"notes", items:[], findings:[], blocks:[], writer:"codex"}' \
  > "$TMP2/report.json"
NS_REPORT_DIR="$TMP2" NS_MEDIA_DIR="$TMP2/media" python3 "$BIN_DIR/report-render.py" >/dev/null 2>&1
report="$(cat "$TMP2/report.html" 2>/dev/null)"
case "$report" in *'class="brand"'*) ok "the run report has the lockup" ;; *) bad "no lockup in the run report" ;; esac
case "$report" in *'--brand-field:#16291c'*) ok "the report carries the brand plate colour" ;;
  *) bad "the report's palette is not the brand's" ;; esac
case "$report" in *'--acc:#4b7510'*) ok "its light accent is the deepened lime" ;;
  *) bad "the report's light accent is not the brand accent" ;; esac
case "$report" in *"#8b65ff"*|*"#6e4bff"*) bad "the old violet is still in the report" ;;
  *) ok "no trace of the old violet" ;; esac

jq -nc '{project_name:"p", ts:"now", outcome:"succeeded_changes", summary:"s",
          review:"passed", commits:[], findings:[], diffstat:"", task:"t"}' \
  | python3 "$BIN_DIR/receipt-render.py" "$TMP2/receipt.html" >/dev/null 2>&1
receipt="$(cat "$TMP2/receipt.html" 2>/dev/null)"
case "$receipt" in *'class="brand"'*) ok "the receipt has the lockup" ;; *) bad "no lockup in the receipt" ;; esac
case "$receipt" in *"#8b65ff"*|*"#6e4bff"*) bad "the old violet is still in the receipt" ;;
  *) ok "the receipt is on the brand palette" ;; esac

echo
[ "$fails" = 0 ] && echo "✅ brand mark: one source, no drift" || echo "❌ brand mark: $fails problem(s)"
exit "$fails"
