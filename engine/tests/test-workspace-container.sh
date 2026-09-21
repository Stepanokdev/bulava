#!/bin/bash
# A folder full of repositories must never become a repository.
#
# The report: a director connected `~/XCodeProjects-noSync/abinito-verawood` — fifteen independent
# checkouts, a python venv, Tutor's runtime data and a Chrome profile, 9.6 GB and not itself a repo.
# `start` ran `git init` in it, staged 23 108 files into a 495 MB object store, and began scanning
# each staged file for secrets with two processes per file. The app's start timeout killed it
# part-way through. What was left was a repository with a full index, no commit, and the project's
# Tutor secrets staged in it — and every retry did the same thing again. Nothing reached the log, so
# from the outside it was "Connecting to Night Shift…" and then a crash.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"
mkdir -p "$TMP/tmux"
# Isolation BEFORE the trap: inside, both TMUX_TMPDIR and a trap on our own socket are set.
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
export SUPERVISOR_CLAUDE_CMD="cat"
export SUPERVISOR_HANDSHAKE_WAIT=0
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
LOG="$SUPERVISOR_STATE_DIR/supervisor.log"

start() { SUPERVISOR_NO_ATTACH=1 bash "$BIN_DIR/night-shift.sh" start "$1" --no-attach 2>&1; }

# `canon_path` resolves symlinks, so a /var/folders temp dir is logged under /private/var:
# the log assertions match on the folder NAME, not on the path the test happens to hold.
# The reported shape, in miniature: repositories at two levels, plus the machine-generated bulk.
WS="$TMP/workspace"
mkdir -p "$WS/src" "$WS/mfes" "$WS/root/env" "$WS/venv/lib"
for r in frontend-app-home frontend-build src/edx-platform mfes/frontend-app-authoring; do
  mkdir -p "$WS/$r" && ( cd "$WS/$r" && git init -q && echo "$r" > file.txt && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init )
done
# Assembled at runtime, never written out as a literal: the engine's own export audit greps its
# tree for anything shaped like a key, and a fixture in a test file would stop every publish.
FAKE_KEY="sk-$(printf 'a%.0s' $(seq 1 28))"
FAKE_TOKEN="ghp_$(printf 'b%.0s' $(seq 1 36))"
FAKE_AWS="AKIA$(printf 'C%.0s' $(seq 1 16))"
printf 'SECRET_KEY: %s\n' "$FAKE_KEY" > "$WS/root/config.yml"
for i in $(seq 1 40); do echo "x" > "$WS/venv/lib/mod$i.py"; done

echo "===== a workspace is refused, and nothing in it is touched ====="
out="$(start "$WS")"
case "$out" in *"робоча тека, а не репозиторій"*) ok "the refusal says what the folder is" ;;
  *) bad "no refusal — got: $(printf '%s' "$out" | head -2)" ;; esac
case "$out" in *"frontend-app-home"*|*"src/edx-platform"*) ok "it names the repositories it found" ;;
  *) bad "the refusal does not say which repositories are in there" ;; esac
[ -e "$WS/.git" ] && bad "it created a repository over the workspace anyway" \
                  || ok "no .git was created in the workspace"
if ( cd "$WS/src/edx-platform" && git status --porcelain | grep -q .; ) then
  bad "a child repository was modified"
else ok "the child repositories are exactly as they were"; fi
grep -qE "REFUSED .*/workspace$" "$LOG" 2>/dev/null && ok "the refusal is in supervisor.log" \
  || bad "nothing about the refusal reached the log — the original complaint"

echo
echo "===== the wreckage of the old behaviour is refused too ====="
# What the killed start left behind: from git's side the folder is now a repository, so a check for
# "is this a repo" would wave the next attempt straight back into the same hole.
( cd "$WS" && git init -q && git add -A >/dev/null 2>&1 )
before="$(cd "$WS" && git rev-parse --git-dir >/dev/null 2>&1 && git diff --cached --name-only | wc -l | tr -d ' ')"
out="$(start "$WS")"
case "$out" in *"робоча тека, а не репозиторій"*) ok "the half-made repository does not make it a project" ;;
  *) bad "the retry was allowed through" ;; esac
after="$(cd "$WS" && git diff --cached --name-only | wc -l | tr -d ' ')"
[ "$before" = "$after" ] && ok "nothing more was staged into it" || bad "the retry staged more files ($before → $after)"
[ -d "$WS/.git" ] && ok "a .git we did not create is left alone" || bad "it deleted a repository whose origin it cannot know"
rm -rf "$WS/.git"

echo
echo "===== an ordinary folder is asked about, not quietly turned into a repository ====="
# Connecting a folder is not consent to change it. The engine used to answer "no git here?" with
# "then I will make one" — in a folder of videos, in a pile of documents, in somebody's export. It
# now stops and asks, and the asking is a wall with a door: `allow-git` is what the app's button
# runs. The wall is not politeness — without a baseline a night has no way back and nothing to show
# a review, which is why the run does not simply proceed without git.
PLAIN="$TMP/plain"
mkdir -p "$PLAIN/src" "$PLAIN/node_modules/left-pad"
echo "console.log(1)" > "$PLAIN/src/app.js"
for i in $(seq 1 30); do echo "x" > "$PLAIN/node_modules/left-pad/f$i.js"; done
out="$(start "$PLAIN")"; rc=$?
case "$out" in *"немає git"*) ok "it asks instead of creating git on its own" ;;
  *) bad "no question was asked — got: $(printf '%s' "$out" | head -1)" ;; esac
[ "$rc" = 76 ] && ok "…with the exit code the app listens for (76)" \
                || bad "the app cannot tell this apart from a failure (exit $rc)"
[ -e "$PLAIN/.git" ] && bad "it created git anyway, without being told to" \
                     || ok "and nothing was created in the folder"

bash "$BIN_DIR/night-shift.sh" allow-git "$PLAIN" >/dev/null 2>&1 \
  && ok "the answer is recorded by a command the button can run" \
  || bad "allow-git refused an ordinary folder"
out="$(start "$PLAIN")"
if ( cd "$PLAIN" && git rev-parse HEAD >/dev/null 2>&1 ); then ok "after the answer, there is a baseline commit"
else bad "consent was given and still no baseline — the night would have no way back"; fi
if ( cd "$PLAIN" && git ls-files | grep -q '^src/app.js$' ); then ok "the project's own files are in it"
else bad "the project's files were not committed"; fi
if ( cd "$PLAIN" && git ls-files | grep -q '^node_modules/' ); then
  bad "node_modules went into the object store"
else ok "node_modules stayed out of the first commit"; fi
bash "$BIN_DIR/night-shift.sh" stop "$PLAIN" >/dev/null 2>&1 || true

echo
echo "===== too big to checkpoint stops BEFORE anything is written ====="
BIG="$TMP/big"; mkdir -p "$BIG"
for i in $(seq 1 12); do echo "x" > "$BIG/f$i.txt"; done
bash "$BIN_DIR/night-shift.sh" allow-git "$BIG" >/dev/null 2>&1   # otherwise the git question stops it
out="$(SUPERVISOR_CHECKPOINT_MAX_FILES=5 start "$BIG")"
case "$out" in *"мав би взяти"*) ok "it says what the checkpoint would have cost" ;;
  *) bad "the budget did not stop it — got: $(printf '%s' "$out" | head -2)" ;; esac
[ -e "$BIG/.git" ] && bad "it left a half-made repository behind" \
                   || ok "the .git it had just created was cleaned up"
grep -qE "REFUSED .*/big$" "$LOG" 2>/dev/null && ok "the budget refusal is in the log" \
  || bad "the budget refusal never reached the log"

echo
echo "===== a folder we could not see the whole of is not an ordinary folder ====="
# "I found no repositories" and "I did not finish looking" are the same sentence to a caller that
# only counts — and the difference is the entire bug. The walk that gave up on a nine-gigabyte
# workspace answered "ordinary folder", and the next thing to run was git init over fifteen
# checkouts. Each way the walk can come back short is checked, because each one produced that answer.
# Deeper than the walk goes: found nothing, and says so rather than pretending the folder is empty.
DEEP="$TMP/deep"; mkdir -p "$DEEP/a/b/c/d/e/f/g/h" && ( cd "$DEEP/a/b/c/d/e/f/g/h" && git init -q )
out="$(SUPERVISOR_WORKSPACE_SCAN_DEPTH=3 start "$DEEP")"
case "$out" in *"оглянути цю теку до кінця"*)
    ok "a repository below the depth limit is not read as an empty folder" ;;
  *) bad "it walked past the depth limit and called the folder ordinary" ;; esac
[ -e "$DEEP/.git" ] && bad "it made a repository out of a folder it had not finished looking at" \
                    || ok "and nothing was created in it"

# …and the case that made this fire on innocent folders: a leaf sitting exactly ON the limit, with
# nothing under it and no repository anywhere. It hides nothing, and it used to be refused.
LEAF="$TMP/leaf"; mkdir -p "$LEAF/a/b/c/d"; echo hi > "$LEAF/readme.md"
out="$(start "$LEAF")"
case "$out" in *"оглянути цю теку до кінця"*)
    bad "an ordinary folder with a leaf at the limit is still accused of hiding repositories" ;;
  *) ok "a leaf exactly at the limit is not mistaken for an unexplored depth" ;; esac

SLOW="$TMP/slow"; mkdir -p "$SLOW/src" && echo "x" > "$SLOW/src/a.txt"
out="$(SUPERVISOR_WORKSPACE_SCAN_TIMEOUT=0 start "$SLOW")"
case "$out" in *"оглянути цю теку до кінця"*) ok "a scan that ran out of time refuses" ;;
  *) bad "a timed-out scan was read as 'no repositories here'" ;; esac
[ -e "$SLOW/.git" ] && bad "it created a repository after a scan that timed out" \
                    || ok "and that folder is untouched too"

LOCKED="$TMP/locked"; mkdir -p "$LOCKED/sub"; chmod 000 "$LOCKED/sub"
out="$(start "$LOCKED")"
chmod 755 "$LOCKED/sub"
case "$out" in *"оглянути цю теку до кінця"*) ok "a folder it cannot read into refuses" ;;
  *) bad "an unreadable subfolder was silently read as empty" ;; esac
[ -e "$LOCKED/.git" ] && bad "it created a repository despite a folder it could not read" \
                      || ok "and that folder is untouched as well"

echo
echo "===== git storages that are not projects ====="
# Forty-one of these sit on the director's disk, and both scanners used to see them as ordinary
# files: a bare store keeps HEAD and objects in the directory itself, with no `.git` to stop at. The
# engine would have run `git init` over somebody's object store and staged its insides.
BARE="$TMP/bare"; mkdir -p "$BARE"
git init -q --bare "$BARE/alpha.git"; git init -q --bare "$BARE/beta.git"
out="$(start "$BARE")"
case "$out" in *"git-сховища, а не проєкти"*) ok "a folder of bare stores is refused, by name" ;;
  *) bad "bare stores read as ordinary files — got: $(printf '%s' "$out" | head -1)" ;; esac
[ -e "$BARE/.git" ] && bad "it made a repository over somebody's object stores" \
                    || ok "and nothing was created over them"
bash "$BIN_DIR/night-shift.sh" allow-git "$BARE" >/dev/null 2>&1 \
  && bad "the consent command agreed to make git over bare stores" \
  || ok "…and the button cannot agree to it either"

out="$(start "$BARE/alpha.git")"
case "$out" in *"bare-сховище"*) ok "a bare store connected on its own is refused too" ;;
  *) bad "running inside a bare store was allowed" ;; esac

BROKEN="$TMP/broken"; mkdir -p "$BROKEN/b/.git"; echo "ref: refs/heads/main" > "$BROKEN/b/.git/HEAD"
out="$(start "$BROKEN")"
case "$out" in *"git-сховища, а не проєкти"*) ok "a damaged store is not mistaken for a project" ;;
  *) bad "a damaged store passed as ordinary files" ;; esac

INSIDE="$TMP/inside"; mkdir -p "$INSIDE/packages/web"
( cd "$INSIDE" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
out="$(start "$INSIDE/packages/web")"
case "$out" in *"частина репозиторія"*) ok "a subfolder of a repository does not get its own git" ;;
  *) bad "it would have made a second git inside somebody's repository" ;; esac
[ -e "$INSIDE/packages/web/.git" ] && bad "and it actually created one" \
                                   || ok "and none was created"

echo
echo "===== the app and the engine read the same answer ====="
# The rule used to live twice and disagreed in three places at once. It lives once now, and this is
# the command the app asks. A change of wording here is a change the app sees.
scan() { bash "$BIN_DIR/night-shift.sh" scan-folder "$1" 2>/dev/null; }
case "$(scan "$WS")" in *"kind=container"*) ok "a workspace answers container" ;;
  *) bad "scan-folder does not call the workspace a container" ;; esac
[ "$(scan "$WS" | grep -c '^repo	')" -ge 4 ] && ok "…and lists the repositories it found" \
  || bad "the list of repositories is missing from the answer"
case "$(scan "$BARE")" in *"kind=storage"*) ok "a folder of bare stores answers storage" ;;
  *) bad "scan-folder does not call bare stores storage" ;; esac
case "$(scan "$INSIDE/packages/web")" in *"kind=inside"*) ok "a subfolder of a repository answers inside" ;;
  *) bad "scan-folder does not recognise a subfolder of a repository" ;; esac
case "$(scan "$LEAF")" in *"kind=plain"*complete=yes*) ok "an ordinary folder answers plain, seen whole" ;;
  *) bad "an ordinary folder is not answered as plain" ;; esac

echo
echo "===== the secret scan reads whole blobs, in one pass ====="
SEC="$TMP/secrets"; mkdir -p "$SEC"
( cd "$SEC" && git init -q )
printf 'prefix\0\0binary\n%s\n' "$FAKE_TOKEN" > "$SEC/blob.bin"
printf '%s\n' "$FAKE_AWS" > "$SEC/conf.yml"
printf 'PLACEHOLDER\n' > "$SEC/.env.example"
printf 'hello\n' > "$SEC/readme.txt"
( cd "$SEC" && git add -A )
found="$( cd "$SEC" && bash -c '. "'"$BIN_DIR"'/supervisor-lib.sh"; staged_secret_paths' )"
case "$found" in *conf.yml*) ok "a key in a text file is found" ;; *) bad "missed the key in conf.yml" ;; esac
case "$found" in *blob.bin*) ok "a token in a file with NUL bytes is found" ;;
  *) bad "missed the token in a binary blob" ;; esac
case "$found" in *.env.example*) bad "an example env file was called a secret" ;;
  *) ok "an example env file is not a secret" ;; esac
case "$found" in *readme.txt*) bad "an ordinary file was called a secret" ;;
  *) ok "ordinary files are left alone" ;; esac

echo
[ "$fails" = 0 ] && echo "✅ workspace: a folder of repositories never becomes one" \
                 || echo "❌ workspace: $fails problem(s)"
exit "$fails"
