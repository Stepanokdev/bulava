#!/bin/bash
# Bulava keeps no memory of what its director decided, and quietly adds none to a prompt.
#
# It used to. A store under ~/.claude/supervisor/memory accumulated a cross-project "taste" file,
# per-module overlays, per-product decisions and machine-proposed candidates; a second half shipped
# in the repository as practice modules; and a router merged the two into the system prompt of every
# worker, every reviewer and every proxy answer. A situational request became a standing rule, rules
# aged, and two of them could contradict each other with nobody able to see which had won.
#
# What is pinned here is the whole property, not one entry point: with every one of those files
# present and readable on disk, none of their text reaches a prompt, nothing writes to them again,
# and the run's own working state is untouched by their absence.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
cleanup() { tmux_cleanup 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/tmux"
unset TMUX
# Bulava exports these into every process it starts; a test run from inside a chat would otherwise
# be measuring the surrounding session rather than the product.
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
tmux_isolate "$TMP/tmux"
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
# Resume is the "continue the work you already started" path, gated off by default while it is
# experimental. It is exactly the path this change must not damage, so it is turned on here.
export SUPERVISOR_ENABLE_RESUME=1
. "$BIN_DIR/supervisor-lib.sh"

# ---- a machine that HAS the old store, in full ------------------------------------------------
#
# Each marker is unique, so a hit names which half of the old design came back rather than only
# saying that something did.
MEM="$SUPERVISOR_STATE_DIR/memory"
mkdir -p "$MEM/modules" "$MEM/projects" "$MEM/candidates" "$MEM/archive"
printf '# taste\n\n## rule\nMARKER_GLOBAL_TASTE\n'        > "$MEM/_global.md"
printf '# overlay\n\n## rule\nMARKER_MODULE_OVERLAY\n'    > "$MEM/modules/ios-native.md"
printf '# product\n\n## rule\nMARKER_PRODUCT_DECISION\n'  > "$MEM/projects/project-000000000000.md"
printf '# waiting\n\n## rule\nMARKER_CANDIDATE\n'         > "$MEM/candidates/project-000000000000.md"
printf '# retired\n\n## rule\nMARKER_ARCHIVED\n'          > "$MEM/archive/retired.md"

PROJ="$TMP/project"; mkdir -p "$PROJ"
echo "hello" > "$PROJ/main.swift"        # Swift, so the old router would have matched ios-native
( cd "$PROJ" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )

markers="MARKER_GLOBAL_TASTE MARKER_MODULE_OVERLAY MARKER_PRODUCT_DECISION MARKER_CANDIDATE MARKER_ARCHIVED"

# What a prompt would have to say for the old design to be back, independent of our own markers:
# a fresh install has no markers at all and must still fail this if the router returns.
shapes="ЩО ДИРЕКТОР УЖЕ ВИРІШИВ ПРО ЦЕЙ ПРОДУКТ|ПАМʼЯТЬ І ПРАКТИКИ|----- module:|----- product:"

leaked() {  # $1=label, $2=file — reports every marker found, not just the first
  local label="$1" f="$2" m hit=0
  [ -s "$f" ] || { bad "$label: nothing was written at all ($f)"; return 1; }
  for m in $markers; do
    grep -q "$m" "$f" && { bad "$label still carries $m"; hit=1; }
  done
  grep -qE "$shapes" "$f" && { bad "$label still has the routed-memory block"; hit=1; }
  [ "$hit" = 0 ] && ok "$label carries none of the old memory"
  return 0
}

echo "===== the worker's system prompt, built by a real start ====="
# What the store looks like before anything runs, so "was it written to" is answered by content
# rather than by a timestamp comparison against one of its own files.
store_state() { find "$MEM" -type f -exec shasum {} \; 2>/dev/null | sed "s|$MEM||" | sort; }
BEFORE="$(store_state)"

out="$(cd "$PROJ" && SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$PROJ" --no-attach 2>&1)"
IDIR="$(instance_dir "$(slug_for "$PROJ")")"
if [ -d "$IDIR" ]; then
  leaked "the worker prompt" "$IDIR/standards.md"
else
  bad "the run did not start, so there is no prompt to read: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

# Removing memory must not have removed the operating contract the run depends on.
if [ -s "$IDIR/standards.md" ] && grep -q "report-outcome" "$IDIR/standards.md"; then
  ok "and it still carries the run protocol"
else
  bad "the run protocol went missing along with the memory"
fi

echo
echo "===== the run's own working state is untouched ====="
for f in project session run-id standards.md; do
  [ -s "$IDIR/$f" ] && ok "the run still records its $f" || bad "the run lost its $f"
done

echo
echo "===== a dispatch carries the task, and nothing the product 'remembers' ====="
# A stale file left by an older engine is the realistic case: the run directory outlives the
# version that wrote it, and a reader that still existed would treat it as current.
printf 'MARKER_PRODUCT_DECISION\n' > "$IDIR/product-memory.md"
bash "$BIN_DIR/dispatch.sh" "$PROJ" "зроби щось невелике" >/dev/null 2>&1 || true
if [ -e "$IDIR/product-memory.md" ]; then
  bad "a stale product-memory.md survived a dispatch, where something could still read it"
else
  ok "a stale product-memory.md is removed rather than left to be read"
fi
if grep -rl "product-memory" "$BIN_DIR" "$ROOT/hooks" 2>/dev/null | grep -qv "dispatch.sh"; then
  bad "something still reads product-memory.md: $(grep -rl 'product-memory' "$BIN_DIR" "$ROOT/hooks" | grep -v dispatch.sh | tr '\n' ' ')"
else
  ok "nothing reads product-memory.md any more"
fi

bash "$BIN_DIR/night-shift.sh" stop "$PROJ" >/dev/null 2>&1 || true
# `stop` deliberately leaves the tmux session behind so a human can read it. Resume is for the
# case where that session is gone — the machine slept, the terminal was closed — so it is killed
# here rather than left to make resume answer "no need".
tmux kill-session -t "$(session_name "$(slug_for "$PROJ")")" 2>/dev/null || true

echo
echo "===== and the same is true of a resumed run ====="
out="$(cd "$PROJ" && SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" resume "$PROJ" "11111111-2222-3333-4444-555555555555" 2>&1)"
if [ -s "$IDIR/standards.md" ]; then
  leaked "the resumed prompt" "$IDIR/standards.md"
  [ -s "$IDIR/run-id" ] && ok "the resumed run keeps its own state directory" \
                        || bad "resume produced no run state"
else
  bad "resume built no prompt: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi
bash "$BIN_DIR/night-shift.sh" stop "$PROJ" >/dev/null 2>&1 || true

echo
echo "===== nothing wrote to the store while all of that happened ====="
# Reading it would be a leak; writing to it would mean learning is still on. Both are checked,
# because the second is the one that creeps back in as "just recording a candidate".
n="$(find "$MEM" -type f | wc -l | tr -d ' ')"
[ "$n" = 5 ] && ok "the store has exactly the 5 files it started with" \
             || bad "the store now has $n file(s) — something wrote to it"
if [ "$(store_state)" = "$BEFORE" ]; then
  ok "and not one byte of them changed"
else
  bad "the store was rewritten:"
  diff <(printf '%s\n' "$BEFORE") <(store_state) | sed 's/^/       /'
fi

echo
echo "===== the machinery that built the memory is gone, not merely unused ====="
for f in bin/learn.sh bin/reflect.sh bin/memory.sh bin/route-lessons.py bin/lib/memory-store.py \
         supervisor/lessons claude-commands/learn.md; do
  [ -e "$ROOT/$f" ] && bad "$f is still here" || ok "$f is gone"
done
for fn in lessons_routed lessons_worker_context lessons_all memory_project_block memory_emit; do
  if grep -q "^$fn()" "$BIN_DIR/supervisor-lib.sh"; then
    bad "supervisor-lib.sh still defines $fn"
  else
    ok "supervisor-lib.sh no longer defines $fn"
  fi
done
# The stack detector is NOT memory: the verifier and the screenshot backend both ask it what kind
# of project this is, and removing it would break them in a way no prompt test would notice.
if grep -q "^detect_stacks()" "$BIN_DIR/supervisor-lib.sh"; then
  ok "detect_stacks is kept — it picks build commands, it routes no rules"
else
  bad "detect_stacks was removed; the verifier and capture have nothing to ask"
fi

echo
echo "===== the reviewer is a contract, not a profile of one person ====="
P="$ROOT/supervisor/SUPERVISOR.md"
if grep -qiE "distilled from|of his real answers|[0-9]+ of his|~?[0-9]+:[0-9]+ *\)?,? *(of the time)?.*overrid" "$P"; then
  bad "the reviewer persona is still a statistical profile of past answers"
else
  ok "the reviewer persona states no history of past decisions"
fi
grep -q "report-finding blocker" "$P" \
  && ok "and a real blocker is still reported the way the standards say" \
  || bad "the persona lost the blocker protocol"

echo
[ "$fails" = 0 ] && echo "✅ no learned memory reaches a prompt, and the work's own state survives" \
                 || echo "❌ $fails problem(s)"
exit "$fails"
