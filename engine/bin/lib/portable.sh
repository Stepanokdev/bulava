#!/bin/bash
# The BSD spellings this engine was written in, answered on GNU systems — Linux and WSL2.
#
# The engine grew up on macOS, and about forty call sites say `stat -f %m`, `date -r <epoch>`,
# `date -v-3H`, `mktemp -t name` or `shasum`. On GNU coreutils most of those do not fail — they mean
# something else. `stat -f %m file` is "file-system status" for a file called `%m` plus the real
# file, several lines of it, so the `|| echo 0` after it never fires and the arithmetic that reads it
# breaks. `date -r 1700000000` looks for a file of that name.
#
# Rewriting each call site would put forty edits on the path the Mac app runs every few seconds.
# Instead, on a system whose tools are not BSD's, a function of the same name stands in front of the
# real command and translates just these spellings; everything else goes straight through. On macOS
# nothing in this file is defined at all, so what the app runs there is byte for byte what it ran
# before.
#
# Sourced by supervisor-lib.sh, and by the few scripts that run without it. Functions reach command
# substitutions and subshells of the shell that sourced this; a separate `bash -c` sources it again.

case "${OSTYPE:-}" in darwin*) return 0 2>/dev/null || exit 0 ;; esac
# Only GNU tools need translating. A BSD userland that is not macOS (FreeBSD) speaks these already.
command stat --version >/dev/null 2>&1 || { return 0 2>/dev/null || exit 0; }

stat() {
  local deref="" fmt="" a
  local -a files=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -L) deref="-L" ;;
      -f) fmt="${2:-}"; shift ;;
      -c|--format=*|--printf=*|--*) command stat "$@"; return ;;
      *) files+=("$1") ;;
    esac
    shift
  done
  if [ -z "$fmt" ]; then
    command stat ${deref:+"$deref"} ${files[@]+"${files[@]}"}
    return
  fi
  # BSD → GNU: modification time, size, permission bits, name.
  fmt="${fmt//%m/%Y}"; fmt="${fmt//%z/%s}"; fmt="${fmt//%Lp/%a}"; fmt="${fmt//%N/%n}"
  command stat ${deref:+"$deref"} -c "$fmt" ${files[@]+"${files[@]}"}
}

date() {
  local -a out=()
  local in_fmt="" a n unit
  while [ $# -gt 0 ]; do
    a="$1"
    case "$a" in
      -r)
        # BSD: seconds since the epoch. GNU: a reference file — which it still is when it exists.
        if [ -n "${2:-}" ] && [ ! -e "$2" ] && [ -z "${2//[0-9]/}" ]; then out+=(-d "@$2"); else out+=(-r "${2:-}"); fi
        shift ;;
      -v*)
        # -v-3H / -v+1d: an adjustment relative to now.
        a="${a#-v}"; n="${a%[A-Za-z]}"; unit="${a#"$n"}"
        case "$unit" in
          S) unit=seconds ;; M) unit=minutes ;; H) unit=hours ;; d) unit=days ;;
          w) unit=weeks ;; m) unit=months ;; y) unit=years ;;
        esac
        out+=(-d "$n $unit") ;;
      -j) ;;                                  # "do not set the clock": GNU never would
      -f) in_fmt="${2:-}"; shift ;;           # BSD's input format; GNU's -d parses on its own
      *)
        if [ -n "$in_fmt" ] && [ "${a#+}" = "$a" ]; then out+=(-d "$a"); in_fmt=""; else out+=("$a"); fi ;;
    esac
    shift
  done
  command date ${out[@]+"${out[@]}"}
}

mktemp() {
  # BSD `mktemp -t name` makes $TMPDIR/name.XXXXXXXX; GNU wants the X's spelled out.
  if [ "${1:-}" = "-t" ] && [ -n "${2:-}" ] && [ "${2%XXX*}" = "$2" ]; then
    command mktemp "${TMPDIR:-/tmp}/$2.XXXXXXXX"
    return
  fi
  if [ "${1:-}" = "-d" ] && [ "${2:-}" = "-t" ] && [ -n "${3:-}" ] && [ "${3%XXX*}" = "$3" ]; then
    command mktemp -d "${TMPDIR:-/tmp}/$3.XXXXXXXX"
    return
  fi
  command mktemp "$@"
}

find() {
  # BSD's `-depth N` is a test — "exactly N levels below the start". GNU's `-depth` is an option
  # that takes no number, so the walk died with "paths must precede expression" and every start in
  # a folder that was not yet a repository was refused as unreadable. The same test, spelled as a
  # path pattern: the start, then exactly N components.
  local -a in=("$@") out=()
  local root="" a i=0 esc
  for a in "$@"; do
    case "$a" in -P|-L|-H) ;; -*|'('|')'|'!') break ;; *) root="$a"; break ;; esac
  done
  while [ "$i" -lt "${#in[@]}" ]; do
    a="${in[$i]}"
    if [ "$a" = "-depth" ] && [ -n "$root" ] && [ -n "${in[$((i + 1))]:-}" ] && [ -z "${in[$((i + 1))]//[0-9]/}" ]; then
      esc="$(printf '%s' "${root%/}" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
      out+=(-regextype posix-extended -regex "${esc}(/[^/]+){${in[$((i + 1))]}}")
      i=$((i + 2)); continue
    fi
    out+=("$a"); i=$((i + 1))
  done
  command find ${out[@]+"${out[@]}"}
}

ps() {
  # `ps -ax` is BSD; procps answers it with a warning on some versions. The dashless form is both's.
  if [ "${1:-}" = "-ax" ]; then shift; command ps ax "$@"; return; fi
  command ps "$@"
}

if ! command -v shasum >/dev/null 2>&1; then
  shasum() {
    local algo=1
    if [ "${1:-}" = "-a" ]; then algo="${2:-1}"; shift 2; fi
    command "sha${algo}sum" "$@"
  }
fi

return 0 2>/dev/null || true
