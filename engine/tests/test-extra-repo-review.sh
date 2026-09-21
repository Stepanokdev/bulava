#!/bin/bash
# Work done in one of the product's OTHER repositories has to reach the review.
#
# A product is often several repositories, and the worker is handed every one of them. The gate
# measured one thing: the primary `cwd` against its base commit. So a night that did all of its
# work in a sibling repository — the ordinary case for a workspace of fifteen Open edX checkouts —
# read as "nothing changed", was nudged and then parked as a run with no outcome, and the code it
# had actually written was never reviewed and never reported. The feature would have looked finished
# and quietly not worked.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="extra-repo-run-id"

pass=0; fail=0
ok(){ printf '  \xe2\x9c\x85 %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \xe2\x9d\x8c %s\n' "$1"; fail=$((fail+1)); }

# A reviewer that writes down what it was actually shown, so the test can ask whether the sibling
# repository's work was in front of it rather than trusting an exit code.
FAKE="$(mktemp -d)"; PROMPT="$FAKE/prompt.txt"; CALLED="$FAKE/called"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "$CODEX_CALLED"
  printf '%s' "$*" > "$CODEX_PROMPT"
  echo "STATE: COMPLETE"; echo "VERDICT: PASS"
else
  echo "VERDICT: PASS"
fi
EOF
chmod +x "$FAKE/codex"
export CODEX_CALLED="$CALLED" CODEX_PROMPT="$PROMPT"
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"

DIRS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$CODEX_SESSIONS_DIR" "$FAKE" "$TR" ${DIRS[@]+"${DIRS[@]}"}; }
trap cleanup EXIT

newrepo(){   # $1=name → prints its path
  local d; d="$(mktemp -d)"; DIRS+=("$d")
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir -p src && echo base > "src/$1.txt" && git add -A && git commit -qm init >/dev/null )
  printf '%s\n' "$d"
}

mkcase(){
  PROJ="$(newrepo primary)"
  SIBLING="$(newrepo sibling)"
  # Untracked and already lying there when the run starts — only in the sibling, so the primary
  # stays genuinely clean and every case below is about the connected repository.
  echo "left here before the run" > "$SIBLING/src/scratch.txt"
  EXTRA_FILE="$(mktemp)"; DIRS+=("$EXTRA_FILE")
  printf '%s\n' "$SIBLING" > "$EXTRA_FILE"
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  SUPERVISOR_EXTRA_DIRS_FILE="$EXTRA_FILE" record_extra_repos "$IDIR"
  rm -f "$SUPERVISOR_STATE_DIR"/outcome-nudge-* 2>/dev/null || true
}

rungate(){   # $1=session id
  rm -f "$CALLED" "$PROMPT"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE"
}

echo "===== the connected repositories are written down when the run starts ====="
mkcase
if [ -s "$IDIR/extra-repos" ]; then ok "the sibling repository is on record for this run"
else no "nothing was recorded — the gate has no way to know it exists"; fi
if grep -q "$(canon_path "$SIBLING")" "$IDIR/extra-repos"; then ok "…by path, with its base state"
else no "the recorded line does not name the sibling"; fi

echo
echo "===== a change only in the sibling is not 'nothing changed' ====="
echo "worker wrote this" >> "$SIBLING/src/sibling.txt"
if extra_repos_changed "$IDIR" | grep -q "$(canon_path "$SIBLING")"; then
  ok "the change is seen"
else no "the sibling's change is invisible — the run would be parked as having done nothing"; fi
if extra_repos_diffstat "$IDIR" | grep -q "sibling.txt"; then
  ok "and it can be described, file by file"
else no "there is nothing to hand a reviewer"; fi

out="$(rungate s_extra_changed)"
if [ -f "$CALLED" ]; then ok "the review ran, with the primary folder untouched"
else no "the run was parked instead of reviewed — got: $(printf '%s' "$out" | head -c 200)"; fi
case "$out" in *"НЕ залишив ні змін коду"*) no "it still asked the worker for an outcome it had already earned" ;;
  *) ok "the worker was not nudged for a result it had already produced" ;; esac
if grep -q "sibling.txt" "$PROMPT" 2>/dev/null; then
  ok "the reviewer was shown what changed in the sibling repository"
else no "the reviewer got an empty diff for a night that wrote code"; fi
if grep -q "підключений репозиторій продукту" "$PROMPT" 2>/dev/null; then
  ok "…named as a connected repository, not mistaken for the primary"
else no "the sibling's diff is unlabelled"; fi

echo
echo "===== an untracked file that was already there, whose content the worker rewrote ====="
# The case a list of names cannot see. `src/scratch.txt` existed, untracked, before the run started,
# so it is in the recorded state already; only its TEXT changes. A digest built from filenames alone
# said nothing had happened, and a night that did its work in exactly that file would have been
# parked as having done nothing.
mkcase
echo "the worker rewrote this file" > "$SIBLING/src/scratch.txt"
if extra_repos_changed "$IDIR" | grep -q "$(canon_path "$SIBLING")"; then
  ok "rewriting an already-untracked file counts as work"
else no "the rewrite is invisible — only the filename was ever hashed"; fi

out="$(rungate s_untracked_rewritten)"
if [ -f "$CALLED" ]; then ok "and it reaches the review through the real gate"
else no "the gate parked a run that had rewritten a file — got: $(printf '%s' "$out" | head -c 200)"; fi
if grep -q "scratch.txt" "$PROMPT" 2>/dev/null; then
  ok "the reviewer is shown the file by name"
else no "the rewritten file never reached the reviewer"; fi

echo
echo "===== a connected repository that has no commits yet ====="
# `git rev-parse HEAD` fails in a repository with no commits AND prints the word HEAD on stdout, so
# a base read that way is the literal string. Everything built on it then lies quietly: `git diff
# HEAD` fails into nothing, staged content is invisible, and the moment the worker makes the first
# commit the base resolves to that commit, so the work compares to itself and reads as nothing. Each
# of those three is a way for a whole night to disappear, so each gets its own case.
mkunborn(){
  PROJ="$(newrepo primary)"
  SIBLING="$(mktemp -d)"; DIRS+=("$SIBLING")
  ( cd "$SIBLING" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir -p src && echo "staged, never committed" > src/pending.txt && git add src/pending.txt )
  EXTRA_FILE="$(mktemp)"; DIRS+=("$EXTRA_FILE")
  printf '%s\n' "$SIBLING" > "$EXTRA_FILE"
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  SUPERVISOR_EXTRA_DIRS_FILE="$EXTRA_FILE" record_extra_repos "$IDIR"
  rm -f "$SUPERVISOR_STATE_DIR"/outcome-nudge-* 2>/dev/null || true
}

mkunborn
if [ -s "$IDIR/extra-repos" ]; then ok "a repository with no commits is still recorded"
else no "a repository with no commits was skipped — its work could never be seen"; fi
case "$(cat "$IDIR/extra-repos")" in *HEAD*) no "the literal word HEAD was written down as the base" ;;
  *) ok "…against a base that is a real object, not the word HEAD" ;; esac

echo "the worker rewrote the staged file" > "$SIBLING/src/pending.txt"
if extra_repos_changed "$IDIR" | grep -q "$(canon_path "$SIBLING")"; then
  ok "rewriting an already-staged file counts as work"
else no "a staged file's new content is invisible"; fi
out="$(rungate s_unborn_staged)"
if [ -f "$CALLED" ]; then ok "…and it reaches the review through the real gate"
else no "the gate parked it — got: $(printf '%s' "$out" | head -c 200)"; fi
if grep -q "pending.txt" "$PROMPT" 2>/dev/null; then ok "the reviewer is shown the file by name"
else no "the staged file never reached the reviewer"; fi

mkunborn
( cd "$SIBLING" && git commit -qm "the worker's first commit" >/dev/null 2>&1 )
if extra_repos_changed "$IDIR" | grep -q "$(canon_path "$SIBLING")"; then
  ok "the first commit in the repository counts as work"
else no "the base moved with the commit, so the work compared to itself"; fi
out="$(rungate s_unborn_committed)"
if [ -f "$CALLED" ]; then ok "…and that reaches the review too"
else no "a night whose only work was a first commit was parked — got: $(printf '%s' "$out" | head -c 200)"; fi
if grep -q "pending.txt" "$PROMPT" 2>/dev/null; then ok "with the committed file named"
else no "the commit reached the reviewer as an empty diff"; fi

mkunborn
if extra_repos_changed "$IDIR" | grep -q .; then
  no "an untouched repository with no commits read as work"
else ok "and an untouched one is not work"; fi
out="$(rungate s_unborn_untouched)"
if [ -f "$CALLED" ]; then no "a run that changed nothing went to review"
else ok "…so the run is asked for its result instead"; fi

echo
echo "===== and a run that really changed nothing is still parked ====="
# The guard above must not turn into "always proceed". A repository the director left dirty before
# the run started is not the run's work either, and must not read as progress.
mkcase
echo "the director was here first" >> "$SIBLING/src/sibling.txt"
echo "and left this lying around too" > "$SIBLING/src/scratch.txt"
SUPERVISOR_EXTRA_DIRS_FILE="$EXTRA_FILE" record_extra_repos "$IDIR"     # started dirty, tracked and not
out="$(rungate s_nothing_changed)"
if [ -f "$CALLED" ]; then no "a run with no changes anywhere went to review"
else ok "nothing changed anywhere — the reviewer was not called"; fi
case "$out" in *"НЕ залишив ні змін коду"*|*"succeeded_changes"*) ok "the worker is asked for its result instead" ;;
  *) no "it neither reviewed nor asked — got: $(printf '%s' "$out" | head -c 200)" ;; esac

echo
[ "$fail" = 0 ] && echo "✅ extra repos: work in a connected repository reaches the review" \
                || echo "❌ extra repos: $fail problem(s)"
exit "$fail"
