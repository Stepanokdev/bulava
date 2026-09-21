#!/bin/bash
# The system searches its own history, so the director does not have to remember.
#
# «An index of transcripts and a search — so the system looks through its own history, not me.»
#
# The roadmap asked for an INDEX. The corpus said otherwise: 1.3 GB of transcripts, crossed by a
# byte scan in about four seconds. An index would be a second copy of the truth that goes stale,
# maintained to save a wait nobody experiences — so there is none, and this tests the search.
#
# The hard-won part is not the scanning. It is that a match must be something SAID: most of the
# corpus is tool calls and their results, and a search that returns those returns noise.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_TRANSCRIPT_ROOT="$TMP/projects"
mkdir -p "$SUPERVISOR_TRANSCRIPT_ROOT/-Users-me-Developer-Night-Shift"

python3 - "$SUPERVISOR_TRANSCRIPT_ROOT/-Users-me-Developer-Night-Shift/s1.jsonl" <<'PY'
import json, sys
rows = [
  {"type": "user", "timestamp": "2026-08-20T10:00:00Z", "sessionId": "sess-1",
   "cwd": "/Users/me/Developer/Night Shift",
   "message": {"role": "user", "content": [{"type": "text",
     "text": "Ключі RevenueCat беремо з Keychain, ніколи з репозиторію."}]}},
  {"type": "assistant", "timestamp": "2026-08-20T10:01:00Z", "sessionId": "sess-1",
   "cwd": "/Users/me/Developer/Night Shift",
   "message": {"role": "assistant", "content": [{"type": "text",
     "text": "Зрозумів: RevenueCat читається з Keychain."}]}},
  # The same word inside a TOOL call and a TOOL result: the bulk of a real corpus, and noise here.
  {"type": "assistant", "timestamp": "2026-08-21T10:00:00Z", "sessionId": "sess-1",
   "cwd": "/Users/me/Developer/Night Shift",
   "message": {"role": "assistant", "content": [
     {"type": "tool_use", "name": "Bash", "input": {"command": "grep -r RevenueCat ."}}]}},
  {"type": "user", "timestamp": "2026-08-21T10:00:05Z", "sessionId": "sess-1",
   "cwd": "/Users/me/Developer/Night Shift",
   "message": {"role": "user", "content": [
     {"type": "tool_result", "content": "RevenueCat.swift:1: import RevenueCat"}]}},
]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY

# A second project, to prove scoping works.
mkdir -p "$SUPERVISOR_TRANSCRIPT_ROOT/-Users-me-Developer-Other"
python3 - "$SUPERVISOR_TRANSCRIPT_ROOT/-Users-me-Developer-Other/s2.jsonl" <<'PY'
import json, sys
rows = [{"type": "user", "timestamp": "2026-08-22T10:00:00Z", "sessionId": "sess-2",
         "cwd": "/Users/me/Developer/Other",
         "message": {"role": "user", "content": [{"type": "text",
           "text": "У цьому проєкті RevenueCat не використовуємо взагалі."}]}}]
open(sys.argv[1], "w").write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n")
PY

h() { bash "$BIN/history.sh" "$@" 2>&1; }

echo "===== it finds what was SAID, and not what was merely executed ====="
out="$(h RevenueCat --all --json)"
n=$(printf '%s' "$out" | jq '.hits | length')
[ "$n" = 3 ] && ok "three things were said about it" || bad "got $n hits"
printf '%s' "$out" | jq -e '[.hits[].text] | map(select(test("grep -r"))) | length == 0' >/dev/null 2>&1 \
  && ok "a tool call that mentions it is not a hit" || bad "a tool call came back as a hit"
printf '%s' "$out" | jq -e '[.hits[].text] | map(select(test("import RevenueCat"))) | length == 0' >/dev/null 2>&1 \
  && ok "neither is a tool result" || bad "a tool result came back as a hit"

echo "===== every hit is placeable ====="
printf '%s' "$out" | jq -e '.hits[0] | .date != "" and .project != "" and .session != ""' >/dev/null 2>&1 \
  && ok "day, project and session are all there" || bad "a hit cannot be placed: $(printf '%s' "$out" | jq -c '.hits[0]')"
# The project comes from the record's own cwd — a folder name like
# `-Users-me-Developer-Night-Shift` cannot be reversed, and guessing gives "Shift".
printf '%s' "$out" | jq -e '[.hits[].project] | index("Night Shift")' >/dev/null 2>&1 \
  && ok "and the project name is the real one, not a guess from the folder" \
  || bad "project names: $(printf '%s' "$out" | jq -c '[.hits[].project]')"
printf '%s' "$out" | jq -e '.hits[0].date >= .hits[-1].date' >/dev/null 2>&1 \
  && ok "newest first" || bad "not ordered by date"

echo "===== who said it ====="
printf '%s' "$(h RevenueCat --all --who=user --json)" | jq -e '[.hits[].who] | unique == ["user"]' >/dev/null 2>&1 \
  && ok "the director's own words can be asked for alone" || bad "--who=user did not filter"
printf '%s' "$(h RevenueCat --all --who=assistant --json)" | jq -e '[.hits[].who] | unique == ["assistant"]' >/dev/null 2>&1 \
  && ok "and Claude's" || bad "--who=assistant did not filter"

echo "===== one project at a time ====="
scoped="$(h RevenueCat --all --project=/Users/me/Developer/Other --json)"
printf '%s' "$scoped" | jq -e '[.hits[].project] | unique == ["Other"]' >/dev/null 2>&1 \
  && ok "a scoped search stays in its project" || bad "leaked: $(printf '%s' "$scoped" | jq -c '[.hits[].project]')"

echo "===== the window is a stated fact, never a silent limit ====="
old="$SUPERVISOR_TRANSCRIPT_ROOT/-Users-me-Developer-Night-Shift/old.jsonl"
python3 - "$old" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
  "type": "user", "timestamp": "2024-01-01T10:00:00Z", "sessionId": "ancient",
  "cwd": "/Users/me/Developer/Night Shift",
  "message": {"role": "user", "content": [{"type": "text", "text": "RevenueCat дуже давно."}]}},
  ensure_ascii=False) + "\n")
PY
touch -t 202401010000 "$old"
printf '%s' "$(h RevenueCat --json)" | jq -e '[.hits[].text] | map(select(test("дуже давно"))) | length == 0' >/dev/null 2>&1 \
  && ok "the default window excludes an ancient session" || bad "the window did not apply"
case "$(h RevenueCat)" in *"за останні"*) ok "and the answer says which window it used" ;;
  *) bad "the window is silent" ;; esac
printf '%s' "$(h RevenueCat --all --json)" | jq -e '[.hits[].text] | map(select(test("дуже давно"))) | length == 1' >/dev/null 2>&1 \
  && ok "--all reaches it" || bad "--all did not widen the search"
case "$(h "не існує такого рядка ніде")" in *"--all"*) ok "and an empty result points at it" ;;
  *) bad "an empty result does not mention --all" ;; esac

echo "===== options are actually read ====="
# `--who=user` was parsed as the flag `--who`, so every option was silently ignored.
printf '%s' "$(h RevenueCat --all --limit=1 --json)" | jq -e '.hits | length == 1' >/dev/null 2>&1 \
  && ok "--limit is honoured" || bad "--limit ignored"

echo "===== it depends on nothing that might not be there ====="
src="$(cat "$BIN/lib/history.py")"
case "$src" in *'"rg"'*) bad "it shells out to rg, which is a shell FUNCTION inside Claude Code" ;;
  *) ok "it does not depend on rg" ;; esac
case "$src" in *'"grep"'*) bad "it shells out to grep — /usr/bin/grep takes eleven seconds here" ;;
  *) ok "nor on the system grep" ;; esac
case "$src" in *"mmap"*) ok "it scans the bytes itself" ;; *) bad "no self-contained scan" ;; esac

echo "===== and the worker is given it ====="
case "$(cat "$BIN/night-shift.sh")" in *'"$IDIR/history"'*) ok "installed into every run's folder" ;;
  *) bad "a worker has no way to call it" ;; esac
case "$(cat "$(dirname "$BIN")/supervisor/STANDARDS.md")" in
  *'$IDIR/history'*) ok "and told when to use it" ;;
  *) bad "nothing tells a worker it exists" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "✅ the machine can search its own history"; else echo "❌ $fails problem(s)"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
