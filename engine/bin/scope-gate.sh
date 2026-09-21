#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

cwd="$1"; IDIR="$2"; BASE="$3"
[ "${SUPERVISOR_SCOPE_GATE:-1}" = 1 ] || exit 0
runspec_present "$IDIR" || exit 0
mode="$(runspec_mode "$IDIR")"; [ "$mode" = broad ] && exit 0
[ -n "$BASE" ] && git -C "$cwd" cat-file -e "$BASE" 2>/dev/null || exit 0

changed=()
while IFS= read -r l; do [ -n "$l" ] && changed+=("$l"); done < <(
  { git -C "$cwd" diff --no-renames --name-only "$BASE" -- 2>/dev/null
    git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null; } | sort -u
)
[ "${#changed[@]}" -gt 0 ] || exit 0

in_scope() {  # $1=relpath
  [ "$mode" = audit ] && return 1
  local g
  while IFS= read -r g; do [ -n "$g" ] && path_matches_glob "$1" "$g" && return 0; done \
    < <(runspec_write_paths "$IDIR")
  return 1
}

quarantined=()      # JSON records for the marker
qpaths=()           # raw rel paths (all quarantined) — for the marker/log
commit_paths=()     # committable subset: paths git knows (in HEAD or staged), never untracked-removed
for rel in "${changed[@]}"; do
  in_scope "$rel" && continue
  case "$(basename "$rel")" in AUDIT-*.md|BLOCKED.md|REVIEW-DEBT.md|DECISIONS.md) continue;; esac
  if git -C "$cwd" cat-file -e "$BASE:$rel" 2>/dev/null; then
    action="restored"                                   # existed at base → revert to base content
    git -C "$cwd" checkout "$BASE" -- "$rel" 2>/dev/null || action="restore_failed"
  else
    action="removed"                                    # new file (tracked-new or untracked) → drop
    git -C "$cwd" rm -f --cached -- "$rel" 2>/dev/null || true
    rm -f "$cwd/$rel" 2>/dev/null || action="remove_failed"
  fi
  quarantined+=("$(jq -n --arg p "$rel" --arg a "$action" '{path:$p,action:$a}')")
  qpaths+=("$rel")
  if git -C "$cwd" cat-file -e "HEAD:$rel" 2>/dev/null \
     || git -C "$cwd" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    commit_paths+=("$rel")
  fi
done

[ "${#quarantined[@]}" -gt 0 ] || exit 0

if [ "${#commit_paths[@]}" -gt 0 ] && git -C "$cwd" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
  git -C "$cwd" add -A -- "${commit_paths[@]}" 2>/dev/null || true
  if ! git -C "$cwd" diff --cached --quiet -- "${commit_paths[@]}" 2>/dev/null; then
    git -C "$cwd" commit -q -m "scope-gate: revert out-of-scope changes (RunSpec quarantine)" -- "${commit_paths[@]}" 2>/dev/null || true
  fi
fi

mkdir -p "$IDIR/reports"
printf '%s\n' "${quarantined[@]}" | jq -s \
  --arg base "$BASE" --arg mode "$mode" --argjson at "$(date +%s)" \
  '{schema:1, detected_at:$at, base_sha:$base, mode:$mode, count:(length), quarantined:.}' \
  > "$IDIR/scope-violation.json.tmp" && mv -f "$IDIR/scope-violation.json.tmp" "$IDIR/scope-violation.json"
{ echo "## $(date '+%F %T') scope-violation (${#quarantined[@]} paths, mode=$mode)"; printf '%s\n' "${quarantined[@]}"; } >> "$IDIR/reports/quarantine.log"
echo "$(date '+%F %T') [scope-gate] quarantined ${#quarantined[@]} out-of-scope path(s)" >> "$SUP_STATE/supervisor.log"
exit 0
