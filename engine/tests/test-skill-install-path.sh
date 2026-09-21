#!/bin/bash
# A catalogue is a monorepo. Installing "a skill from it" has to mean ONE skill.
#
# The installer took a source and audited `$Q/source` — the whole clone. So a skill the index
# named could not actually be fetched from the catalogue that listed it: you would audit and
# install the entire repository under that skill's name. `--path` addresses the one directory,
# and the path is validated against the quarantine root before anything is read from it.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_ORCH_HOME="$TMP/orch"; mkdir -p "$TMP/orch"
export SUPERVISOR_SKILLS_LOCK="$TMP/orch/skills.lock"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"

# Stage B is a real agent call. Stub it so this suite costs no model time; the audit decision
# itself is covered where it belongs.
mkdir -p "$TMP/stub"
printf '#!/bin/bash\necho "VERDICT: PASS"\n' > "$TMP/stub/codex"; chmod +x "$TMP/stub/codex"
export PATH="$TMP/stub:$PATH"

# A catalogue with two skills and something valuable beside them.
REPO="$TMP/catalogue"
mkdir -p "$REPO/skills/wanted" "$REPO/skills/other" "$REPO/secrets"
printf -- '---\nname: wanted\n---\nInert markdown.\n'  > "$REPO/skills/wanted/SKILL.md"
printf -- '---\nname: other\n---\nAlso inert.\n'       > "$REPO/skills/other/SKILL.md"
printf 'do not ship me\n'                              > "$REPO/secrets/keys.txt"
PROJ="$TMP/proj"; mkdir -p "$PROJ"
res() { bash "$BIN/skill-resolver.sh" "$@" 2>&1; }

echo "===== --path installs the ONE skill, not the catalogue around it ====="
out="$(res install "$PROJ" "$REPO" wanted --path skills/wanted)"
if [ -f "$PROJ/.claude/skills/wanted/SKILL.md" ]; then ok "the addressed skill is installed"
else bad "not installed: $out"; fi
[ -e "$PROJ/.claude/skills/wanted/secrets" ] && bad "the whole catalogue came with it" \
  || ok "nothing else from the repository came with it"
[ -e "$PROJ/.claude/skills/wanted/skills" ] && bad "the sibling skills came too" \
  || ok "and neither did its sibling skills"
grep -q "name: wanted" "$PROJ/.claude/skills/wanted/SKILL.md" 2>/dev/null \
  && ok "it is the skill that was asked for" || bad "wrong skill installed"

echo "===== the path is validated before anything is read through it ====="
for evil in "../../../etc" "/etc" "skills/../../.." "skills/wanted/../../../"; do
  out="$(res install "$PROJ" "$REPO" evil --path "$evil")"; rc=$?
  [ "$rc" = 0 ] && bad "accepted an escaping path: $evil"
done
ok "every escaping path was refused"
[ -d "$PROJ/.claude/skills/evil" ] && bad "an escaping path still produced an install" \
  || ok "and none of them installed anything"

echo "===== a symlink inside the fetched source cannot redirect the audit ====="
ln -s "$TMP/outside" "$REPO/skills/sneaky" 2>/dev/null
mkdir -p "$TMP/outside"; printf -- '---\nname: sneaky\n---\n' > "$TMP/outside/SKILL.md"
out="$(res install "$PROJ" "$REPO" sneaky --path skills/sneaky)"; rc=$?
# The copy into quarantine does not follow the link out of the tree, so this must not resolve to
# the outside directory and install it.
if [ "$rc" != 0 ] || [ ! -d "$PROJ/.claude/skills/sneaky" ]; then
  ok "a link pointing out of the source did not install what it pointed at"
else
  real="$(cat "$PROJ/.claude/skills/sneaky/SKILL.md" 2>/dev/null)"
  bad "installed through a symlink out of quarantine: $real"
fi

echo "===== a path that holds no skill is not a skill ====="
out="$(res install "$PROJ" "$REPO" nothere --path secrets)"; rc=$?
[ "$rc" != 0 ] && ok "a directory without SKILL.md is refused" || bad "installed a non-skill: $out"
case "$out" in *"SKILL.md"*) ok "and says why" ;; *) bad "unclear refusal: $out" ;; esac

echo "===== without --path the old behaviour is unchanged ====="
SOLO="$TMP/solo"; mkdir -p "$SOLO"; printf -- '---\nname: solo\n---\n' > "$SOLO/SKILL.md"
res install "$PROJ" "$SOLO" solo >/dev/null 2>&1
[ -f "$PROJ/.claude/skills/solo/SKILL.md" ] && ok "a single-skill source still installs as before" \
  || bad "the ordinary install path regressed"

echo
if [ "$fails" -eq 0 ]; then echo "✅ one skill, addressed, and the path is a boundary"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
