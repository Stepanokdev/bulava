#!/bin/bash
# What night-shift-wsl.ps1 runs inside the distribution: `bash -l wsl-entry.sh <tool> <args…>`.
#
# A script file rather than `bash -c '…'`, because Windows PowerShell 5.1 does not escape double
# quotes inside an argument it hands to a native program, and `"$@"` would arrive broken. `-l`
# reads the login profile; claude and codex installed through nvm live in ~/.bashrc, which a
# non-interactive shell skips, so nvm is loaded here explicitly.
tool="${1:-night-shift}"; shift
case "$tool" in *[!a-z-]*|"") echo "night-shift: bad tool name" >&2; exit 2 ;; esac
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
for d in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.bun/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && PATH="$d:$PATH" ;; esac
done
export PATH
exec "$HOME/.local/bin/$tool" "$@"
