#!/bin/bash
# A start never commits the director's uncommitted work unasked.
#
# It used to: a dirty folder got `git add -A` and a commit as `night-shift <night-shift@local>`,
# «Checkpoint before night shift», in whatever branch the director was on — and a fix Claude Code had
# just made in another window reached the remote under a name that described nothing. Now a dirty
# folder is a question (exit 77) with three answers: leave the changes where they are, commit them
# as the director, or let the director sort them out. Every scenario below checks the same thing
# before and after: HEAD, the staged diff, the unstaged diff, the untracked files and every ref.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_COMMIT_MESSAGE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
# The director's identity lives in the repository's own config below; nothing from this machine's
# global git config may stand in for it, or «no identity» could never be tested.
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

NS="$BIN_DIR/night-shift.sh"
. "$BIN_DIR/supervisor-lib.sh"

# A repository with one commit, then the shape of the evening in the bug report and worse: an
# unstaged edit, a partly staged file (`add -p`), a staged deletion, an untracked file, an untracked
# file with a Cyrillic name and a space, and a nested repository that has no commits.
make_repo() {   # $1=dir
  local d="$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q -b main
    git config user.name "Ihor Director"; git config user.email "ihor@example.com"
    printf 'one\ntwo\nthree\n' > a.txt; echo b > b.txt; echo c > c.txt
    git add . && git commit -qm "base"
    echo "their fix" >> a.txt                       # unstaged
    printf 'one\nTWO\nthree\n' > b.txt; git add b.txt; echo "unstaged tail" >> b.txt   # partial staging
    git rm -q c.txt                                  # staged deletion
    echo "draft" > notes.md                          # untracked
    mkdir -p docs; echo "чернетка" > "docs/Нотатка з пробілом.md"
    mkdir -p inner && ( cd inner && git init -q ) )
}
fingerprint() {   # $1=dir → HEAD, staged, unstaged, untracked names+content, all refs
  local d="$1"
  { git -C "$d" rev-parse HEAD 2>/dev/null || echo unborn
    git -C "$d" diff --cached --binary
    echo "--"; git -C "$d" diff --binary
    echo "--"; git -C "$d" ls-files --others --exclude-standard -z | tr '\0' '\n'
    git -C "$d" ls-files --others --exclude-standard -z | ( cd "$d" && xargs -0 cat 2>/dev/null )
    echo "--"; git -C "$d" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags
  } | shasum | cut -c1-40
}
nightshift_authored() {   # $1=dir → commits by the engine on any branch
  git -C "$1" log --branches --format='%ae' | grep -c 'night-shift@local'
}
stop() { bash "$NS" stop "$1" >/dev/null 2>&1 || true; }

echo "===== no answer: it asks, and changes nothing ====="
P="$TMP/ask"; make_repo "$P"
before="$(fingerprint "$P")"; commits="$(git -C "$P" rev-list --all | wc -l | tr -d ' ')"
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 77 ] && ok "exit 77 — a question, not a failure" || bad "exit $rc, expected 77: $out"
[ "$(fingerprint "$P")" = "$before" ] && ok "HEAD, index, files and branches are exactly as they were" \
  || bad "the start changed the folder"
[ "$(git -C "$P" rev-list --all | wc -l | tr -d ' ')" = "$commits" ] && ok "no commit anywhere" || bad "a commit appeared"
case "$out" in *"a.txt"*"notes.md"*) ok "it names the files" ;; *) bad "the files are not listed: $out" ;; esac
case "$out" in *"--dirty=keep"*"--dirty=commit"*) ok "and says how to answer from a terminal" ;; *) bad "no answers offered" ;; esac
[ ! -d "$SUPERVISOR_STATE_DIR/instances/$(slug_for "$(canon_path "$P")")" ] && ok "no run was left behind" || bad "an instance was created"
grep -q "REFUSED $(canon_path "$P")" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the log says why" || bad "nothing in the log"

echo "===== an app older than its engine is told so in words, not handed terminal flags ====="
out="$(SUPERVISOR_RUN_ENV_FROM_APP=1 SUPERVISOR_CHAT_CONTEXT_FILE=/dev/null bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 77 ] && ok "still the same question (77)" || bad "exit $rc"
case "$out" in *"--dirty"*) bad "an app with no buttons for this got terminal flags: $out" ;; *) ok "no terminal flags for an app" ;; esac
case "$out" in *"старіша за свій рушій"*"Нічого не закомічено"*) ok "it says the copy is out of date and nothing was committed" ;; *) bad "no plain explanation: $out" ;; esac
case "$out" in *"a.txt"*) ok "and still lists the files" ;; *) bad "files missing" ;; esac
out="$(SUPERVISOR_RUN_ENV_FROM_APP=1 SUPERVISOR_APP_ANSWERS="dirty mcp" bash "$NS" start "$P" --no-attach 2>&1)"
case "$out" in *"старіша за свій рушій"*) bad "an app that answers with buttons was called out of date" ;; *) ok "an app that has the buttons is not told it is old" ;; esac
# The app shows its own card, but the text can still reach the director another way — and a
# screenshot of a chat once showed exactly these flags in red. Words, never a terminal's commands.
case "$out" in *"--dirty"*|*"night-shift start"*) bad "an app with the buttons was handed terminal flags: $out" ;;
  *) ok "an app with the buttons gets no terminal flags either" ;; esac
[ "$(fingerprint "$P")" = "$before" ] && ok "and none of it touched the folder" || bad "the folder changed"

echo "===== dirty-state: what the app reads ====="
js="$(bash "$NS" dirty-state "$P")"
[ "$(printf '%s' "$js" | jq -r .dirty)" = true ] && ok "dirty" || bad "not reported dirty: $js"
[ "$(printf '%s' "$js" | jq -r .author)" = "Ihor Director <ihor@example.com>" ] && ok "the author is the director's own identity" || bad "author: $js"
[ "$(printf '%s' "$js" | jq -r '.files | map(.path) | index("docs/") != null')" = true ] && ok "untracked folders are listed as folders" || bad "files: $js"
[ "$(printf '%s' "$js" | jq -r .digest)" = "$(dirty_digest "$(canon_path "$P")")" ] && ok "the digest is the one a start checks" || bad "digest mismatch"
[ "$(fingerprint "$P")" = "$before" ] && ok "reading it touched nothing" || bad "dirty-state changed the folder"

echo "===== keep: start, leave the changes exactly where they are ====="
P="$TMP/keep"; make_repo "$P"
before="$(fingerprint "$P")"; head0="$(git -C "$P" rev-parse HEAD)"
idx0="$(git -C "$P" diff --cached | shasum)"
out="$(bash "$NS" start "$P" --no-attach --dirty=keep 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the run started" || bad "start failed ($rc): $out"
IDIR="$SUPERVISOR_STATE_DIR/instances/$(slug_for "$(canon_path "$P")")"
[ "$(fingerprint "$P")" = "$before" ] && ok "HEAD, index, files and branches are exactly as they were" || bad "keep changed the folder"
[ "$(git -C "$P" diff --cached | shasum)" = "$idx0" ] && ok "the partly staged file is still partly staged" || bad "the index moved"
[ "$(nightshift_authored "$P")" = 0 ] && ok "no night-shift commit on any branch" || bad "night-shift authored a commit"
rid="$(cat "$IDIR/run-id" 2>/dev/null)"; ref="refs/night-shift/$rid"
snap="$(git -C "$P" rev-parse --verify -q "$ref")"
[ -n "$snap" ] && ok "a snapshot is kept under $ref" || bad "no snapshot ref"
[ "$(cat "$IDIR/base-sha" 2>/dev/null)" = "$snap" ] && ok "and the run is measured against it" || bad "base-sha is not the snapshot"
[ -z "$(git -C "$P" branch --contains "$snap" 2>/dev/null)" ] && ok "the snapshot is on no branch" || bad "the snapshot is on a branch"
[ -z "$(git -C "$P" diff "$snap" --name-only)" ] && [ -z "$(worker_untracked "$P" "$IDIR")" ] \
  && ok "before the worker does anything, the run has changed nothing" || bad "the director's work counts as the run's: $(git -C "$P" diff "$snap" --name-only) $(worker_untracked "$P" "$IDIR")"
grep -q "notes.md" "$IDIR/standards.md" && grep -q "not yours" "$IDIR/standards.md" \
  && ok "the worker is told which files are not its own" || bad "the worker is not told"
# The worker works: edits one of the director's files, adds a file, rewrites an untracked draft.
echo "worker line" >> "$P/b.txt"; echo "new" > "$P/worker.txt"; echo "rewritten" > "$P/notes.md"
changed="$( { git -C "$P" diff "$snap" --name-only; worker_untracked "$P" "$IDIR"; } | sort -u | tr '\n' ' ')"
[ "$changed" = "b.txt notes.md worker.txt " ] && ok "the review sees the worker's three changes and nothing else" \
  || bad "the review's list is wrong: [$changed]"
git -C "$P" diff "$snap" -- b.txt | grep -q '^+worker line' && ! git -C "$P" diff "$snap" -- b.txt | grep -qE '^[-+](TWO|two|unstaged tail)' \
  && ok "and inside b.txt only the worker's own line" || bad "the director's edit in b.txt counts as the worker's"
stop "$P"
# The way back: from a clean HEAD, the snapshot brings back all of it, the staged split included.
( cd "$P" && git reset -q --hard && git clean -fdq -e inner ) >/dev/null 2>&1
git -C "$P" stash apply --index "$ref" >/dev/null 2>&1 \
  && [ "$(fingerprint "$P")" = "$before" ] && ok "git stash apply --index restores exactly what was there" \
  || bad "the snapshot does not restore the folder"

echo "===== keep, in a scoped run: the scope gate must not touch the director's files ====="
P="$TMP/scope"; make_repo "$P"
bash "$NS" start "$P" --no-attach --dirty=keep >/dev/null 2>&1 || bad "start failed"
IDIR="$SUPERVISOR_STATE_DIR/instances/$(slug_for "$(canon_path "$P")")"
printf '%s\n' '{"schema":1,"mode":"scoped","write_paths":["worker/**"]}' > "$IDIR/runspec.json"
snap="$(cat "$IDIR/base-sha")"
mkdir -p "$P/worker"; echo "in scope" > "$P/worker/ok.txt"
echo "out of scope" > "$P/stray.txt"; echo "worker scribble" >> "$P/notes.md"; echo "worker edit" >> "$P/a.txt"
bash "$BIN_DIR/scope-gate.sh" "$P" "$IDIR" "$snap" >/dev/null 2>&1
[ -f "$P/worker/ok.txt" ] && ok "the in-scope file stays" || bad "the in-scope file was removed"
[ ! -e "$P/stray.txt" ] && ok "the worker's out-of-scope file is quarantined" || bad "stray.txt survived"
[ "$(cat "$P/notes.md")" = "draft" ] && ok "the director's untracked draft is put back as it was, not deleted" || bad "notes.md: $(cat "$P/notes.md" 2>&1)"
[ -f "$P/docs/Нотатка з пробілом.md" ] && ok "their other untracked files are untouched" || bad "an untracked file of theirs was deleted"
tail -1 "$P/a.txt" | grep -q "their fix" && ok "a.txt is back to THEIR version, not to HEAD" || bad "a.txt: $(cat "$P/a.txt")"
git -C "$P" diff --cached --name-only | grep -qx b.txt && ok "and their staged split is intact" || bad "the index lost their staged change"
[ "$(git -C "$P" log --format=%s -1)" = "base" ] && ok "no revert commit carries their work into history" || bad "scope-gate committed: $(git -C "$P" log --format=%s -1)"
stop "$P"

echo "===== resumed later, the chat is still measured against the snapshot ====="
# `resume` launches the real CLI by name, so a stand-in `claude` that only writes down its arguments.
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/resume-args"\nsleep 30\n' "$TMP" > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
P="$TMP/resume"; make_repo "$P"; P="$(canon_path "$P")"
SLUG="$(slug_for "$P")"; IDIR="$SUPERVISOR_STATE_DIR/instances/$SLUG"
bash "$NS" start "$P" --no-attach --dirty=keep >/dev/null 2>&1 || bad "start failed"
snap="$(cat "$IDIR/base-sha")"
echo "worker line" >> "$P/b.txt"; echo "new" > "$P/worker.txt"     # the worker's turn, not yet reviewed
stop "$P"; tmux kill-session -t "$(session_name "$SLUG")" 2>/dev/null   # the session is gone, as when a resume is needed
[ -f "$SUPERVISOR_STATE_DIR/bases/$SLUG/base-snapshot" ] && ok "stopping keeps the snapshot base for a resume" || bad "the base was not kept"
PATH="$TMP/bin:$PATH" SUPERVISOR_ENABLE_RESUME=1 bash "$NS" resume "$P" "sess-1" - --no-attach > "$TMP/resume.out" 2>&1 || bad "resume failed: $(cat "$TMP/resume.out")"
[ "$(cat "$IDIR/base-sha" 2>/dev/null)" = "$snap" ] && ok "the resumed session is measured against the same snapshot, not HEAD" \
  || bad "base-sha after resume: $(cat "$IDIR/base-sha" 2>/dev/null) (snapshot $snap)"
changed="$( { git -C "$P" diff "$(cat "$IDIR/base-sha")" --name-only; worker_untracked "$P" "$IDIR"; } | sort -u | tr '\n' ' ')"
[ "$changed" = "b.txt worker.txt " ] && ok "and its review sees the worker's two changes and none of the director's" || bad "resumed review list: [$changed]"
git -C "$P" diff "$(cat "$IDIR/base-sha")" -- b.txt | grep -qE '^[-+](TWO|unstaged tail)' \
  && bad "the director's edit in b.txt counts as the worker's after resume" || ok "inside b.txt, only the worker's line"
grep -q "notes.md" "$IDIR/standards.md" && ! grep -q "worker.txt" "$IDIR/standards.md" \
  && ok "the resumed worker is told again which files are not its own — read off the snapshot, not the folder" \
  || bad "the resumed brief is wrong"
stop "$P"; tmux kill-session -t "$(session_name "$SLUG")" 2>/dev/null
( cd "$P" && git add -A . ':(exclude)inner' && git commit -qm "the director commits everything" )
PATH="$TMP/bin:$PATH" SUPERVISOR_ENABLE_RESUME=1 bash "$NS" resume "$P" "sess-1" - --no-attach > "$TMP/resume.out" 2>&1 || bad "resume failed: $(cat "$TMP/resume.out")"
[ "$(cat "$IDIR/base-sha" 2>/dev/null)" = "$(git -C "$P" rev-parse HEAD)" ] && [ ! -f "$IDIR/base-snapshot" ] \
  && ok "once nothing uncommitted is left, a resume is an ordinary run on HEAD" || bad "a stale snapshot base was restored"
stop "$P"

echo "===== an ignored file the worker exposes is not deleted by the scope gate ====="
P="$TMP/ignored"; mkdir -p "$P"
( cd "$P" && git init -q -b main && git config user.name D && git config user.email d@e.x
  printf 'vendor/\n.env\n' > .gitignore; echo x > x; git add . && git commit -qm base
  mkdir -p vendor; echo "their vendored draft" > vendor/draft.txt; echo "SECRET=1" > .env )
bash "$NS" start "$P" --no-attach >/dev/null 2>&1 || bad "start failed"
IDIR="$SUPERVISOR_STATE_DIR/instances/$(slug_for "$(canon_path "$P")")"
grep -qx "vendor/" "$IDIR/base-ignored" && grep -qx ".env" "$IDIR/base-ignored" && ok "the ignored paths were written down at the start" || bad "base-ignored: $(cat "$IDIR/base-ignored" 2>/dev/null)"
printf '%s\n' '{"schema":1,"mode":"scoped","write_paths":["worker/**"]}' > "$IDIR/runspec.json"
printf '' > "$P/.gitignore"                                     # the worker drops the ignore rules
echo "worker scribble" >> "$P/vendor/draft.txt"; echo "stray" > "$P/stray.txt"
bash "$BIN_DIR/scope-gate.sh" "$P" "$IDIR" "$(cat "$IDIR/base-sha")" >/dev/null 2>&1
[ -f "$P/vendor/draft.txt" ] && [ -f "$P/.env" ] && ok "the files ignored at the start are still there" || bad "an ignored-at-start file was deleted"
[ ! -e "$P/stray.txt" ] && ok "while the worker's own stray file is still quarantined" || bad "stray.txt survived"
jq -e '.quarantined[] | select(.path == "vendor/draft.txt" and .action == "kept_ignored_at_start")' "$IDIR/scope-violation.json" >/dev/null 2>&1 \
  && ok "and the report says it was kept, and why" || bad "scope-violation.json: $(cat "$IDIR/scope-violation.json" 2>/dev/null)"
stop "$P"

echo "===== commit: a commit as the director, with what they saw ====="
P="$TMP/commit"; make_repo "$P"
digest="$(dirty_digest "$(canon_path "$P")")"
out="$(bash "$NS" start "$P" --no-attach --dirty=commit --dirty-digest="$digest" --message="test: pin the contrast debt" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the run started" || bad "start failed ($rc): $out"
[ "$(git -C "$P" log -1 --format='%an <%ae>|%cn <%ce>')" = "Ihor Director <ihor@example.com>|Ihor Director <ihor@example.com>" ] \
  && ok "author and committer are the director's own identity" || bad "identity: $(git -C "$P" log -1 --format='%an <%ae>|%cn <%ce>')"
[ "$(git -C "$P" log -1 --format=%s)" = "test: pin the contrast debt" ] && ok "with the message they wrote" || bad "message: $(git -C "$P" log -1 --format=%s)"
[ "$(git -C "$P" log -1 --format=%H)" != "$(git -C "$P" rev-parse main~1 2>/dev/null)" ] && [ "$(git -C "$P" rev-list --count main)" = 2 ] \
  && ok "one commit, on their branch, because they asked for it" || bad "commit count wrong"
[ "$(git -C "$P" status --porcelain --untracked-files=normal)" = "?? inner/" ] && ok "everything on the list went in" || bad "left over: $(git -C "$P" status --porcelain)"
! git -C "$P" ls-files --stage | grep -q ' inner$' && ! grep -q inner "$P/.git/info/exclude" 2>/dev/null \
  && ok "the nested repository stayed out — no gitlink, nothing written to .git/info/exclude" || bad "the nested repository was swallowed or excluded"
! worktree_dirty "$(canon_path "$P")" && ok "and the folder now reads as clean" || bad "still dirty after the commit"
git -C "$P" -c core.quotePath=false show --name-only --format= HEAD | grep -q "Нотатка" && ok "including the untracked files" || bad "untracked files missing from the commit"
[ "$(nightshift_authored "$P")" = 0 ] && ok "nothing authored by night-shift" || bad "night-shift authored a commit"
stop "$P"

echo "===== commit, but the folder changed after the list was shown ====="
P="$TMP/stale"; make_repo "$P"
digest="$(dirty_digest "$(canon_path "$P")")"
echo "one more edit" >> "$P/a.txt"
before="$(fingerprint "$P")"
out="$(bash "$NS" start "$P" --no-attach --dirty=commit --dirty-digest="$digest" 2>&1)"; rc=$?
[ "$rc" = 77 ] && ok "it asks again instead of committing" || bad "exit $rc: $out"
[ "$(fingerprint "$P")" = "$before" ] && ok "nothing committed, nothing touched" || bad "the folder changed"

echo "===== commit, but git does not know who the director is ====="
P="$TMP/noid"; make_repo "$P"
git -C "$P" config --unset user.name; git -C "$P" config --unset user.email
before="$(fingerprint "$P")"
out="$(bash "$NS" start "$P" --no-attach --dirty=commit 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$rc" != 77 ] && ok "refused" || bad "exit $rc"
case "$out" in *"user.name"*) ok "and says what is missing" ;; *) bad "no reason: $out" ;; esac
[ "$(fingerprint "$P")" = "$before" ] && ok "index and files are as they were — no fallback to night-shift" || bad "the folder changed"
[ "$(git -C "$P" rev-list --count HEAD)" = 1 ] && ok "no commit" || bad "a commit was made"

echo "===== commit, but something looks like a secret ====="
P="$TMP/secret"; make_repo "$P"
echo "AWS=AKIAABCDEFGHIJKLMNOP" > "$P/.env"
before="$(fingerprint "$P")"
out="$(bash "$NS" start "$P" --no-attach --dirty=commit 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "refused" || bad "exit $rc: $out"
case "$out" in *".env"*) ok "and names the file" ;; *) bad "no file named: $out" ;; esac
[ "$(fingerprint "$P")" = "$before" ] && ok "the index is put back exactly — the partial staging survives" || bad "the index changed"
[ ! -e "$P/BLOCKED.md" ] && ok "nothing written into their project" || bad "BLOCKED.md appeared"

echo "===== commit, but their own pre-commit hook says no ====="
P="$TMP/hook"; make_repo "$P"
printf '#!/bin/sh\necho "lint: 3 problems" >&2\nexit 1\n' > "$P/.git/hooks/pre-commit"; chmod +x "$P/.git/hooks/pre-commit"
before="$(fingerprint "$P")"; idx0="$(shasum < "$P/.git/index")"
out="$(bash "$NS" start "$P" --no-attach --dirty=commit --message="mine" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "refused" || bad "exit $rc: $out"
case "$out" in *"lint: 3 problems"*) ok "with the hook's own words" ;; *) bad "the hook's reason is lost: $out" ;; esac
[ "$(fingerprint "$P")" = "$before" ] && [ "$(shasum < "$P/.git/index")" = "$idx0" ] \
  && ok "their index file is byte-for-byte what it was — it was never staged into" || bad "the index moved"
[ -z "$(ls "$P/.git" | grep night-shift-commit-index)" ] && ok "and no copy is left behind in .git" || bad "a temporary index was left in .git"

echo "===== a failed start keeps the commit they asked for, and drops the snapshot it made ====="
P="$TMP/fail-commit"; make_repo "$P"
out="$(SUPERVISOR_TMUX_FAIL=1 bash "$NS" start "$P" --no-attach --dirty=commit --message="mine" 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "the start failed (as arranged)" || bad "it started"
[ "$(git -C "$P" log -1 --format=%s)" = "mine" ] && ok "their commit is still there" || bad "the commit was rolled back: $(git -C "$P" log -1 --format=%s)"
P="$TMP/fail-keep"; make_repo "$P"
before="$(fingerprint "$P")"
out="$(SUPERVISOR_TMUX_FAIL=1 bash "$NS" start "$P" --no-attach --dirty=keep 2>&1)"; rc=$?
[ "$rc" != 0 ] && ok "the start failed (as arranged)" || bad "it started"
[ "$(fingerprint "$P")" = "$before" ] && ok "the folder is as it was" || bad "the folder changed"
[ -z "$(git -C "$P" for-each-ref refs/night-shift/)" ] && ok "no snapshot left behind" || bad "a snapshot ref survived"

echo "===== a new branch per run: the director's branch gains nothing ====="
P="$TMP/newbranch"; make_repo "$P"
main0="$(git -C "$P" rev-parse main)"
before="$(fingerprint "$P" | cut -c1-8)"
SUPERVISOR_BRANCH_MODE=new bash "$NS" start "$P" --no-attach --dirty=keep >/dev/null 2>&1 || bad "start failed"
[ "$(git -C "$P" rev-parse main)" = "$main0" ] && ok "main is where it was" || bad "main moved"
case "$(git -C "$P" symbolic-ref --short HEAD)" in night/*) ok "the run is on its own branch" ;; *) bad "not on a night branch" ;; esac
[ -n "$(git -C "$P" diff --cached --name-only)" ] && [ -f "$P/notes.md" ] && ok "with the director's changes carried along untouched" || bad "the changes did not come along"
stop "$P"

echo "===== a clean folder: nothing asked, nothing made ====="
P="$TMP/clean"; mkdir -p "$P"
( cd "$P" && git init -q -b main && git config user.name D && git config user.email d@e.x && echo x > x && git add x && git commit -qm base )
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "started straight away" || bad "exit $rc: $out"
[ "$(git -C "$P" rev-list --count --all)" = 1 ] && [ -z "$(git -C "$P" for-each-ref refs/night-shift/)" ] \
  && ok "no commit, no snapshot" || bad "something was created"
stop "$P"

echo "===== their own repository with no commits yet ====="
P="$TMP/unborn"; mkdir -p "$P"
( cd "$P" && git init -q -b main && git config user.name "Ihor Director" && git config user.email ihor@example.com && echo x > x )
out="$(bash "$NS" start "$P" --no-attach 2>&1)"; rc=$?
[ "$rc" = 77 ] && ok "asked, not committed" || bad "exit $rc: $out"
! git -C "$P" rev-parse -q --verify HEAD >/dev/null && ok "still no commit" || bad "a commit was made"
out="$(bash "$NS" start "$P" --no-attach --dirty=keep 2>&1)"; rc=$?
[ "$rc" = 77 ] && ok "«leave it» cannot measure anything here, so it asks again" || bad "exit $rc: $out"
[ "$(bash "$NS" dirty-state "$P" | jq -r .keep_possible)" = false ] && ok "and the app is told keep is not possible" || bad "keep_possible"
out="$(bash "$NS" start "$P" --no-attach --dirty=commit --message="first" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$P" log -1 --format='%ae %s')" = "ihor@example.com first" ] \
  && ok "the first commit is theirs" || bad "exit $rc, $(git -C "$P" log -1 --format='%ae %s' 2>&1)"
stop "$P"

echo "===== the night queue: nobody to ask, so it waits ====="
P="$TMP/queued"; make_repo "$P"
before="$(fingerprint "$P")"
Q="$SUPERVISOR_STATE_DIR/queue"; mkdir -p "$Q/pending/001-x"
printf '%s\n' "$(canon_path "$P")" > "$Q/pending/001-x/project"; echo "do the thing" > "$Q/pending/001-x/task"
SUPERVISOR_PREFLIGHT_ENABLE=0 bash "$BIN_DIR/queue-runner.sh" >/dev/null 2>&1
held="$(ls -1d "$Q/needs-user/001-x-needs-user-"* 2>/dev/null | head -1)"
[ -n "$held" ] && ok "the entry is waiting for the director (needs-user), not failed" || bad "not held: $(ls -R "$Q")"
[ -n "$held" ] && grep -q "notes.md" "$held/why" 2>/dev/null && ok "with the reason and the files" || bad "no reason kept"
[ "$(fingerprint "$P")" = "$before" ] && ok "zero commits, nothing touched" || bad "the queue changed the folder"

echo "===== the leftover authorship ====="
n="$(grep -n 'night-shift@local' "$BIN_DIR/night-shift.sh" | grep -v '^\s*#' | wc -l | tr -d ' ')"
[ "$n" = 2 ] && ok "night-shift@local appears only in the first commit of a repo the engine itself created" \
  || bad "night-shift@local is used in $n places: $(grep -n 'night-shift@local' "$BIN_DIR/night-shift.sh")"

echo
[ "$fails" = 0 ] && echo "✅ dirty tree: nothing is committed unasked" || echo "❌ dirty tree: $fails problem(s)"
exit "$fails"
