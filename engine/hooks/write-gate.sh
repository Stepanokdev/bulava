#!/bin/bash
set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$HOOK_DIR/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

[ "${SUPERVISOR_SCOPE_GATE:-1}" = 1 ] || exit 0     # master kill-switch (config.sh)

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // "."')
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$file_path" ] || [ -n "$command" ] || exit 0   # nothing to gate

scope="$(hook_scope "$cwd" write-gate once)"
[ "${scope%%:*}" = "instance" ] || exit 0            # unsupervised / legacy / day-mode → allow
IDIR="$(instance_dir "${scope#instance:}")"
PROJ="$(cat "$IDIR/project" 2>/dev/null || echo "$cwd")"

abs="$(abs_target "$cwd" "$file_path")"              # #3: safe for not-yet-existing paths
IDIR_C="$(cd "$IDIR" 2>/dev/null && pwd -P || echo "$IDIR")"
SUP_C="$(cd "$SUP_STATE" 2>/dev/null && pwd -P || echo "$SUP_STATE")"

deny() {   # $1 = reason
  jq -n --arg r "🌙 write-gate: $1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    },
    suppressOutput: true
  }'
  exit 0
}

# ------------------------------------------------- the control plane, and the one door left open
#
# Every decision this engine records lives in the run's folder, and writes there are already denied
# further down — for Edit, Write and NotebookEdit, which is where this gate was wired. Bash was not,
# and Bash is a file editor with extra steps. One `printf > codex-fallback.json` and the worker has
# granted itself permission to finish a night without the reviewer, with the journal recording the
# director as the source. That is not a threat model about an attacker; it is the ordinary shape of
# a model that reads "the run is parked for a decision" and helpfully unparks it.
#
# So the same fence covers the same files whichever tool reaches for them. Reading stays allowed —
# a worker that cannot see its own state cannot report on it either — and the engine's own handles
# are named through, because they are the sanctioned way to touch this state and do their own
# checking. Matching on the command text is coarse and a name built at runtime would slip past it;
# the honest thing to do about a door is still to shut it rather than describe it in a comment.
if [ -n "$command" ]; then
  # A server's own line: credentials are not read and nothing is published from inside a run
  # (`server_bash_refusal`). Off a server this prints nothing and the gate goes on as it always has.
  _srv="$(server_bash_refusal "$command")"
  [ -n "$_srv" ] && deny "$_srv"
  # Where the run's state lives, as a command would have to spell it to reach it: the folder's own
  # path either way round, the state directory, or the variables the worker is handed for them.
  _reaches_state=0
  case "$command" in
    *"$IDIR"*|*"$IDIR_C"*|*"$SUP_STATE"*|*"$SUP_C"*|*.claude/supervisor*|*supervisor/instances*|\
    *'$IDIR'*|*'${IDIR'*|*SUP_STATE*|*SUPERVISOR_STATE_DIR*) _reaches_state=1 ;;
  esac
  # Distinctive names — but only in a command that reaches into that state. The name alone used to
  # be enough, and the engine then refused to be worked on from its own repository: a script that
  # edited a TEST about `codex-owed.json` was denied as though it were forging one, and a pure
  # `grep -rln` for the same name was refused too. Nothing in a product repository IS one of these
  # files; plenty of the engine's own code and tests talk about them.
  _touches_control=0
  if [ "$_reaches_state" = 1 ]; then
    case "$command" in
      *codex-decision-answer.json*|*codex-fallback.json*|*codex-decision.json*|*codex-owed.json*|\
      *codex-away.json*|*codex-gaps.jsonl*|\
      *consult-unanswered.jsonl*|*paused-for-limit.json*|*review-pending*|*review-off*|\
      *ask-user.json*|*resume-refused*|*decision-key.pem*|\
      *writable-dirs*|*writable-directories*) _touches_control=1 ;;
    esac
  fi
  # And the ones whose names are ordinary. `answer.json` and `outcome.json` could plausibly belong
  # to the repository being worked on, so for these the command has to be reaching into the run's
  # own folder before it counts as touching control state at all.
  # `plain-folder` and the run's saved choices (`run-env`) are among them: a run that wrote either
  # could call itself a job with no git, whose word the gate takes about how it ended.
  case "$command" in
    *answer.json*|*outcome.json*|*plain-folder*|*run-env*)
      [ "$_reaches_state" = 1 ] && _touches_control=1 ;;
  esac
  # Stderr goes to /dev/null in half the reads this engine's own handles make, and `2>/dev/null`
  # contains a `>`. Matching on that raw would have denied `jq -r .id "$IDIR/codex-decision.json"
  # 2>/dev/null` — a read, refused for looking like a write. Only the stderr forms are dropped.
  #
  # `&>` is NOT dropped, and that was a real hole: it redirects BOTH streams, so it writes the
  # file, and stripping it alongside `2>` took the only evidence of a write out of the probe.
  # `printf x &>"$IDIR/codex-fallback.json"` walked straight through.
  #
  # `echo` and `printf` are deliberately absent below: on their own they write nothing, and the `>`
  # that makes them dangerous is already caught. Interpreters are there, because `python -c
  # "open(f,'w')"` modifies with no redirection at all — at the price of refusing a read written
  # the same way, which costs one retry with `cat`.
  _probe="$(printf '%s' "$command" | sed -e 's/2>>[^ ]*//g' -e 's/2>[^ ]*//g')"
  #
  # The verbs are matched as words. As substrings they caught `grep -rln` as `ln ` and `add ` as
  # `dd ` — reads refused for containing the letters of a write.
  _modifies=0
  case "$_probe" in
    *">"*|*truncate*|*"sed -i"*|*python*|*perl*|*ruby*|*node*) _modifies=1 ;;
  esac
  printf '%s' "$_probe" \
    | grep -qE '(^|[[:space:];&|(`])(tee|rm|mv|cp|touch|ln|install|dd|chmod)([[:space:]]|$)' && _modifies=1
  # There is deliberately no "but this command mentions report-finding, so let it through" clause.
  # It was written and then removed: naming the sanctioned handles as an exemption turns them into
  # a password — `echo x > $IDIR/codex-fallback.json # report-finding` walks straight past it. They
  # need no exemption anyway. The handles write `findings.jsonl`, `checks.jsonl` and `outcome.json`
  # through their own code, none of which is a redirection or a mutating verb in the command line
  # that invokes them, so they never reach this branch in the first place.
  if [ "$_touches_control" = 1 ] && [ "$_modifies" = 1 ]; then
    deny "керуючий стан прогону не редагується з Bash — рішення про заміну Codex ухвалює директор у Bulava, а не воркер записом файлу. Читати ці файли можна, писати — через $IDIR/report-finding, report-outcome та інші рукоятки рушія"
  fi
  exit 0     # every other shell command is none of this gate's business
fi

broad_fence() {
  case "$abs/" in "$PROJ"/*) exit 0 ;; esac
  # The product's other folders that the director let this chat change. Without this the policy he
  # set in the app said "can change" and the gate said no: 13 Oct a dashboard in the product's second
  # folder could not be edited. The list is the app's, copied into the run's folder at launch, where
  # the worker cannot add to it; a folder he gave only for reading is never on it.
  if [ -s "$IDIR/writable-dirs" ]; then
    local _w
    while IFS= read -r _w || [ -n "$_w" ]; do
      [ -n "$_w" ] || continue
      case "$abs/" in "${_w%/}"/*) exit 0 ;; esac
    done < "$IDIR/writable-dirs"
  fi
  # Claude Code's own memory for THIS project — the folder it is told to keep notes in, named after
  # the project's path with every other character as `-`. Refusing it made the worker write its
  # memory through a heredoc instead, which no gate looks at: the deny protected nothing and only
  # forced the detour. Another project's memory stays outside.
  local _mem
  _mem="$HOME/.claude/projects/$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')/memory"
  case "$abs/" in "$_mem"/*) exit 0 ;; esac
  case "$abs/" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) exit 0 ;; esac
  [ -n "${TMPDIR:-}" ] && case "$abs/" in "${TMPDIR%/}"/*) exit 0 ;; esac
  deny "запис поза межами репозиторію задачі ($abs) — по інших файлах передай через report-finding, не редагуй напряму"
}

case "$abs/" in
  "$SUP_C"/reports/*) : ;;
  "$IDIR_C"/*|"$SUP_C"/*) deny "заборонено писати в керуючий стан ($IDIR)" ;;
esac

ENGINE_ROOT="$(cd "$HOOK_DIR/.." 2>/dev/null && pwd -P || echo "$HOOK_DIR/..")"
# The engine is fenced because a worker inside SOMEBODY ELSE's project has no business editing the
# tool that supervises it: a run in a client's repository that rewrites review-gate.sh has
# disabled its own reviewer.
#
# That reasoning inverts when the engine IS part of the task repository. Bulava ships it as
# `<repo>/engine`, so ENGINE_ROOT ("…/Night Shift/engine") never EQUALLED PROJ ("…/Night Shift") —
# the old `!=` was true for every path, always, and the engine became unmaintainable from inside
# its own product's repository. The question is not "are they the same directory" but "does the
# engine live in the repository this run is allowed to change".
engine_belongs_to_project=0
[ "$ENGINE_ROOT" = "$PROJ" ] && engine_belongs_to_project=1
case "$ENGINE_ROOT/" in "$PROJ"/*) engine_belongs_to_project=1 ;; esac
if [ "$engine_belongs_to_project" = 0 ]; then
  case "$abs/" in "$ENGINE_ROOT"/*) deny "заборонено писати в сам рушій ($ENGINE_ROOT) — він не належить репозиторію задачі" ;; esac
fi

base="$(basename "$abs")"
case "$base" in
  AUDIT-*.md|REVIEW-DEBT.md|REVIEW-DEBT-ARCHIVE.md|BLOCKED.md|PLAN.md|MANAGER-PLAN.md|\
  IMPLEMENTATION-BRIEF.md|FOREMAN-RESEARCH.md)
    deny "журнал сесії живе в теці прогону (\$IDIR), не в репозиторії ($base)" ;;
esac
if [ "${SUPERVISOR_BLOCK_DECISIONS:-0}" = 1 ]; then
  case "$base" in DECISIONS.md) deny "рішення пиши через канал знахідок, не в DECISIONS.md" ;; esac
fi

runspec_present "$IDIR" || broad_fence
mode="$(runspec_mode "$IDIR")"
[ "$mode" = broad ] && broad_fence

if [ "$mode" = audit ]; then
  case "$abs/" in
    "$PROJ"/*) deny "режим audit: тільки знахідки, без змін коду в репозиторії" ;;
    *)         broad_fence ;;                         # out-of-repo: temp scratch OK, else deny
  esac
fi

case "$abs/" in
  "$PROJ"/*) rel="${abs#$PROJ/}" ;;
  *)         deny "поза межами репозиторію задачі: $abs" ;;
esac
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  path_matches_glob "$rel" "$glob" && exit 0          # allowed
done < <(runspec_write_paths "$IDIR")

deny "поза дозволеними write_paths RunSpec: $rel — знахідку по інших файлах передай через канал знахідок (\$IDIR/report-finding або report-finding.sh), не редагуй їх"
