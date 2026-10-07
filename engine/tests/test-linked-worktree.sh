#!/bin/bash
# A night's work in a linked worktree — a copy made with `git worktree add` — is held to the same
# rules as work in the folder itself.
#
# Two things broke there, both because of where a worktree keeps its git. Ignore rules were written
# to `$(git rev-parse --git-dir)/info/exclude`, which in a worktree is `<main>/.git/worktrees/<name>`
# — a file git never reads — or to a literal `.git/info/exclude`, which cannot even be made, because
# `.git` in a worktree is a file. So AUDIT-*.md, REVIEW-DEBT.md and node_modules turned up in the
# copy as the director's work. And MCP answers are kept per folder, so a fresh copy of a project the
# director had already answered for started with every server «not asked about» and refused with 78
# at night, when nobody is there to answer.
#
# Every path here has a space in it: the engine itself lives in "Night Shift/engine", and so do the
# folders the copies are made from.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
COPIES="$(mktemp -d)"; COPIES="$(cd "$COPIES" && pwd -P)"
mkdir -p "$TMP/tmux"
tmux_isolate "$TMP/tmux"
trap 'tmux_cleanup; rm -rf "$TMP" "$COPIES"' EXIT INT TERM
unset TMUX
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE SUPERVISOR_CLAUDE_CMD SUPERVISOR_MCP_GATE
unset SUPERVISOR_APP_ANSWERS SUPERVISOR_RUN_ENV_FROM_APP
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export SUPERVISOR_HANDSHAKE_WAIT=0 SUPERVISOR_NO_SKILL_PICK=1
export SUPERVISOR_STATE_DIR="$TMP/state dir"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home dir"; mkdir -p "$HOME/.claude"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# A `claude` that only writes down that it was launched.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/claude-args"
sleep 30
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

NS="$BIN_DIR/night-shift.sh"
. "$BIN_DIR/supervisor-lib.sh"

REPO="$TMP/Night Shift/project one"
mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main && git config user.name D && git config user.email d@example.com
  printf '%s\n' '{"mcpServers":{"a":{"command":"true"},"b":{"command":"true"}}}' > .mcp.json
  echo x > x && git add . && git commit -qm base ) || { echo "❌ could not make the repository"; exit 1; }
WT="$COPIES/Bulava copies/project one"
mkdir -p "$(dirname "$WT")"
git -C "$REPO" worktree add -q -b night "$WT" 2>/dev/null || { echo "❌ git worktree add failed"; exit 1; }

echo "===== where a worktree's ignore rules have to go ====="
[ -f "$WT/.git" ] && ok ".git in the copy is a file, so .git/info cannot be made there" || bad ".git is not a file"
mkdir -p "$WT/.git/info" 2>/dev/null && bad "mkdir -p .git/info worked in a worktree?" || ok "and mkdir -p .git/info fails"
old="$(git -C "$WT" rev-parse --git-dir)/info/exclude"
mkdir -p "$(dirname "$old")" && echo 'OLD-*.md' >> "$old"
! git -C "$WT" check-ignore -q OLD-x.md \
  && ok "a rule in \$(git rev-parse --git-dir)/info/exclude — the old place — is not read by git" \
  || bad "git read the per-worktree exclude after all"
ex="$(git_exclude_file "$WT")"
[ "$ex" = "$REPO/.git/info/exclude" ] && ok "git_exclude_file names the common exclude: <main>/.git/info/exclude" || bad "git_exclude_file: '$ex'"
[ "$(git_exclude_file "$REPO")" = "$REPO/.git/info/exclude" ] \
  && ok "and in an ordinary repository it is the same .git/info/exclude as before" || bad "repo: '$(git_exclude_file "$REPO")'"
[ "$(cd "$REPO" && git_exclude_file .)" = "$REPO/.git/info/exclude" ] \
  && ok "given «.», it still answers with an absolute path" || bad "relative: '$(cd "$REPO" && git_exclude_file .)'"
git_exclude_file "$TMP/home dir" >/dev/null 2>&1 && bad "a folder with no git got an exclude file" || ok "a folder with no git gets none"

echo "===== the harness's paperwork and machine-made folders stay out of the copy ====="
harness_exclude_in "$WT"
seed_heavy_excludes "$WT"
( cd "$WT" && touch AUDIT-x.md REVIEW-DEBT.md && mkdir -p node_modules/pkg && touch node_modules/pkg/i.js )
git -C "$WT" check-ignore -q AUDIT-x.md && ok "AUDIT-x.md is ignored in the copy" || bad "AUDIT-x.md is not ignored"
git -C "$WT" check-ignore -q REVIEW-DEBT.md && ok "REVIEW-DEBT.md is ignored in the copy" || bad "REVIEW-DEBT.md is not ignored"
git -C "$WT" check-ignore -q node_modules/ && ok "node_modules/ is ignored in the copy" || bad "node_modules/ is not ignored"
[ -z "$(git -C "$WT" status --porcelain --untracked-files=all)" ] \
  && ok "so the copy reads as clean" || bad "the copy is dirty: $(git -C "$WT" status --porcelain --untracked-files=all)"
grep -qxF 'AUDIT-*.md' "$REPO/.git/info/exclude" && ok "the rules are in <main>/.git/info/exclude" || bad "not in the common exclude"
harness_exclude_in "$WT"; seed_heavy_excludes "$WT"
[ "$(grep -cxF 'AUDIT-*.md' "$REPO/.git/info/exclude")" = 1 ] && [ "$(grep -cxF 'node_modules/' "$REPO/.git/info/exclude")" = 1 ] \
  && ok "written once, however often it runs" || bad "duplicated: $(cat "$REPO/.git/info/exclude")"

echo "===== an ordinary repository keeps its own .git/info/exclude ====="
R2="$TMP/Night Shift/plain repo"; mkdir -p "$R2"
( cd "$R2" && git init -q -b main && echo x > x && git add x && git -c user.name=D -c user.email=d@e.x commit -qm base )
harness_exclude_in "$R2"; seed_heavy_excludes "$R2"
grep -qxF 'REVIEW-DEBT.md' "$R2/.git/info/exclude" && grep -qxF 'node_modules/' "$R2/.git/info/exclude" \
  && ok "written into <repo>/.git/info/exclude" || bad "exclude: $(cat "$R2/.git/info/exclude" 2>/dev/null)"
( cd "$R2" && touch AUDIT-y.md && mkdir -p .venv && touch .venv/z )
[ -z "$(git -C "$R2" status --porcelain --untracked-files=all)" ] && ok "and git reads it there" || bad "dirty: $(git -C "$R2" status --porcelain)"

echo "===== files the director chose to leave out of checkpoints, in the copy ====="
rec="$(checkpoint_heavy_file "$WT")"; mkdir -p "$(dirname "$rec")"
printf '%s\n' '{"files":[{"path":"capture one.mov","rule":"/capture one.mov","tracked":false,"size":5}]}' > "$rec"
touch "$WT/capture one.mov"
checkpoint_leave_out "$WT" local >/dev/null && ok "checkpoint_leave_out local went through" || bad "checkpoint_leave_out failed"
git -C "$WT" check-ignore -q "capture one.mov" && ok "and the file is ignored in the copy" || bad "the file is not ignored"

echo "===== MCP answers travel with the copy ====="
mcp_decision_record "$REPO" enable a
mcp_decision_record "$REPO" skip b
[ -z "$(project_mcp_pending "$REPO")" ] && ok "the original has nothing waiting" || bad "the original waits: $(project_mcp_pending "$REPO")"
[ "$(project_mcp_pending "$WT" | tr '\n' ' ')" = "a b " ] && ok "the fresh copy, before carrying, waits on both" || bad "copy: $(project_mcp_pending "$WT")"
out="$(bash "$NS" mcp-carry "$REPO" "$WT" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "mcp-carry exit 0" || bad "mcp-carry exit $rc: $out"
[ -z "$(project_mcp_pending "$WT")" ] && ok "nothing waits in the copy any more" || bad "copy still waits: $(project_mcp_pending "$WT")"
f="$(mcp_decisions_file "$WT")"
[ "$(jq -c '.enabled' "$f" 2>/dev/null)" = '["a"]' ] && [ "$(jq -c '.disabled' "$f" 2>/dev/null)" = '["b"]' ] \
  && ok "the copy's record: a on, b off — the same answers, not merely «decided»" || bad "record: $(cat "$f" 2>/dev/null)"
grep -q "\[mcp-carry\] '$REPO' -> '$WT'" "$SUPERVISOR_STATE_DIR/supervisor.log" && ok "and it is in the log" || bad "not logged"
[ -z "$(git -C "$WT" status --porcelain --untracked-files=all)" ] && [ ! -e "$WT/.claude" ] \
  && ok "nothing was written into the copy" || bad "the copy changed: $(git -C "$WT" status --porcelain)"

echo "===== nothing decided: nothing written ====="
S2="$TMP/Night Shift/undecided"; D2="$COPIES/Bulava copies/undecided"; mkdir -p "$S2" "$D2"
printf '%s\n' '{"mcpServers":{"a":{},"b":{}}}' > "$S2/.mcp.json"
out="$(bash "$NS" mcp-carry "$S2" "$D2" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc: $out"
[ ! -e "$(mcp_decisions_file "$D2")" ] && ok "and no record for the destination" || bad "a record appeared: $(cat "$(mcp_decisions_file "$D2")")"

echo "===== enableAllProjectMcpServers in the original's settings.local.json ====="
S3="$TMP/Night Shift/all on"; D3="$COPIES/Bulava copies/all on"; mkdir -p "$S3/.claude" "$D3"
printf '%s\n' '{"mcpServers":{"a":{},"b":{}}}' > "$S3/.mcp.json"; cp "$S3/.mcp.json" "$D3/.mcp.json"
printf '%s\n' '{"enableAllProjectMcpServers":true}' > "$S3/.claude/settings.local.json"
bash "$NS" mcp-carry "$S3" "$D3" >/dev/null 2>&1 || bad "mcp-carry failed"
f="$(mcp_decisions_file "$D3")"
[ "$(jq -c '.enabled' "$f" 2>/dev/null)" = '["a","b"]' ] && [ "$(jq -c '.disabled // []' "$f" 2>/dev/null)" = '[]' ] \
  && ok "carried as a and b on" || bad "record: $(cat "$f" 2>/dev/null)"
[ -z "$(project_mcp_pending "$D3")" ] && ok "and the copy has nothing waiting" || bad "waits: $(project_mcp_pending "$D3")"

echo "===== «off» anywhere stays off ====="
S4="$TMP/Night Shift/mixed"; D4="$COPIES/Bulava copies/mixed"; mkdir -p "$S4/.claude" "$D4"
printf '%s\n' '{"mcpServers":{"a":{},"b":{}}}' > "$S4/.mcp.json"
printf '%s\n' '{"enableAllProjectMcpServers":true}' > "$S4/.claude/settings.json"
jq -n --arg p "$S4" '{projects: {($p): {disabledMcpjsonServers: ["b"]}}}' > "$HOME/.claude.json"
bash "$NS" mcp-carry "$S4" "$D4" >/dev/null 2>&1 || bad "mcp-carry failed"
f="$(mcp_decisions_file "$D4")"
[ "$(jq -c '.enabled' "$f" 2>/dev/null)" = '["a"]' ] && [ "$(jq -c '.disabled' "$f" 2>/dev/null)" = '["b"]' ] \
  && ok "enabled for all in one scope, off in ~/.claude.json: b is carried as off" || bad "record: $(cat "$f" 2>/dev/null)"
rm -f "$HOME/.claude.json"

echo "===== usage ====="
bash "$NS" mcp-carry "$REPO" >/dev/null 2>&1; [ "$?" = 2 ] && ok "one folder is a usage error (2)" || bad "not a usage error"
bash "$NS" mcp-carry "$REPO" "$TMP/nowhere" >/dev/null 2>&1; [ "$?" = 1 ] && ok "a missing folder is refused (1)" || bad "a missing folder was accepted"
bash "$NS" help 2>/dev/null | grep -q 'mcp-carry <src> <dst>' && ok "the usage line names it" || bad "not in the usage line"

echo "===== a night in the copy starts instead of asking ====="
out="$(bash "$NS" start "$WT" --no-attach 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "the run in the worktree started" || bad "exit $rc: $out"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/claude-args" ] && break; sleep 0.5; done
[ -s "$TMP/claude-args" ] && ok "claude was launched" || bad "claude was never launched"
settings="$(grep -A1 -x -- '--settings' "$TMP/claude-args" 2>/dev/null | tail -1)"
[ "$(jq -c '.enabledMcpjsonServers' "$settings" 2>/dev/null)" = '["a"]' ] \
  && [ "$(jq -c '.disabledMcpjsonServers' "$settings" 2>/dev/null)" = '["b"]' ] \
  && ok "with the carried answers in its settings" || bad "settings: $(cat "$settings" 2>/dev/null)"
bash "$NS" stop "$WT" >/dev/null 2>&1 || true

echo
[ "$fails" = 0 ] && echo "✅ linked worktree: ignore rules land where git reads them, MCP answers travel" || echo "❌ linked worktree: $fails problem(s)"
exit "$fails"
