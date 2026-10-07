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
    worker_untracked "$cwd" "$IDIR"; } | sort -u
)

# A run that started on top of the director's uncommitted work measures against a snapshot of it
# (`snapshot_director_work`). Putting a file «back to base» then means back to THEIR version — and
# only on disk and in the index as they had it, never through a commit: an automatic revert commit
# here would carry their half-finished edit into history, which is the very thing that snapshot
# exists to prevent.
snapshot_base=0
[ -f "$IDIR/base-snapshot" ] && snapshot_base=1
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
  if [ "$snapshot_base" = 1 ] && git -C "$cwd" cat-file -e "$BASE:$rel" 2>/dev/null; then
    action="restored"                                   # tracked: their staged and on-disk versions
    if git -C "$cwd" cat-file -e "$BASE^2:$rel" 2>/dev/null; then
      git -C "$cwd" restore --source="$BASE^2" --staged -- "$rel" 2>/dev/null || action="restore_failed"
    else
      git -C "$cwd" rm -q --cached --ignore-unmatch -- "$rel" 2>/dev/null || action="restore_failed"
    fi
    git -C "$cwd" restore --source="$BASE" --worktree -- "$rel" 2>/dev/null || action="restore_failed"
  elif [ "$snapshot_base" = 1 ] && git -C "$cwd" cat-file -e "$BASE^3:$rel" 2>/dev/null; then
    action="restored"                                   # one of their untracked files: put it back as it was
    git -C "$cwd" rm -q --cached --ignore-unmatch -- "$rel" 2>/dev/null || true
    mkdir -p "$(dirname "$cwd/$rel")" 2>/dev/null
    git -C "$cwd" cat-file blob "$BASE^3:$rel" > "$cwd/$rel" 2>/dev/null || action="restore_failed"
  elif git -C "$cwd" cat-file -e "$BASE:$rel" 2>/dev/null; then
    action="restored"                                   # existed at base → revert to base content
    git -C "$cwd" checkout "$BASE" -- "$rel" 2>/dev/null || action="restore_failed"
  elif was_ignored_at_start "$IDIR" "$rel"; then
    # Ignored when the run began, so not in the base — and not new either. It became visible because
    # an ignore rule changed; the file itself was already there, and it is not ours to delete.
    action="kept_ignored_at_start"
    git -C "$cwd" rm -q --cached --ignore-unmatch -- "$rel" 2>/dev/null || true
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

if [ "$snapshot_base" = 0 ] && [ "${#commit_paths[@]}" -gt 0 ] && git -C "$cwd" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
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
