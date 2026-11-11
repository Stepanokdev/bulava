#!/bin/bash
# What a chat changed in a folder with no git — kept OUTSIDE that folder.
#
# A chat he sits at may work in a plain folder: no git, no checkpoint, no branch (night-shift.sh,
# SUPERVISOR_PLAIN_FOLDER). The review gate used to take such a run's word for how it ended, because
# there was no diff to read: «plain folder: no git and nothing to review — the declared outcome
# (succeeded_changes) stands». In the week of 3–10 Nov that is how code in MonitorControl, the
# roulette in Everything, AI Factory and IdeaBank was accepted with nobody reading a line.
#
# So at the start of such a run the folder's text files are copied into a git of the engine's own,
# in the run's instance folder (`plain-shadow/`, a bare repository whose work tree is his folder).
# Nothing is written into his folder: no .git, no fingerprint, no list. At the stop the same files
# are read again and the difference is a real patch the reviewer can read. After a review passes the
# base moves to what was accepted, so the next turn is measured from there.
#
# Only what a review can read is kept: files under SUPERVISOR_PLAIN_SHADOW_MAX_BYTES (1 MB), outside
# the usual build and dependency folders and outside repositories nested in the folder (those are
# reviewed as repositories — adopt_nested_repos). A folder of more than
# SUPERVISOR_PLAIN_SHADOW_MAX_FILES such files is not copied at all, and says so.
#
# Sourced by supervisor-lib.sh.

plain_shadow_dir() { printf '%s/plain-shadow' "${1:-}"; }

plain_shadow_present() {   # $1=instance dir
  git --git-dir="$(plain_shadow_dir "${1:-}")" rev-parse -q --verify refs/plain/base >/dev/null 2>&1
}

_plain_shadow_git() {   # $1=instance dir $2=folder, then git arguments
  local idir="$1" proj="$2"; shift 2
  git --git-dir="$(plain_shadow_dir "$idir")" --work-tree="$proj" \
      -c core.autocrlf=false -c core.quotepath=false -c core.safecrlf=false \
      -c user.name="Night Shift" -c user.email="night-shift@local" -c commit.gpgsign=false "$@"
}

_plain_shadow_max() {
  local max="${SUPERVISOR_PLAIN_SHADOW_MAX_BYTES:-1048576}"
  case "$max" in ''|*[!0-9]*) max=1048576 ;; esac
  printf '%s' "$max"
}

# The folder's files a review can read, NUL-separated and relative to it: no secrets, nothing over the
# size limit, nothing in dependency or build folders or nested repositories (lib/plain-shadow-scan.py).
_plain_shadow_files() {   # $1=folder
  python3 "$_SUP_BIN_DIR/lib/plain-shadow-scan.py" copy "$1" "$(_plain_shadow_max)" 2>/dev/null
}

# The files that are NOT copied — too large, or secrets — named with their size and time, so that one
# appearing, changing or going is still seen.
_plain_shadow_uncopied() {   # $1=folder
  python3 "$_SUP_BIN_DIR/lib/plain-shadow-scan.py" uncopied "$1" "$(_plain_shadow_max)" 2>/dev/null
}

# Stage the folder as it is now: changes and deletions of what is kept, and new files to keep.
_plain_shadow_stage() {   # $1=instance dir $2=folder
  local idir="$1" proj="$2" list
  list="$(mktemp 2>/dev/null)" || return 1
  _plain_shadow_files "$proj" > "$list"
  _plain_shadow_git "$idir" "$proj" add -u >/dev/null 2>&1 || { rm -f "$list"; return 1; }
  # Forced: what is copied is decided by the list above, not by a .gitignore lying in his folder —
  # a file it names would otherwise make the whole add fail, and nothing would be read at all.
  if [ -s "$list" ]; then
    GIT_LITERAL_PATHSPECS=1 _plain_shadow_git "$idir" "$proj" add -f --pathspec-from-file="$list" --pathspec-file-nul >/dev/null 2>&1 \
      || { rm -f "$list"; return 1; }
  fi
  rm -f "$list"
}

# At the start of a plain run. Never fails its caller: without a copy the gate says so and the
# run is judged as before.
plain_shadow_take() {   # $1=instance dir $2=folder
  local idir="${1:-}" proj="${2:-}" dir n maxf
  [ -n "$idir" ] && [ -d "$idir" ] && [ -d "$proj" ] && command -v git >/dev/null 2>&1 || return 0
  dir="$(plain_shadow_dir "$idir")"
  plain_shadow_present "$idir" && return 0
  rm -rf "$dir" "$idir/plain-shadow.skipped" 2>/dev/null
  maxf="${SUPERVISOR_PLAIN_SHADOW_MAX_FILES:-20000}"; case "$maxf" in ''|*[!0-9]*) maxf=20000 ;; esac
  n="$(_plain_shadow_files "$proj" | tr -cd '\0' | wc -c | tr -d ' ')"
  if [ "${n:-0}" -gt "$maxf" ]; then
    printf '%s files a review could read — more than %s, so no copy was taken\n' "$n" "$maxf" > "$idir/plain-shadow.skipped"
    return 0
  fi
  git init -q --bare "$dir" 2>/dev/null || { echo "git could not make the copy" > "$idir/plain-shadow.skipped"; return 0; }
  _plain_shadow_stage "$idir" "$proj" \
    || { rm -rf "$dir"; echo "the folder's files could not be copied" > "$idir/plain-shadow.skipped"; return 0; }
  _plain_shadow_git "$idir" "$proj" commit -q --allow-empty --no-verify -m "the folder when the run began" >/dev/null 2>&1 \
    && _plain_shadow_git "$idir" "$proj" update-ref refs/plain/base HEAD >/dev/null 2>&1 \
    || { rm -rf "$dir"; echo "the copy could not be committed" > "$idir/plain-shadow.skipped"; return 0; }
  _plain_shadow_uncopied "$proj" > "$dir/uncopied.base"
  return 0
}

# What changed since the base, one path per line (deletions included).
plain_shadow_changed() {   # $1=instance dir $2=folder
  local idir="$1" proj="$2"
  plain_shadow_present "$idir" || return 1
  _plain_shadow_stage "$idir" "$proj" || return 1
  _plain_shadow_git "$idir" "$proj" diff --cached --no-renames --name-only refs/plain/base 2>/dev/null
}

# Prose: a change to it alone needs no review of code.
_plain_shadow_not_prose() { grep -viE '\.(md|markdown|rst|adoc|txt)$' | grep . || true; }

# The same, without prose: what a review of code is owed for. Fails — distinct from "nothing" — when
# the comparison could not be made: an unread folder is never taken for an unchanged one.
plain_shadow_changed_code() {   # $1=instance dir $2=folder
  local all
  all="$(plain_shadow_changed "$1" "$2")" || return 1
  printf '%s\n' "$all" | _plain_shadow_not_prose
  return 0
}

# Files not copied — too large, or secrets — that appeared, changed or went since the base: named,
# never read. One per line: status<TAB>kind<TAB>path (status new|changed|deleted, kind large|secret).
plain_shadow_uncopied_changes() {   # $1=instance dir $2=folder
  local dir now
  dir="$(plain_shadow_dir "$1")"
  [ -f "$dir/uncopied.base" ] || return 0
  now="$(mktemp 2>/dev/null)" || return 1
  _plain_shadow_uncopied "$2" > "$now"
  python3 "$_SUP_BIN_DIR/lib/plain-shadow-scan.py" compare "$dir/uncopied.base" "$now" 2>/dev/null
  rm -f "$now"
}

# Their paths, as "path (what happened)", for the reviewer.
plain_shadow_unread() {   # $1=instance dir $2=folder
  plain_shadow_uncopied_changes "$1" "$2" | awk -F'\t' '{ printf "%s (%s, %s)\n", $3, $1, ($2 == "secret" ? "a secret — not read" : "too large to copy") }'
}

# Those of them owed a review: anything but prose.
plain_shadow_unread_code() {   # $1=instance dir $2=folder
  plain_shadow_uncopied_changes "$1" "$2" | cut -f3 | _plain_shadow_not_prose
}

# The patch for the reviewer, written into the instance folder. Prints its path.
plain_shadow_patch() {   # $1=instance dir $2=folder
  local idir="$1" proj="$2" out="$1/plain-diff.patch"
  plain_shadow_present "$idir" || return 1
  _plain_shadow_stage "$idir" "$proj" || return 1
  _plain_shadow_git "$idir" "$proj" diff --cached --no-renames --no-color refs/plain/base > "$out" 2>/dev/null || return 1
  printf '%s\n' "$out"
}

plain_shadow_stat() {   # $1=instance dir $2=folder
  plain_shadow_present "$1" || return 1
  _plain_shadow_git "$1" "$2" diff --cached --no-renames --stat refs/plain/base 2>/dev/null | tail -40
}

# After a review passed: what was accepted is the new base.
plain_shadow_advance() {   # $1=instance dir $2=folder
  local idir="$1" proj="$2"
  plain_shadow_present "$idir" || return 0
  _plain_shadow_stage "$idir" "$proj" || return 0
  _plain_shadow_git "$idir" "$proj" commit -q --allow-empty --no-verify -m "accepted by the review" >/dev/null 2>&1 \
    && _plain_shadow_git "$idir" "$proj" update-ref refs/plain/base HEAD >/dev/null 2>&1 \
    && _plain_shadow_uncopied "$proj" > "$(plain_shadow_dir "$idir")/uncopied.base"
  return 0
}

# The copy outlives the run folder that held it. Stop, the idle teardown, the stale cleanup and a
# resume all take that folder away; a resumed conversation must not take the folder as it is now —
# with work a review returned, or never saw — for its new base. The copy is kept beside the state,
# by the folder's slug, and a resume brings it back. A fresh start measures itself, and forgets it.
plain_shadow_kept() { printf '%s/plain-shadows/%s' "$SUP_STATE" "${1:-}"; }

plain_shadow_keep() {   # $1=instance dir (before it is removed)
  local idir="${1%/}" slug dst
  plain_shadow_present "$idir" || return 0
  slug="$(basename "$idir")"; dst="$(plain_shadow_kept "$slug")"
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
  rm -rf "$dst.tmp.$$" 2>/dev/null
  cp -Rp "$(plain_shadow_dir "$idir")" "$dst.tmp.$$" 2>/dev/null || { rm -rf "$dst.tmp.$$"; return 0; }
  rm -rf "$dst" 2>/dev/null; mv "$dst.tmp.$$" "$dst" 2>/dev/null || rm -rf "$dst.tmp.$$"
  return 0
}

plain_shadow_restore() {   # $1=new instance dir → 0 when a kept copy was brought back
  local idir="${1%/}" src
  [ -d "$idir" ] || return 1
  plain_shadow_present "$idir" && return 1
  src="$(plain_shadow_kept "$(basename "$idir")")"
  git --git-dir="$src" rev-parse -q --verify refs/plain/base >/dev/null 2>&1 || return 1
  rm -rf "$(plain_shadow_dir "$idir")" 2>/dev/null
  cp -Rp "$src" "$(plain_shadow_dir "$idir")" 2>/dev/null || return 1
  plain_shadow_present "$idir"
}

plain_shadow_forget() {   # $1=slug
  rm -rf "$(plain_shadow_kept "${1:-}")" 2>/dev/null; return 0
}

# Whether a run is an automation's, with nobody at the computer (run-env, written at its start).
run_unattended() {   # $1=instance dir
  grep -qx "export SUPERVISOR_UNATTENDED='1'" "$(run_env_file "${1:-}")" 2>/dev/null
}
