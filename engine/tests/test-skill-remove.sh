#!/bin/bash
# Deleting a skill is the engine's job, and it is the one that has to be paranoid.
#
# «Being able to remove and update them quickly.» The button is in the app; the deleting is here,
# because skill state belongs to the engine — it owns the lock, the name sanitising and the audit.
# A UI reaching into `.claude/skills` with its own `rm -rf` is how a name like `../../src` becomes
# a deleted source tree.
#
# An update is not a lighter operation than an install: it is new code from the internet, and
# having been trusted once earns it no shortcut past the audit.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_ORCH_HOME="$TMP/orch"; mkdir -p "$TMP/orch"
export SUPERVISOR_SKILLS_LOCK="$TMP/orch/skills.lock"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"
PROJ="$TMP/proj"
mk() { mkdir -p "$PROJ/.claude/skills/$1"; printf -- '---\nname: %s\n---\nbody\n' "$1" > "$PROJ/.claude/skills/$1/SKILL.md"; }
res() { bash "$BIN/skill-resolver.sh" "$@" 2>&1; }

mk demo-skill
printf '%s\n' '{"version":1,"skills":[{"name":"demo-skill","source_url":"https://example.invalid/x","scope":"project"}]}' > "$SUPERVISOR_SKILLS_LOCK"
# Something valuable next to the skills root, to prove a traversal would have had a target.
mkdir -p "$PROJ/src"; printf 'keep me\n' > "$PROJ/src/important.txt"

echo "===== removing a skill removes it, and forgets it in the lock ====="
out="$(res remove "$PROJ" demo-skill)"
[ -d "$PROJ/.claude/skills/demo-skill" ] && bad "the directory is still there" || ok "the skill is gone from disk"
if jq -e '[.skills[]?] | length == 0' "$SUPERVISOR_SKILLS_LOCK" >/dev/null 2>&1; then
  ok "and gone from the lock — a pinned hash for a deleted skill is a lie"
else bad "still pinned: $(jq -c '.skills' "$SUPERVISOR_SKILLS_LOCK")"; fi

echo "===== a name that tries to escape deletes nothing ====="
for evil in "../../src" "../src" ".." "a/b"; do
  out="$(res remove "$PROJ" "$evil")"; rc=$?
  [ "$rc" = 0 ] && bad "accepted a traversal name: $evil"
done
[ -f "$PROJ/src/important.txt" ] && ok "the source tree beside the skills root is untouched" \
  || bad "a traversal name deleted outside the skills root"
ok "every traversal name was refused"

echo "===== a skill that is not there is not an error the app can mistake for success ====="
out="$(res remove "$PROJ" never-installed)"; rc=$?
[ "$rc" != 0 ] && ok "removing a missing skill fails" || bad "reported success for a missing skill: $out"

echo "===== an update needs a recorded source, and never invents one ====="
mk hand-placed
out="$(res update "$PROJ" hand-placed)"; rc=$?
[ "$rc" != 0 ] && ok "a hand-placed skill cannot be updated" || bad "updated a skill with no source: $out"
case "$out" in *"джерела"*) ok "and says why" ;; *) bad "unclear failure: $out" ;; esac
[ -f "$PROJ/.claude/skills/hand-placed/SKILL.md" ] && ok "a failed update leaves the skill alone" \
  || bad "a failed update destroyed the installed skill"

echo "===== and an update is routed through the audit, not around it ====="
src="$(cat "$BIN/skill-resolver.sh")"
case "$src" in *'exec "$0" install "$PROJ" "$src" "$NAME"'*)
  ok "update re-enters the install pipeline (fetch → quarantine → audit)" ;;
  *) bad "update has its own install path — that would skip the audit" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ removing and updating stay inside the engine's guards"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
