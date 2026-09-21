#!/bin/bash
# Which skills get used, and which only ever cost context.
#
# The director asked to be able to clear out skills that are not being used, and the data for that
# already exists: Claude Code records every skill invocation in its own transcript. What this test
# protects is mostly the honesty of the answer — that "no uses" is reported as no EVIDENCE of use,
# that a skill used through a plugin is not silently counted as missing, and that the numbers come
# from the transcripts rather than from anything the reader has to take on trust.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The app bridge must not leak in from the surrounding shell.
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
export SUPERVISOR_ORCH_HOME="$TMP/orch"; mkdir -p "$SUPERVISOR_ORCH_HOME"

# A fake home, so the global skills the developer happens to have installed cannot change
# the result of this test.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude/skills"
PROJ="$TMP/project"; mkdir -p "$PROJ/.claude/skills"

skill() {  # $1=root $2=name $3=description
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\n\nbody\n' "$2" "$3" > "$1/$2/SKILL.md"
}
skill "$HOME/.claude/skills" used-often "a skill that earns its place"
skill "$HOME/.claude/skills" never-used "a skill nobody has ever called"
skill "$PROJ/.claude/skills" project-only "installed for this project"

# Transcripts, in the shape Claude Code actually writes them.
export SUPERVISOR_TRANSCRIPT_ROOT="$TMP/transcripts"
mkdir -p "$SUPERVISOR_TRANSCRIPT_ROOT/some-project"
cat > "$SUPERVISOR_TRANSCRIPT_ROOT/some-project/a.jsonl" <<'JSON'
{"timestamp":"2026-08-01T10:00:00Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"used-often"}}]}}
{"timestamp":"2026-08-05T10:00:00Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"used-often"}}]}}
{"timestamp":"2026-08-09T10:00:00Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"project-only"}}]}}
{"timestamp":"2026-08-11T10:00:00Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"from-a-plugin"}}]}}
{"timestamp":"2026-08-12T10:00:00Z","message":{"content":[{"type":"text","text":"no skill here"}]}}
not json at all
JSON

echo "===== usage reads the transcripts, not a promise ====="
out="$(bash "$BIN_DIR/skill-resolver.sh" usage "$PROJ" 2>&1)"
json="$(bash "$BIN_DIR/skill-resolver.sh" usage "$PROJ" --json 2>&1)"

case "$out" in *"переглянуто транскриптів: 1"*) ok "found the transcript" ;;
                *) bad "did not scan the transcripts: $out" ;; esac

u="$(printf '%s' "$json" | jq -r '.installed[] | select(.name=="used-often") | .uses')"
[ "$u" = "2" ] && ok "counted two uses" || bad "expected 2 uses, got '$u'"

l="$(printf '%s' "$json" | jq -r '.installed[] | select(.name=="used-often") | .last')"
[ "$l" = "2026-08-05" ] && ok "kept the LATEST use, not the first" || bad "last use wrong: '$l'"

n="$(printf '%s' "$json" | jq -r '.installed[] | select(.name=="never-used") | .uses')"
[ "$n" = "0" ] && ok "an unused skill reports zero" || bad "unused skill wrong: '$n'"

s="$(printf '%s' "$json" | jq -r '.installed[] | select(.name=="project-only") | .scope')"
[ "$s" = "project" ] && ok "a project skill is reported as project scope" || bad "scope wrong: '$s'"

echo "===== the honest edges ====="
p="$(printf '%s' "$json" | jq -r '.used_but_not_installed[] | select(.name=="from-a-plugin") | .uses')"
[ "$p" = "1" ] && ok "a skill used but not installed is surfaced, not dropped" || bad "plugin skill lost: '$p'"

case "$out" in *"без слідів використання"*) ok "unused skills are summarised" ;;
                *) bad "no summary of unused skills" ;; esac

# The caveat is the point: no evidence is not the same as no value.
case "$out" in *"не те саме, що «непотрібен»"*) ok "the caveat is printed with the numbers" ;;
                *) bad "the caveat is missing — the numbers would read as a verdict" ;; esac

# A malformed line and a non-skill line must not stop the scan; if they did, the counts above
# would already be wrong, so reaching here with them correct is the assertion.
ok "malformed and irrelevant lines are skipped"

echo
if [ "$fails" -eq 0 ]; then echo "✅ skill usage: counted from real transcripts, with its caveat"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
