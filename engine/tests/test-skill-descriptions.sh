#!/bin/bash
# Descriptions for skills, from the skill's own front matter.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_TRANSCRIPT_ROOT="$TMP/none"
P="$TMP/proj"

skill() { mkdir -p "$P/.claude/skills/$1"; printf -- '%s' "$2" > "$P/.claude/skills/$1/SKILL.md"; }
skill plain '---
name: plain
description: One clear sentence about what it does.
---
body
'
skill quoted '---
name: quoted
description: "Quoted, with: a colon inside."
---
'
skill block '---
name: block
version: 2.1.1
description: |
  First line of the description.
  Second line that continues it.
tags: [a, b]
---
'
skill folded '---
name: folded
description: >-
  A folded scalar
  across two lines.
---
'
skill none '---
name: none
---
'
skill nofm 'no front matter at all
'
inv() { python3 "$BIN/lib/skill-usage.py" "$P" --json --fast 2>/dev/null; }
d() { inv | jq -r "[.installed[] | select(.name == \"$1\")][0].description // \"ABSENT\""; }

echo "===== the ordinary shapes ====="
[ "$(d plain)" = "One clear sentence about what it does." ] && ok "a plain value" || bad "plain: $(d plain)"
[ "$(d quoted)" = "Quoted, with: a colon inside." ] && ok "a quoted value with a colon" || bad "quoted: $(d quoted)"

echo "===== block scalars, which real skills actually use ====="
# `humanizer` on this machine uses `description: |`. A naive split on ':' returns the bare pipe.
[ "$(d block)" = "First line of the description. Second line that continues it." ] \
  && ok "a literal block is folded into one paragraph" || bad "block: $(d block)"
case "$(d block)" in *"|"*) bad "the pipe leaked into the text" ;; *) ok "and the pipe never reaches the interface" ;; esac
[ "$(d folded)" = "A folded scalar across two lines." ] && ok "a folded block too" || bad "folded: $(d folded)"
case "$(d block)" in *tags*) bad "it swallowed the next key" ;; *) ok "it stops at the next key" ;; esac

echo "===== and where there is nothing to say ====="
[ "$(d none)" = "" ] && ok "a skill with no description gets none invented" || bad "none: $(d none)"
[ "$(d nofm)" = "" ] && ok "neither does one with no front matter" || bad "nofm: $(d nofm)"
inv | jq -e '[.installed[] | select(.name == "nofm")] | length == 1' >/dev/null 2>&1 \
  && ok "and it is still listed — a missing caption is not a missing skill" || bad "the skill vanished"

echo
if [ "$fails" -eq 0 ]; then echo "✅ descriptions are read, folded, and never invented"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
