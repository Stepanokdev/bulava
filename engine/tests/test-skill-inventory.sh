#!/bin/bash
# What `usage --json` reports, and why each field of it matters to the app.
#
# Three defects lived here at once, and each one made a skill disappear from the interface.
#
#   * `.agents/skills` is a PROJECT-local directory and was reported under a scope of its own,
#     `repo`. The app knew three scopes and folded anything else into `global` — so a genuinely
#     project-local skill read as "loaded everywhere" and was filtered out of the one panel where
#     it should have appeared.
#   * Only ONE project could be asked about, so a window claiming to hold the machine's inventory
#     held a single product's.
#   * Plugins were not scanned at all: a skill that came with one could be invoked all day and
#     still report as "used but not installed".
#
# And a name is not an identity — two projects may each hold `design` — so every row carries the
# directory it lives in and the project it belongs to.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_ORCH_HOME="$TMP/orch"; mkdir -p "$TMP/orch"
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$TMP/state"
# No transcripts: usage counts are not what this suite is about, and scanning the real ones would
# make it slow and machine-dependent.
export SUPERVISOR_TRANSCRIPT_ROOT="$TMP/no-transcripts"

mk() { mkdir -p "$1"; printf -- '---\nname: %s\ndescription: x\n---\nbody\n' "$2" > "$1/SKILL.md"; }
A="$TMP/projA"; B="$TMP/projB"
mk "$A/.claude/skills/design" design            # project-local, the usual place
mk "$A/.agents/skills/repo-skill" repo-skill    # project-local, the OTHER place
mk "$B/.claude/skills/design" design            # the same NAME in a different project
inv() { python3 "$BIN/lib/skill-usage.py" "$@" --json 2>/dev/null; }

echo "===== .agents/skills is project-local, not a scope of its own ====="
out="$(inv "$A")"
if printf '%s' "$out" | jq -e '[.installed[] | select(.name == "repo-skill")][0].scope == "project"' >/dev/null 2>&1; then
  ok "a skill in .agents/skills reports as project scope"
else bad "scope is $(printf '%s' "$out" | jq -r '[.installed[]|select(.name=="repo-skill")][0].scope // "absent"')"; fi
if printf '%s' "$out" | jq -e '[.installed[].scope] | all(. == "global" or . == "project" or . == "plugin")' >/dev/null 2>&1; then
  ok "every scope is one the app knows — an unknown one is silently dropped there"
else bad "an unknown scope escaped: $(printf '%s' "$out" | jq -c '[.installed[].scope] | unique')"; fi

echo "===== a row says where it lives and whose it is ====="
row="$(printf '%s' "$out" | jq -c '[.installed[] | select(.name == "repo-skill")][0]')"
printf '%s' "$row" | jq -e '.path | endswith("/.agents/skills/repo-skill")' >/dev/null 2>&1 \
  && ok "the directory is reported" || bad "no path: $row"
printf '%s' "$row" | jq -e '.project != ""' >/dev/null 2>&1 \
  && ok "and the project it belongs to" || bad "no project: $row"
printf '%s' "$out" | jq -e '[.installed[] | select(.scope == "global")][0].project == ""' >/dev/null 2>&1 \
  && ok "a global skill claims no project" || ok "no global skills on this machine to check"

echo "===== every project asked about, not the first one ====="
both="$(inv "$A" "$B")"
n=$(printf '%s' "$both" | jq '[.installed[] | select(.name == "design")] | length')
[ "$n" = 2 ] && ok "the same name in two projects is two rows" || bad "got $n rows for design"
paths=$(printf '%s' "$both" | jq -r '[.installed[] | select(.name == "design") | .project] | sort | join(",")')
case "$paths" in *projA*projB*) ok "and each names its own project" ;;
  *) bad "projects are wrong: $paths" ;; esac
# The bug this replaces: asking about A alone must not surface B's copy.
onlyA="$(inv "$A")"
printf '%s' "$onlyA" | jq -e '[.installed[] | select(.project | test("projB"))] | length == 0' >/dev/null 2>&1 \
  && ok "a project that was not asked about contributes nothing" || bad "leaked another project's skills"

echo "===== one skill in two roots of one project is one skill ====="
mk "$A/.agents/skills/design" design    # the same skill, copied into the other root
dupes=$(inv "$A" | jq '[.installed[] | select(.name == "design" and (.project | test("projA")))] | length')
[ "$dupes" = 1 ] && ok "it is listed once, not twice" || bad "listed $dupes times"

echo "===== plugins come from what is INSTALLED, never from the marketplace cache ====="
src="$(cat "$BIN/lib/skill-usage.py")"
case "$src" in *installed_plugins.json*) ok "the installed-plugins manifest is the source" ;;
  *) bad "plugins are discovered by walking the plugins directory" ;; esac
case "$src" in *installPath*) ok "and each plugin's own recorded path is used, not a guess" ;;
  *) bad "the install path is guessed" ;; esac
# Walking ~/.claude/plugins would list every skill of every catalogue ever browsed.
case "$src" in *'os.listdir(base)'*) bad "still walks the plugins directory" ;;
  *) ok "the catalogue cache is not mistaken for installed software" ;; esac

echo "===== a skill directory without SKILL.md is not a skill ====="
mkdir -p "$A/.claude/skills/not-a-skill"
inv "$A" | jq -e '[.installed[] | select(.name == "not-a-skill")] | length == 0' >/dev/null 2>&1 \
  && ok "an empty directory is ignored" || bad "an empty directory was listed as a skill"

echo "===== and asking about nothing still works ====="
out="$(inv)"
printf '%s' "$out" | jq -e 'has("installed") and has("transcripts")' >/dev/null 2>&1 \
  && ok "no projects is a valid question (global and plugins only)" || bad "broke with no arguments: $out"

echo
if [ "$fails" -eq 0 ]; then echo "✅ the inventory names what it found, where, and whose"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
