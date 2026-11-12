#!/bin/bash
# A chat he sits at, in a folder with no git, that changes code is reviewed (lib/plain-shadow.sh).
#
# Before: «plain folder: no git and nothing to review — the run's declared outcome (succeeded_changes)
# stands». In the week of 3–10 Nov that is how MonitorControl, the roulette in Everything, AI Factory
# and IdeaBank had code accepted that no reviewer read.
#
# Pinned:
#   1. The start of such a chat copies the folder's readable files into a git of the engine's own in
#      the run's instance folder; nothing at all is written into his folder. An automation's run
#      (unattended) is not copied.
#   2. A declared success with code changed is reviewed: Codex is asked, and the patch — measured
#      against the copy — is in front of it, with a note that the folder has no git. A pass moves
#      the copy's base to what was accepted; a fail does not.
#   3. Only prose changed, a research result, "nothing to change", an automation's job: as before,
#      the declared outcome stands with no review.
#   4. A file too large to copy is named for the reviewer, not read; repositories nested in the
#      folder and dependency folders are not copied.
#   5. His folder ends the run exactly as the work left it: no .git, no list, no fingerprint.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP"' EXIT INT TERM
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_COMMIT_MESSAGE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP SUPERVISOR_PLAIN_FOLDER SUPERVISOR_ALLOW_TOOLS SUPERVISOR_UNATTENDED
export SUPERVISOR_CLAUDE_CMD="cat" SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
NS="$BIN_DIR/night-shift.sh"
APP=(env SUPERVISOR_RUN_ENV_FROM_APP=1 "SUPERVISOR_APP_ANSWERS=dirty mcp git heavy")

. "$BIN_DIR/supervisor-lib.sh"

KEYDIR="$TMP/keys"; mkdir -p "$KEYDIR"
openssl ecparam -name prime256v1 -genkey -noout -out "$KEYDIR/priv.pem" 2>/dev/null
openssl ec -in "$KEYDIR/priv.pem" -pubout -out "$SUPERVISOR_STATE_DIR/decision-key.pem" 2>/dev/null
record_plain() {   # $1 = the folder
  local slug; slug="$(slug_for "$(canon_path "$1")")"
  printf '%s' "plain-folder|$slug" > "$KEYDIR/payload"
  openssl dgst -sha256 -sign "$KEYDIR/priv.pem" -out "$KEYDIR/sig" "$KEYDIR/payload" 2>/dev/null
  mkdir -p "$SUPERVISOR_STATE_DIR/plain-folders"
  jq -nc --arg s "$(base64 < "$KEYDIR/sig" | tr -d '\n')" '{signature:$s}' > "$(plain_folder_file "$slug")"
}
# Everything in a folder, with sizes and contents, to tell that nothing was added to it.
listing() { ( cd "$1" && find . -print0 | sort -z | xargs -0 shasum 2>/dev/null; find . | sort ) ; }

echo "===== 1. the copy is taken outside his folder ====="
F="$TMP/MonitorControl"; mkdir -p "$F/src" "$F/node_modules/dep" "$F/vendor-app"
printf 'export const a = 1\n' > "$F/src/a.js"
printf 'def old(): pass\n' > "$F/src/gone.py"
printf '# MonitorControl\n' > "$F/README.md"
printf 'dep\n' > "$F/node_modules/dep/index.js"
( cd "$F/vendor-app" && git init -q && git config user.email t@t && git config user.name t && echo v > v.swift && git add -A && git commit -qm v )
IDIR="$(instance_dir "$(slug_for "$(canon_path "$F")")")"; mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$F")" > "$IDIR/project"
before="$(listing "$F")"
plain_shadow_take "$IDIR" "$F"
plain_shadow_present "$IDIR" && ok "a copy was taken" || bad "no copy"
[ "$(listing "$F")" = "$before" ] && ok "nothing was written into his folder" || bad "his folder changed"
[ -e "$F/.git" ] && bad "a .git appeared in his folder" || ok "no .git in his folder"
case "$(plain_shadow_dir "$IDIR")" in "$IDIR"/*) ok "the copy lives in the run's instance folder" ;; *) bad "the copy is elsewhere" ;; esac
kept="$(git --git-dir="$(plain_shadow_dir "$IDIR")" ls-tree -r --name-only refs/plain/base)"
printf '%s\n' "$kept" | grep -qx 'src/a.js' && ok "code is copied" || bad "src/a.js not copied: $kept"
printf '%s\n' "$kept" | grep -q '^node_modules/' && bad "node_modules was copied" || ok "dependency folders are not"
printf '%s\n' "$kept" | grep -q '^vendor-app/' && bad "a nested repository was copied" || ok "repositories nested in it are not"
plain_shadow_take "$IDIR" "$F"
[ "$(git --git-dir="$(plain_shadow_dir "$IDIR")" rev-list --count refs/plain/base)" = 1 ] \
  && ok "taken once: a second call keeps the base" || bad "the base was taken again"

echo "===== what changed, measured against it ====="
printf 'export const a = 2\nconsole.log("roulette")\n' > "$F/src/a.js"
printf 'print("new")\n' > "$F/src/new.py"
rm -f "$F/src/gone.py"
printf '\nmore\n' >> "$F/README.md"
changed="$(plain_shadow_changed "$IDIR" "$F")"
for p in src/a.js src/new.py src/gone.py README.md; do
  printf '%s\n' "$changed" | grep -qx "$p" && ok "changed: $p" || bad "not seen: $p ($changed)"
done
code="$(plain_shadow_changed_code "$IDIR" "$F")"
printf '%s\n' "$code" | grep -qx README.md && bad "prose counted as code" || ok "prose is not code"
patch="$(plain_shadow_patch "$IDIR" "$F")"
grep -q '^+console.log("roulette")' "$patch" && ok "the patch holds the change" || bad "patch: $(head -20 "$patch")"
case "$patch" in "$IDIR"/*) ok "and is written beside the run" ;; *) bad "patch at $patch" ;; esac

echo "===== 2. the gate reviews a declared success with code changed ====="
GATE="$ROOT/hooks/review-gate.sh"
FAKE="$TMP/fake"; mkdir -p "$FAKE"; export CODEX_CALLED="$FAKE/called" CODEX_PROMPT="$FAKE/prompt"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
echo called >> "$CODEX_CALLED"
printf '%s\n' "$@" >> "$CODEX_PROMPT"
echo "STATE: COMPLETE"; echo "VERDICT: ${FAKE_VERDICT:-PASS}"
[ "${FAKE_VERDICT:-PASS}" = FAIL ] && echo "1. [acceptance_failure] src/a.js — рулетка крутиться назад"
exit 0
EOF
chmod +x "$FAKE/codex"
TR="$TMP/transcript.jsonl"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово"}]}}' > "$TR"
RID="plain-chat-1"
G="$TMP/Everything"; GIDIR="$(instance_dir "$(slug_for "$(canon_path "$G")")")"
mkcase() {   # [$1 = "unattended"]
  rm -rf "$G" "$GIDIR"; mkdir -p "$G/app" "$GIDIR"
  printf 'const spin = () => 1\n' > "$G/app/roulette.js"
  printf '# notes\n' > "$G/notes.md"
  printf '%s\n' "$(canon_path "$G")" > "$GIDIR/project"
  printf '%s\n' "$RID" > "$GIDIR/run-id"
  [ "${1:-}" = unattended ] && printf "export SUPERVISOR_UNATTENDED='1'\n" > "$(run_env_file "$GIDIR")"
  record_plain "$G"
  plain_shadow_take "$GIDIR" "$G"
  rm -f "$SUPERVISOR_STATE_DIR"/outcome-nudge-* "$SUPERVISOR_STATE_DIR"/rounds-* "$CODEX_PROMPT" 2>/dev/null || true
}
declare_outcome() {
  jq -nc --arg r "$1" --arg rid "$RID" --arg ts "$(date '+%F %T')" \
    '{schema:1, result:$r, summary:"Додав рулетку", ts:$ts, run_id:$rid}' > "$GIDIR/outcome.json"
}
rungate() {
  rm -f "$CODEX_CALLED"
  printf '{"session_id":"s1","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$G" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
      PATH="$FAKE:$PATH" "$GATE" 2>/dev/null
}
done_is() { [ "$(cat "$GIDIR/done" 2>/dev/null)" = "$1" ]; }
reviewed() { [ -s "$CODEX_CALLED" ]; }

mkcase
printf 'const spin = () => Math.random() < 0.5 ? "red" : "black"\n' > "$G/app/roulette.js"
before="$(listing "$G")"
declare_outcome succeeded_changes
out="$(rungate)"
reviewed && ok "code changed: Codex was asked" || bad "no review: $out"
grep -q 'THIS FOLDER HAS NO GIT' "$CODEX_PROMPT" 2>/dev/null && ok "told the folder has no git" || bad "the prompt does not say so"
grep -qF '+const spin = () => Math.random()' "$CODEX_PROMPT" 2>/dev/null && ok "and given the patch" || bad "the patch is not in the prompt"
done_is passed && ok "a PASS passes" || bad "done=$(cat "$GIDIR/done" 2>/dev/null)"
[ -z "$(plain_shadow_changed "$GIDIR" "$G")" ] && ok "and the copy's base is what was accepted" || bad "base not moved: $(plain_shadow_changed "$GIDIR" "$G")"
[ "$(listing "$G")" = "$before" ] && ok "his folder is exactly as the work left it" || bad "the review changed his folder"
[ -e "$G/.git" ] && bad "a .git appeared" || ok "no .git"
grep -q "reviewed from the copy kept outside the folder" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "the log says why" || bad "no log line"

mkcase
printf 'const spin = () => -1\n' > "$G/app/roulette.js"
declare_outcome succeeded_changes
FAKE_VERDICT=FAIL rungate >/dev/null
reviewed && ok "a second change is reviewed too" || bad "not reviewed"
done_is passed && bad "a FAIL passed" || ok "a FAIL does not pass"
printf '%s\n' "$(plain_shadow_changed "$GIDIR" "$G")" | grep -qx app/roulette.js \
  && ok "and the base stays: the change is still owed a review" || bad "the base moved on a FAIL"

echo "===== 3. where the declared outcome stands, as before ====="
mkcase
printf '\nmore notes\n' >> "$G/notes.md"
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && bad "prose alone was sent to review" || ok "only prose changed: no review"
done_is passed && ok "and the outcome stands" || bad "done=$(cat "$GIDIR/done" 2>/dev/null)"

for result in succeeded_research succeeded_no_change; do
  mkcase; printf 'x()\n' >> "$G/app/roulette.js"
  declare_outcome "$result"; rungate >/dev/null
  reviewed && bad "$result was reviewed" || ok "$result: stands, no review"
  done_is passed && ok "$result: passed" || bad "$result → $(cat "$GIDIR/done" 2>/dev/null)"
done

mkcase unattended; printf 'x()\n' >> "$G/app/roulette.js"
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && bad "an automation's job was reviewed" || ok "an automation's job (unattended): no review, as before"
done_is passed && ok "and passed" || bad "unattended → $(cat "$GIDIR/done" 2>/dev/null)"

mkcase; rm -rf "$(plain_shadow_dir "$GIDIR")"; printf 'x()\n' >> "$G/app/roulette.js"
declare_outcome succeeded_changes; rungate >/dev/null
done_is passed && ok "no copy (a run from before copies were kept): as before" || bad "no copy → $(cat "$GIDIR/done" 2>/dev/null)"
grep -q "no copy of the folder was taken" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "and the log says so" || bad "no log line"

echo "===== 4. a file too large to copy is named, not read ====="
mkcase
printf 'const spin = 2\n' > "$G/app/roulette.js"
sleep 1
dd if=/dev/zero of="$G/app/model.bin" bs=1024 count=1100 2>/dev/null
declare_outcome succeeded_changes; rungate >/dev/null
grep -q 'app/model.bin' "$CODEX_PROMPT" 2>/dev/null && ok "the large file is named for the reviewer" || bad "large file not named"
git --git-dir="$(plain_shadow_dir "$GIDIR")" ls-tree -r --name-only HEAD | grep -q model.bin \
  && bad "the large file was copied" || ok "and not copied"

echo "===== a .gitignore in his folder neither breaks the copy nor hides code ====="
mkcase
printf 'secret.env\n*.log\n' > "$G/.gitignore"; printf 'KEY=1\n' > "$G/secret.env"
rm -rf "$(plain_shadow_dir "$GIDIR")"; plain_shadow_take "$GIDIR" "$G"
plain_shadow_present "$GIDIR" && ok "a copy is taken although a .gitignore names a file in it" || bad "no copy: $(cat "$GIDIR/plain-shadow.skipped" 2>/dev/null)"
printf 'const spin = () => 3\n' > "$G/app/roulette.js"; printf 'x\n' > "$G/run.log"
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && ok "code beside an ignored file is reviewed" || bad "not reviewed"
grep -qF '+const spin = () => 3' "$CODEX_PROMPT" 2>/dev/null && ok "with its patch" || bad "patch missing"

echo "===== a comparison that fails is not taken for 'nothing changed' ====="
# The copy made unreadable under the gate: git cannot answer what changed.
mkcase; printf 'const spin = () => 4\n' > "$G/app/roulette.js"
chmod a-w "$(plain_shadow_dir "$GIDIR")"          # the copy is there, but git cannot stage into it
declare_outcome succeeded_changes; rungate >/dev/null
chmod u+w "$(plain_shadow_dir "$GIDIR")"
reviewed && ok "an unreadable copy sends the run to review" || bad "an unreadable copy passed without review"
grep -q "the comparison with the copy failed" "$SUPERVISOR_STATE_DIR/supervisor.log" \
  && ok "and the log says the comparison failed" || bad "the log does not say the comparison failed"
grep -q "the comparison with the copy failed: read the changed files" "$CODEX_PROMPT" 2>/dev/null \
  && ok "and so does the reviewer's brief" || bad "the brief does not say it"

echo "===== a change only to a file too large to copy is reviewed ====="
mkcase
sleep 1
dd if=/dev/urandom of="$G/app/bundle.min.js" bs=1024 count=1100 2>/dev/null
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && ok "a new large file of code alone: reviewed" || bad "a new large file of code passed without review"
grep -q 'app/bundle.min.js' "$CODEX_PROMPT" 2>/dev/null && ok "and named for the reviewer" || bad "not named"
mkcase
dd if=/dev/zero of="$G/app/model.bin" bs=1024 count=1100 2>/dev/null
rm -rf "$(plain_shadow_dir "$GIDIR")"; plain_shadow_take "$GIDIR" "$G"
sleep 1; printf 'tail' >> "$G/app/model.bin"
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && ok "an edit to an existing large file alone: reviewed" || bad "an edited large file passed without review"
grep -q 'app/model.bin' "$CODEX_PROMPT" 2>/dev/null && ok "and named" || bad "not named"

echo "===== a large file of code deleted, and nothing else: reviewed, and still owed after a FAIL ====="
mkcase
dd if=/dev/urandom of="$G/app/bundle.js" bs=1024 count=1100 2>/dev/null
rm -rf "$(plain_shadow_dir "$GIDIR")"; plain_shadow_take "$GIDIR" "$G"
rm -f "$G/app/bundle.js"
declare_outcome succeeded_changes; FAKE_VERDICT=FAIL rungate >/dev/null
reviewed && ok "deleting a large file of code alone: reviewed" || bad "a deleted large file passed without review"
grep -q 'app/bundle.js (deleted' "$CODEX_PROMPT" 2>/dev/null && ok "named as deleted" || bad "not named as deleted: $(grep -n bundle "$CODEX_PROMPT" 2>/dev/null)"
done_is passed && bad "the FAIL passed" || ok "the FAIL does not pass"
declare_outcome succeeded_changes; rungate >/dev/null
grep -q 'app/bundle.js (deleted' "$CODEX_PROMPT" 2>/dev/null && ok "handed in again, the deletion is still in front of the reviewer" || bad "the deletion was forgotten after the FAIL"
done_is passed && ok "and a PASS passes" || bad "pass → $(cat "$GIDIR/done" 2>/dev/null)"
[ -z "$(plain_shadow_unread_code "$GIDIR" "$G")" ] && ok "after which it is part of the base" || bad "still owed after the pass"

echo "===== a secret is named, never read — not in the copy, the patch or the brief ====="
mkcase
# Made from parts at run time: written out whole, they would look like real secrets to the export's
# own audit (publish-engine.sh), which this file travels through.
SK="sk""-live-DO-NOT-LEAK"; PEM_HEAD="-----BEGIN ""PRIVATE KEY-----"; PEM_TAIL="-----END ""PRIVATE KEY-----"
printf 'API_KEY=%s-4242\n' "$SK" > "$G/.env"
printf -- '%s\nDO-NOT-LEAK-PEM\n%s\n' "$PEM_HEAD" "$PEM_TAIL" > "$G/deploy.pem"
rm -rf "$(plain_shadow_dir "$GIDIR")"; plain_shadow_take "$GIDIR" "$G"
printf 'API_KEY=%s-9999\n' "$SK" > "$G/.env"
printf '{"client_secret":"DO-NOT-LEAK-JSON"}\n' > "$G/app/credentials.json"
printf 'const spin = () => "with secrets around"\n' > "$G/app/roulette.js"
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && ok "the code beside them is reviewed" || bad "not reviewed"
grep -qF '+const spin = () => "with secrets around"' "$CODEX_PROMPT" 2>/dev/null && ok "with its patch" || bad "patch missing"
grep -q 'DO-NOT-LEAK' "$CODEX_PROMPT" 2>/dev/null && bad "a secret's value reached the reviewer's brief" || ok "no secret's value in the brief"
grep -q 'DO-NOT-LEAK' "$GIDIR/plain-diff.patch" 2>/dev/null && bad "a secret's value is in the patch" || ok "nor in the patch"
git --git-dir="$(plain_shadow_dir "$GIDIR")" grep -q 'DO-NOT-LEAK' $(git --git-dir="$(plain_shadow_dir "$GIDIR")" rev-list --all) 2>/dev/null \
  && bad "a secret's value is in the copy" || ok "nor anywhere in the copy"
git --git-dir="$(plain_shadow_dir "$GIDIR")" ls-tree -r --name-only HEAD | grep -qE '(^|/)(\.env|deploy\.pem|credentials\.json)$' \
  && bad "a secret file was copied" || ok "no secret file was copied"
grep -q '\.env (changed, a secret' "$CODEX_PROMPT" 2>/dev/null && ok "the changed .env is named" || bad ".env not named"
grep -q 'app/credentials.json (new, a secret' "$CODEX_PROMPT" 2>/dev/null && ok "the new credentials file is named" || bad "credentials not named"
mkcase; printf 'const secretSanta = 1\n' > "$G/app/secret_santa.js"
declare_outcome succeeded_changes; rungate >/dev/null
grep -qF '+const secretSanta = 1' "$CODEX_PROMPT" 2>/dev/null && ok "a source file with 'secret' in its name is still code, read" || bad "secret_santa.js was hidden"

echo "===== a repository inside and code around it: the reviewer gets both ====="
UP="$TMP/upstream.git"; rm -rf "$UP" "$TMP/up-src"; mkdir -p "$TMP/up-src"
( cd "$TMP/up-src" && git init -q -b develop && git config user.email t@t && git config user.name t \
    && echo app > app.swift && git add -A && git commit -qm upstream && git clone -q --bare . "$UP" )
mkcase
( cd "$G" && git clone -q -b develop "$UP" app-ios && cd app-ios && git config user.email t@t && git config user.name t \
    && echo brand > theme.swift && git add -A && git commit -qm brand )
printf 'const spin = () => "nested"\n' > "$G/app/roulette.js"
declare_outcome succeeded_changes; rungate >/dev/null
reviewed && ok "reviewed" || bad "not reviewed"
grep -qF '+const spin = () => "nested"' "$CODEX_PROMPT" 2>/dev/null && ok "the folder around the repository: its patch is there" || bad "the outer patch is missing"
grep -q 'app-ios' "$CODEX_PROMPT" 2>/dev/null && ok "the repository inside: named" || bad "the nested repository is missing"
grep -q 'theme.swift' "$(plain_shadow_dir "$GIDIR")/../plain-diff.patch" 2>/dev/null && bad "the nested repository's files were copied" || ok "and its files are not in the folder's patch"
done_is passed && [ -z "$(plain_shadow_changed_code "$GIDIR" "$G")" ] && ok "after the pass, the reviewed change is the base" || bad "base after pass: $(plain_shadow_changed_code "$GIDIR" "$G")"

echo "===== a declared research result with code changed: stands, but the change stays owed ====="
mkcase; printf 'const spin = () => "later"\n' > "$G/app/roulette.js"
declare_outcome succeeded_research; rungate >/dev/null
done_is passed && ok "the research result stands" || bad "research → $(cat "$GIDIR/done" 2>/dev/null)"
printf '%s\n' "$(plain_shadow_changed_code "$GIDIR" "$G")" | grep -qx app/roulette.js \
  && ok "the base did not move over the unreviewed code" || bad "the base absorbed unreviewed code"
declare_outcome succeeded_changes; rungate >/dev/null
grep -qF '+const spin = () => "later"' "$CODEX_PROMPT" 2>/dev/null && ok "the next declared change is reviewed with it" || bad "the earlier code was not in the next review"

echo "===== 5. the start: a chat he sits at is copied, an automation's run is not ====="
S="$TMP/IdeaBank"; mkdir -p "$S"; printf 'x = 1\n' > "$S/app.py"
before="$(listing "$S")"
out="$("${APP[@]}" SUPERVISOR_PLAIN_FOLDER=1 bash "$NS" start "$S" --no-attach 2>&1)"; rc=$?
SIDIR="$(instance_dir "$(slug_for "$(canon_path "$S")")")"
[ "$rc" = 0 ] && ok "started" || bad "exit $rc: $out"
plain_shadow_present "$SIDIR" && ok "an attended plain chat gets its copy at the start" || bad "no copy at the start"
[ "$(listing "$S")" = "$before" ] && ok "and his folder is untouched" || bad "the start changed his folder"

echo "===== change → FAIL → stop → resume → handed in again: the unaccepted change is still owed ====="
record_plain "$S"
printf 'x = 2  # not accepted\n' > "$S/app.py"
SRID="$(cat "$SIDIR/run-id")"
jq -nc --arg rid "$SRID" --arg ts "$(date '+%F %T')" '{schema:1, result:"succeeded_changes", summary:"x", ts:$ts, run_id:$rid}' > "$SIDIR/outcome.json"
srungate() {   # $1 = verdict
  rm -f "$CODEX_CALLED" "$CODEX_PROMPT"
  printf '{"session_id":"s2","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$TR" "$S" \
    | ORCHESTRATOR_RUN_ID="$(cat "$SIDIR/run-id")" SUPERVISOR_VERIFIER_ENABLED=0 SUPERVISOR_CODEX_USAGE_CMD=/usr/bin/true \
      FAKE_VERDICT="$1" PATH="$FAKE:$PATH" "$GATE" >/dev/null 2>&1
}
srungate FAIL
reviewed && ok "the change was reviewed and returned" || bad "not reviewed"
bash "$NS" stop "$S" >/dev/null 2>&1
tmux kill-session -t "$(session_name "$(slug_for "$(canon_path "$S")")")" 2>/dev/null   # stop leaves the pane; a resume is for a session that went
[ -d "$SIDIR" ] && bad "the run folder is still there after stop" || ok "stopped: the run folder is gone"
out="$(SUPERVISOR_ENABLE_RESUME=1 SUPERVISOR_PLAIN_FOLDER=1 bash "$NS" resume "$S" "00000000-0000-4000-8000-0000000000a1" - --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "resumed" || bad "resume exit $rc: $out"
printf '%s\n' "$(plain_shadow_changed_code "$SIDIR" "$S")" | grep -qx app.py \
  && ok "the resumed run measures from the base accepted before — the returned change is still a change" \
  || bad "the resume took the folder as it is for its base: $(plain_shadow_changed "$SIDIR" "$S")"
jq -nc --arg rid "$(cat "$SIDIR/run-id")" --arg ts "$(date '+%F %T')" '{schema:1, result:"succeeded_changes", summary:"x", ts:$ts, run_id:$rid}' > "$SIDIR/outcome.json"
srungate PASS
grep -qF '+x = 2  # not accepted' "$CODEX_PROMPT" 2>/dev/null && ok "handed in again, the reviewer sees it" || bad "the returned change is not in the next review"
bash "$NS" stop "$S" >/dev/null 2>&1
"${APP[@]}" SUPERVISOR_PLAIN_FOLDER=1 bash "$NS" start "$S" --no-attach >/dev/null 2>&1
[ -z "$(plain_shadow_changed "$SIDIR" "$S")" ] && ok "a fresh start measures itself" || bad "a fresh start reused a kept copy"
bash "$NS" stop "$S" >/dev/null 2>&1
U="$TMP/meetings-job"; mkdir -p "$U"; printf 'n\n' > "$U/n.txt"
"${APP[@]}" SUPERVISOR_PLAIN_FOLDER=1 SUPERVISOR_UNATTENDED=1 bash "$NS" start "$U" --no-attach >/dev/null 2>&1
UIDIR="$(instance_dir "$(slug_for "$(canon_path "$U")")")"
plain_shadow_present "$UIDIR" && bad "an automation's run was copied" || ok "an automation's run is not copied"
bash "$NS" stop "$U" >/dev/null 2>&1

[ "$fails" -eq 0 ] && { echo "✅ plain-folder review: all passed"; exit 0; } || { echo "❌ plain-folder review: $fails failed"; exit 1; }
