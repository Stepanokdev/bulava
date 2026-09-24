#!/bin/bash
set -u
BIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

PROJ="$(canon_path "${1:?usage: verify.sh <project-dir> <session-id> [instance-dir] [base-sha]}")"
SID="${2:-adhoc}"
IDIR_ARG="${3:-}"; BASE_SHA_ARG="${4:-}"
STEP_TO="${SUPERVISOR_VERIFY_STEP_TIMEOUT}"
TOTAL_TO="${SUPERVISOR_VERIFY_TOTAL_TIMEOUT}"
START_TS=$(date +%s)

if [ -n "$IDIR_ARG" ]; then IDIR="$IDIR_ARG"; else IDIR="$(instance_dir "$(slug_for "$PROJ")")"; fi
if [ -d "$IDIR" ]; then EVIDENCE_DIR="$IDIR/evidence/$SID"; else EVIDENCE_DIR="$SUP_STATE/evidence/$SID"; fi
rm -rf "$EVIDENCE_DIR"; mkdir -p "$EVIDENCE_DIR"
if [ -n "$BASE_SHA_ARG" ]; then BASE_SHA="$BASE_SHA_ARG"
else BASE_SHA="$(read_base_sha "$IDIR")"; fi

VPROFILE="$(runspec_get "$IDIR" '.verification_profile')"; : "${VPROFILE:=standard}"

CRIT_JSON=""   # accumulates JSON objects, comma-separated
add_criterion() {  # $1 crit  $2 command  $3 exit_code  $4 artifact  $5 status  $6 note
  local obj; obj="$(jq -n --arg c "$1" --arg cmd "$2" --argjson ec "${3:-0}" \
    --arg art "${4:-}" --arg st "$5" --arg note "${6:-}" \
    '{criterion:$c,command:$cmd,exit_code:$ec,artifact:$art,status:$st,note:$note}')"
  CRIT_JSON="${CRIT_JSON:+$CRIT_JSON,}$obj"
}

redact() {  # mask obvious secrets in a captured log (portable: perl -i)
  local f="$1"; [ -f "$f" ] || return 0
  perl -i -pe 's/(AKIA|ASIA)[A-Z0-9]{8,}/[REDACTED-AWS]/g; s/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED-GH]/g; s/(Bearer\s+)\S{12,}/$1\[REDACTED\]/gi; s/\bsk-[A-Za-z0-9_-]{12,}/[REDACTED-KEY]/g; s/([A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY)[A-Za-z0-9_]*\s*[=:]\s*)\S+/$1\[REDACTED\]/gi;' "$f" 2>/dev/null || true
}

# A criterion written in Ukrainian has no ASCII in it, so this used to return an empty string: the
# log became `.log`, hidden, and the NEXT such criterion overwrote it. The reviewer reads those
# logs — two checks sharing one file means one of them cannot be read at all. When there is nothing
# nameable left, the criterion's own digest names it: stable between runs, distinct per criterion.
slugify(){
  local out
  out="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-60)"
  case "$out" in
    ''|-) out="" ;;
  esac
  if [ "${#out}" -lt 3 ]; then
    out="check-$(printf '%s' "$1" | shasum -a 256 | cut -c1-10)"
  fi
  printf '%s' "$out"
}

budget_left(){ [ $(( $(date +%s) - START_TS )) -lt "$TOTAL_TO" ]; }

run_step() {  # $1 criterion  $2 timeout ; then the command + args
  local crit="$1" to="$2"; shift 2
  local tool="$1" log ec status note=""
  log="$EVIDENCE_DIR/$(slugify "$crit").log"
  if ! budget_left; then
    add_criterion "$crit" "$*" 0 "" inconclusive "skipped — total verify budget exceeded"; return
  fi
  if ! command -v "$tool" >/dev/null 2>&1; then
    add_criterion "$crit" "$*" 127 "" inconclusive "tool not found: $tool"; return
  fi
  # Stdin is closed for every step, and that is not tidiness.
  #
  # The loop below reads the registered checks FROM STDIN. One of them ran `ssh`, which drains
  # stdin when it is not given `-n` — so it swallowed the rest of the file, and every check
  # registered after it was never run and never appeared in the evidence. Not failed, not skipped:
  # absent. A registered check that can vanish without a trace is worse than no check at all,
  # because the report then reads as complete.
  ( cd "$PROJ" && perl -e 'alarm shift; exec @ARGV' "$to" "$@" ) >"$log" 2>&1 </dev/null; ec=$?
  case "$ec" in
    0)   status=pass ;;
    142) status=inconclusive; note="timed out after ${to}s" ;;   # SIGALRM
    *)   status=fail ;;
  esac
  redact "$log"
  add_criterion "$crit" "$*" "$ec" "$log" "$status" "$note"
}

should_build() {  # $1 = ERE of buildable paths
  local re="$1" files
  [ -n "$BASE_SHA" ] && git -C "$PROJ" cat-file -e "$BASE_SHA" 2>/dev/null || return 0
  files="$(git -C "$PROJ" diff "$BASE_SHA" --name-only 2>/dev/null; git -C "$PROJ" ls-files --others --exclude-standard 2>/dev/null)"
  printf '%s\n' "$files" | grep -qiE "$re"
}
skip_build() {  # record a skipped build step (neutral, never blocks)
  add_criterion "$1" "$2" 0 "" skipped "no buildable change since base"
}
has_npm_script(){ jq -e --arg s "$1" '.scripts[$s] // empty' "$PROJ/package.json" >/dev/null 2>&1; }

detect_pm(){
  local pm; pm="$(jq -r '.packageManager // empty' "$PROJ/package.json" 2>/dev/null | sed 's/@.*//')"
  case "$pm" in pnpm|yarn|npm) printf '%s\n' "$pm"; return;; esac
  { [ -f "$PROJ/pnpm-lock.yaml" ] || [ -f "$PROJ/pnpm-workspace.yaml" ]; } && { printf 'pnpm\n'; return; }
  [ -f "$PROJ/yarn.lock" ] && { printf 'yarn\n'; return; }
  printf 'npm\n'
}
is_js_workspace(){ [ -f "$PROJ/pnpm-workspace.yaml" ] || jq -e '.workspaces // empty' "$PROJ/package.json" >/dev/null 2>&1; }
pkg_has_script(){ jq -e --arg s "$2" '.scripts[$s] // empty' "$PROJ/$1/package.json" >/dev/null 2>&1; }
changed_js_pkgs(){
  { [ -n "$BASE_SHA" ] && git -C "$PROJ" diff --name-only "$BASE_SHA" 2>/dev/null; \
    git -C "$PROJ" ls-files --others --exclude-standard 2>/dev/null; } \
  | while IFS= read -r f; do
      [ -n "$f" ] || continue
      local d; d="$(dirname "$f")"
      while [ "$d" != "." ] && [ "$d" != "/" ]; do
        [ -f "$PROJ/$d/package.json" ] && { printf './%s\n' "$d"; break; }
        d="$(dirname "$d")"
      done
    done | sort -u
}

STACKS="$(detect_stacks "$PROJ")"
ran_any=0

if [ "$VPROFILE" = none ]; then
  add_criterion "automated verification" "(profile=none)" 0 "" skipped "verification_profile=none (docs/non-code task)"
fi

if [ "$VPROFILE" != none ] && [ -d "$IDIR" ] && [ -z "$BASE_SHA" ]; then
  add_criterion "automated verification" "(no base_sha)" 0 "" inconclusive "instance run without a base SHA — refusing an unbounded full-tree build"
  SKIP_STACKS=1
fi

if [ "$VPROFILE" != none ] && [ -z "${SKIP_STACKS:-}" ]; then

if echo " $STACKS " | grep -q ' ios-native '; then
  ran_any=1
  if ! should_build '\.swift$|\.xcodeproj|\.xcworkspace|Package\.swift|\.plist$|\.xcassets'; then
    skip_build "app builds" "xcodebuild build"
  elif ! command -v xcodebuild >/dev/null 2>&1; then
    add_criterion "app builds" "xcodebuild build" 127 "" inconclusive "tool not found: xcodebuild"
  else
    scheme="$(cd "$PROJ" && xcodebuild -list -json 2>/dev/null | jq -r '(.project // .workspace) as $c | (($c.schemes) // []) as $all | (($all | map(select(. == ($c.name // ""))) | first) // ($all | map(select(endswith("-Package") | not)) | first) // ($all | first) // empty)' 2>/dev/null)"
    if [ -n "$scheme" ]; then
      settings="$(cd "$PROJ" && xcodebuild -scheme "$scheme" -showBuildSettings 2>/dev/null)"
      sdk="$(printf '%s\n' "$settings" | awk -F' = ' '/[[:space:]]SDKROOT[[:space:]]*=/{print $2; exit}')"
      plats="$(printf '%s\n' "$settings" | awk -F' = ' '/SUPPORTED_PLATFORMS/{print $2; exit}')"
      case "$sdk$plats" in
        *macosx*) dest='platform=macOS' ;;
        *iphoneos*|*iphonesimulator*) dest='generic/platform=iOS Simulator' ;;
        *) dest='platform=macOS' ;;
      esac
      # Where this run's app ends up, for any suite that needs to audit the built bundle rather
      # than the sources. Without it a shell suite comparing app-against-checkout reads whatever
      # older build is lying around and reports a mismatch this run did not cause.
      export BULAVA_APP="$EVIDENCE_DIR/DerivedData/Build/Products/Debug/Bulava.app"
      run_step "app builds ($dest)" "$STEP_TO" xcodebuild build -scheme "$scheme" \
        -destination "$dest" -derivedDataPath "$EVIDENCE_DIR/DerivedData" CODE_SIGNING_ALLOWED=NO
      has_tests="$(cd "$PROJ" && xcodebuild -list -json 2>/dev/null | jq -r '[((.project.targets // .workspace.targets) // [])[] | select(test("(?i)tests?$"))] | length' 2>/dev/null)"
      if [ "${has_tests:-0}" -gt 0 ] && [ "$dest" = 'platform=macOS' ]; then
        run_step "unit tests pass" "$STEP_TO" xcodebuild test -scheme "$scheme" \
          -destination "$dest" -derivedDataPath "$EVIDENCE_DIR/DerivedData" CODE_SIGNING_ALLOWED=NO
      fi
    else
      add_criterion "app builds" "xcodebuild build" 0 "" inconclusive "no scheme found (xcodebuild -list)"
    fi
  fi
  [ -f "$PROJ/.swiftlint.yml" ] && run_step "swiftlint clean" "$STEP_TO" swiftlint
fi

if [ -f "$PROJ/package.json" ]; then
  ran_any=1; export CI=1
  PM="$(detect_pm)"
  case "$PM" in
    pnpm) PM_INSTALL="pnpm install --frozen-lockfile" ;;
    yarn) PM_INSTALL="yarn install --immutable" ;;
    *)    if [ -f "$PROJ/package-lock.json" ]; then PM_INSTALL="npm ci"; else PM_INSTALL="npm install"; fi ;;
  esac
  if should_build '\.(ts|tsx|js|jsx|mjs|cjs|css|scss|sass|less|html|vue|svelte|astro|mdx|json)$'; then
    run_step "dependencies install" "$STEP_TO" $PM_INSTALL
    NODE_PKGS=""; [ "$PM" = pnpm ] && is_js_workspace && NODE_PKGS="$(changed_js_pkgs)"
    if [ -n "$NODE_PKGS" ]; then
      node_scoped=0
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        [ -n "$(cd "$PROJ" && pnpm --filter "$pkg" ls --depth -1 --parseable 2>/dev/null)" ] || continue
        pkg_has_script "$pkg" build && { run_step "web build succeeds ($pkg)" "$STEP_TO" pnpm --filter "$pkg" run build; node_scoped=1; }
        pkg_has_script "$pkg" test  && { run_step "tests pass ($pkg)" "$STEP_TO" pnpm --filter "$pkg" run test; node_scoped=1; }
        pkg_has_script "$pkg" lint  && { run_step "lint clean ($pkg)" "$STEP_TO" pnpm --filter "$pkg" run lint; node_scoped=1; }
      done <<EOF_PKGS
$NODE_PKGS
EOF_PKGS
      [ "$node_scoped" = 1 ] || NODE_PKGS=""   # nothing runnable in changed pkgs ⇒ root scripts
    fi
    if [ -z "$NODE_PKGS" ]; then
      has_npm_script build && run_step "web build succeeds" "$STEP_TO" $PM run build
      has_npm_script test  && run_step "tests pass" "$STEP_TO" $PM run test
      has_npm_script lint  && run_step "lint clean" "$STEP_TO" $PM run lint
    fi
  else
    skip_build "web build succeeds" "$PM run build"
    has_npm_script test && run_step "tests pass" "$STEP_TO" $PM run test
    has_npm_script lint && run_step "lint clean" "$STEP_TO" $PM run lint
  fi
fi

if echo " $STACKS " | grep -q ' backend-go '; then
  ran_any=1
  if should_build '\.go$|go\.mod|go\.sum'; then run_step "go builds" "$STEP_TO" go build ./...
  else skip_build "go builds" "go build ./..."; fi
  run_step "go tests pass" "$STEP_TO" go test ./...
fi

if echo " $STACKS " | grep -q ' backend-python '; then
  ran_any=1
  run_step "python compiles" "$STEP_TO" python3 -m compileall -q .
  command -v pytest >/dev/null 2>&1 && run_step "pytest passes" "$STEP_TO" pytest -q
fi

# ------------------------------------------------------------------------- the shell suites
#
# Two things changed here, and both came out of one afternoon in the log: six review rounds, each
# FAILED by this step, for a change that touched none of the tests that were red.
#
# 1. Only the tests that can see the change run. A test that sources nothing the diff touched
#    cannot fail because of it, and a suite of eighty-odd scripts takes a quarter of an hour that
#    the round then pays for nothing. The selection is by reference: a test is picked when its text
#    names a changed script, a changed function of the shared library, or is itself changed. When
#    the library changed in a way no function name can be read off the diff, or a changed script is
#    named by no test at all, the whole suite runs — a guess that skips a real regression is worse
#    than fifteen minutes.
# 2. A test that is red at the BASE commit is not this change's failure. Every red test is run once
#    more in a throwaway worktree of the base; those red there too are listed and excluded, and the
#    step passes when nothing else is red. That is what "pre-existing" is allowed to mean here —
#    the base showing it — not the worker's word for it.
_shell_changed=""      # files changed since base (tracked + untracked), or "?" when unknown
if [ -n "$BASE_SHA" ] && git -C "$PROJ" cat-file -e "$BASE_SHA" 2>/dev/null; then
  _shell_changed="$( { git -C "$PROJ" diff "$BASE_SHA" --name-only 2>/dev/null;
                       git -C "$PROJ" ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"
else
  _shell_changed="?"
fi
_BASE_WT=""
# Sets _BASE_WT to a detached worktree at BASE_SHA, made once and removed when the verifier exits.
# Called in THIS shell, never in a $(...) — a subshell's EXIT trap would remove the tree the moment
# the path was returned.
base_worktree() {
  [ -n "$_BASE_WT" ] && return 0
  [ -n "$BASE_SHA" ] && git -C "$PROJ" cat-file -e "$BASE_SHA" 2>/dev/null || return 1
  _BASE_WT="$(mktemp -d "${TMPDIR:-/tmp}/ns-verify-base-XXXXXX")/base"
  if git -C "$PROJ" worktree add --detach "$_BASE_WT" "$BASE_SHA" >/dev/null 2>&1; then
    trap 'git -C "$PROJ" worktree remove --force "$_BASE_WT" >/dev/null 2>&1; rm -rf "$(dirname "$_BASE_WT")" 2>/dev/null' EXIT
    return 0
  fi
  rm -rf "$(dirname "$_BASE_WT")" 2>/dev/null; _BASE_WT=""; return 1
}
# Names of functions the diff of a shared library touched, read off git's hunk headers. Empty when
# the diff has hunks whose nearest heading is not a function — then nothing can be said about who
# is affected, and the caller runs everything.
changed_functions() {   # $1 = repo-relative file
  local hunks fns
  hunks="$(git -C "$PROJ" diff -U0 "$BASE_SHA" -- "$1" 2>/dev/null | grep '^@@' || true)"
  [ -n "$hunks" ] || { printf ''; return 0; }
  # A changed line at column zero is outside every function body — a top-level statement, an export,
  # a new definition — and git's hunk heading would still name whatever function came before it.
  if git -C "$PROJ" diff -U0 "$BASE_SHA" -- "$1" 2>/dev/null | grep -E '^[-+][^-+ #}]' | grep -qvE '^[-+][A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{?[[:space:]]*$'; then
    printf ''; return 0
  fi
  fns="$(printf '%s\n' "$hunks" | sed -E 's/^@@[^@]*@@ *//' | grep -oE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' | tr -d ' ()' | sort -u)"
  # Every hunk must have named a function, or the selection is not safe.
  [ "$(printf '%s\n' "$hunks" | grep -c .)" -eq "$(printf '%s\n' "$hunks" | sed -E 's/^@@[^@]*@@ *//' | grep -cE '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)')" ] || { printf ''; return 0; }
  printf '%s' "$fns"
}
select_shell_tests() {   # $1 = tests dir (repo-relative)  $2 = code root the tests cover ; prints test paths, one per line
  local tdir="$1" root="$2" all t f base fn hits sel="" why=""
  all="$(ls "$PROJ/$tdir"/test-*.sh 2>/dev/null)"
  [ -n "$all" ] || return 0
  if [ "${SUPERVISOR_TEST_SELECT:-1}" != 1 ] || [ "$_shell_changed" = "?" ]; then
    printf '%s' "all tests (selection off or no base)" > "$SHELL_SELECT_NOTE_FILE"; printf '%s\n' "$all"; return 0
  fi
  # Anything in the code root that is not a test: scripts the tests exercise.
  local code; code="$(printf '%s\n' "$_shell_changed" | grep -E "^${root}" | grep -vE "^${tdir}/" || true)"
  local changed_tests; changed_tests="$(printf '%s\n' "$_shell_changed" | grep -E "^${tdir}/test-.*\.sh$" || true)"
  if [ -z "$code" ] && [ -z "$changed_tests" ]; then
    printf '%s' "nothing under $root changed" > "$SHELL_SELECT_NOTE_FILE"; return 0
  fi
  while IFS= read -r t; do [ -n "$t" ] && sel="$sel
$PROJ/$t"; done <<EOF_CT
$changed_tests
EOF_CT
  # The suite's own plumbing changed: everything runs.
  if printf '%s\n' "$code" | grep -qE "^${tdir}/(run-all|lib-[^/]*)\.sh$|^${root}supervisor/config\.sh$"; then
    printf '%s' "all tests (test plumbing or config changed)" > "$SHELL_SELECT_NOTE_FILE"; printf '%s\n' "$all"; return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "${tdir}"/*) continue ;; esac
    base="$(basename "$f")"
    case "$base" in
      supervisor-lib.sh|*-lib.sh)
        fn="$(changed_functions "$f")"
        if [ -z "$fn" ]; then printf '%s' "all tests ($base changed outside named functions)" > "$SHELL_SELECT_NOTE_FILE"; printf '%s\n' "$all"; return 0; fi
        # Tests that name the function — and tests that name a script which calls it, because a
        # test rarely calls a library function by name; it runs the script that does.
        hits=""
        while IFS= read -r n; do
          [ -n "$n" ] || continue
          hits="$hits
$(grep -lF -- "$n" $all 2>/dev/null)"
          for caller in $(grep -lF -- "$n" "$PROJ/${root}bin"/*.sh "$PROJ/${root}hooks"/*.sh 2>/dev/null); do
            [ "$(basename "$caller")" = "$base" ] && continue
            hits="$hits
$(grep -lF -- "$(basename "$caller")" $all 2>/dev/null)"
          done
        done <<EOF_FN
$fn
EOF_FN
        why="$why $base{$(printf '%s' "$fn" | tr '\n' ',')}" ;;
      *.sh|*.py|*.json|*.md)
        hits="$(grep -lF -- "$base" $all 2>/dev/null || true)"
        # A script no test names is a script whose regressions the suite cannot catch selectively.
        case "$f" in
          *bin/*.sh|*hooks/*.sh) [ -n "$hits" ] || { printf '%s' "all tests (no test names $base)" > "$SHELL_SELECT_NOTE_FILE"; printf '%s\n' "$all"; return 0; } ;;
        esac
        why="$why $base" ;;
      *) hits="" ;;
    esac
    sel="$sel
$hits"
  done <<EOF_CODE
$code
EOF_CODE
  sel="$(printf '%s\n' "$sel" | grep . | sort -u)"
  if [ -z "$sel" ]; then printf '%s' "no test references the change (${why# })" > "$SHELL_SELECT_NOTE_FILE"; return 0; fi
  printf '%s' "$(printf '%s\n' "$sel" | grep -c .) of $(printf '%s\n' "$all" | grep -c .) selected by reference to:${why}" > "$SHELL_SELECT_NOTE_FILE"
  printf '%s\n' "$sel"
}
. "$BIN_DIR/verify-suite-lib.sh"

for _tdir in tests engine/tests; do
  ls "$PROJ/$_tdir"/test-*.sh >/dev/null 2>&1 || continue
  case "$_tdir" in engine/tests) _root="engine/" ;; *) _root="" ;; esac
  if ! budget_left; then
    add_criterion "shell suite ($_tdir)" "bash tests" 0 "" inconclusive "skipped — total verify budget exceeded"; continue
  fi
  SHELL_SELECT_NOTE_FILE="$EVIDENCE_DIR/.select-note"; : > "$SHELL_SELECT_NOTE_FILE"
  _sel="$(select_shell_tests "$_tdir" "$_root" | sed "s#^$PROJ/##")"
  SHELL_SELECT_NOTE="$(cat "$SHELL_SELECT_NOTE_FILE" 2>/dev/null)"
  if [ -z "$_sel" ]; then
    add_criterion "shell suite ($_tdir)" "bash tests" 0 "" skipped "${SHELL_SELECT_NOTE:-no buildable change since base}"
    continue
  fi
  ran_any=1
  # The suite gets whatever is left of the WHOLE verifier's budget, not the per-step ceiling: for a
  # shell project the suite IS the verification, and a suite that cannot finish inside its ceiling
  # is a suite whose result nobody ever collects.
  SH_TO="$STEP_TO"; _sh_left=$(( TOTAL_TO - ( $(date +%s) - START_TS ) - 10 ))
  [ "$_sh_left" -gt "$SH_TO" ] && SH_TO="$_sh_left"
  # `test-export-suite.sh` publishes the tree and runs the whole suite again inside the copy; what
  # it proves is proved outside a review round, by tests/run-all.sh and the publishing check.
  _rcdir="$EVIDENCE_DIR/shell-rc-$(printf '%s' "$_tdir" | tr '/' '-')"
  _log="$EVIDENCE_DIR/$(slugify "shell suite ($_tdir)").log"
  ( export SUPERVISOR_TEST_SKIP="${SUPERVISOR_TEST_SKIP:-} test-export-suite.sh"
    printf '%s\n' "$_sel" | perl -e 'alarm shift; exec @ARGV' "$SH_TO" bash -c '
      . "$0"; run_shell_suite "$1" "$2" "$3"' "$BIN_DIR/verify-suite-lib.sh" "$PROJ" "$_tdir" "$_rcdir" ) </dev/null >"$_log.driver" 2>&1; _ec=$?
  _failed=""; _absent=""
  for _rc in "$_rcdir"/*.rc; do
    [ -f "$_rc" ] || continue
    _tn="$(basename "$_rc" .rc)"
    case "$(cat "$_rc" 2>/dev/null)" in
      0) ;;
      absent) _absent="$_absent $_tn" ;;
      *) _failed="$_failed $_tn" ;;
    esac
  done
  _selected_n="$(printf '%s\n' "$_sel" | grep -c .)"
  _ran_n="$(ls "$_rcdir"/*.rc 2>/dev/null | wc -l | tr -d ' ')"
  { echo "selection: ${SHELL_SELECT_NOTE:-all}"; echo "ran: $_ran_n of $_selected_n selected"
    for _tn in $_failed; do echo "FAILED: $_tdir/$_tn"; echo "----- $_tn -----"; tail -n 60 "$_rcdir/$_tn.log" 2>/dev/null; done
    [ "$_ec" = 142 ] && echo "TIMED OUT after ${SH_TO}s — results above are those that finished"
  } > "$_log" 2>/dev/null
  redact "$_log"
  _note="${SHELL_SELECT_NOTE:-all tests}"
  if [ "$_ec" = 142 ] && [ "$_ran_n" -lt "$_selected_n" ]; then
    add_criterion "shell suite ($_tdir)" "bash tests" 142 "$_log" inconclusive "timed out after ${SH_TO}s; $_note"
    continue
  fi
  if [ -z "$_failed" ]; then
    add_criterion "shell suite passes ($_tdir)" "bash tests" 0 "$_log" pass "$_note"
    continue
  fi
  # Red. Which of these were red before this change?
  _pre=""; _new=""
  if [ "${SUPERVISOR_VERIFY_BASELINE:-1}" = 1 ] && budget_left && base_worktree; then
    _wt="$_BASE_WT"
    _suite_key="$(printf '%s' "$_tdir" | tr '/' '-')"
    _cache="$IDIR/verify-baseline/$BASE_SHA/$_suite_key"; mkdir -p "$_cache" 2>/dev/null || _cache="$EVIDENCE_DIR/baseline-$_suite_key"
    mkdir -p "$_cache"
    _todo=""
    for _tn in $_failed; do [ -f "$_cache/$_tn.rc" ] || _todo="$_todo
$_tdir/$_tn"; done
    if [ -n "$(printf '%s' "$_todo" | grep .)" ]; then
      _bl_to=$(( TOTAL_TO - ( $(date +%s) - START_TS ) - 10 )); [ "$_bl_to" -lt 60 ] && _bl_to=60
      ( export SUPERVISOR_TEST_SKIP="${SUPERVISOR_TEST_SKIP:-} test-export-suite.sh"
        printf '%s\n' "$_todo" | perl -e 'alarm shift; exec @ARGV' "$_bl_to" bash -c '
          . "$0"; run_shell_suite "$1" "$2" "$3"' "$BIN_DIR/verify-suite-lib.sh" "$_wt" "$_tdir" "$_cache" ) </dev/null >>"$_log.driver" 2>&1 || true
    fi
    for _tn in $_failed; do
      case "$(cat "$_cache/$_tn.rc" 2>/dev/null)" in
        ""|0|absent) _new="$_new $_tn" ;;   # green at base, not there at base, or never measured: this change's
        *) _pre="$_pre $_tn" ;;             # red at base too
      esac
    done
  else
    _new="$_failed"
  fi
  { echo; echo "baseline ($BASE_SHA): red at base too →${_pre:- none}; new →${_new:- none}"; } >> "$_log"
  if [ -n "$_new" ]; then
    add_criterion "shell suite passes ($_tdir)" "bash tests" 1 "$_log" fail "new failures:${_new}${_pre:+; red at base too (not counted):$_pre}; $_note"
  else
    add_criterion "shell suite: no new failures vs base ($_tdir)" "bash tests" 0 "$_log" pass "red at base too, excluded:${_pre}; $_note"
  fi
done

if [ "$ran_any" = 0 ]; then
  PV_TO="$STEP_TO"; _left=$(( TOTAL_TO - ( $(date +%s) - START_TS ) - 10 ))
  [ "$_left" -gt "$PV_TO" ] && PV_TO="$_left"
  if [ -x "$PROJ/verify.sh" ] && [ -f "$PROJ/verify.sh" ] && [ "$PROJ" != "$BIN_DIR" ] \
     && [ "${SUPERVISOR_PROJECT_VERIFY:-1}" = 1 ]; then
    run_step "project verify.sh" "$PV_TO" env ./verify.sh
  elif [ -f "$PROJ/Makefile" ] && grep -qE '^verify:' "$PROJ/Makefile"; then
    run_step "make verify" "$PV_TO" make verify
  elif [ -f "$PROJ/Makefile" ] && grep -qE '^test:' "$PROJ/Makefile"; then
    run_step "make test" "$STEP_TO" make test
  elif command -v pytest >/dev/null 2>&1 && ls "$PROJ"/test_*.py "$PROJ"/tests/*.py >/dev/null 2>&1; then
    run_step "pytest passes" "$STEP_TO" pytest -q
  else
    add_criterion "automated verification" "(none available)" 0 "" inconclusive "no automated verification available for this stack"
  fi
fi

fi   # end: VPROFILE != none — all stack build/test steps skipped for docs/non-code tasks

CHECKS_FILE="$IDIR/checks.jsonl"
if [ -f "$CHECKS_FILE" ]; then
  # Read the whole file FIRST, then run. Closing each step's stdin is the real fix, but a loop
  # whose input survives only as long as every command it invokes happens to be well-behaved is
  # one badly-chosen tool away from silently dropping work again.
  _lines=()
  # `|| [ -n "$_l" ]` because a file whose last line has no newline would otherwise lose it — and
  # the last line is the check registered most recently, which is invariably the one being asked
  # about. add-check writes a newline today; a reader that depends on that is a reader waiting to
  # drop the newest check the day something else appends to this file.
  while IFS= read -r _l || [ -n "$_l" ]; do _lines+=("$_l"); done < "$CHECKS_FILE"
  _n=0
  for _line in ${_lines[@]+"${_lines[@]}"}; do
    [ -n "$_line" ] || continue
    _n=$((_n + 1)); [ "$_n" -le 10 ] || break        # same cap add-check enforces
    _crit="$(printf '%s' "$_line" | jq -r '.criterion // empty' 2>/dev/null)"
    [ -n "$_crit" ] || continue
    _argv=()
    while IFS= read -r -d '' _a; do _argv+=("$_a"); done < <(
      printf '%s' "$_line" | jq -j '.argv[]? | . + "\u0000"' 2>/dev/null)
    [ "${#_argv[@]}" -gt 0 ] || continue
    run_step "$_crit" "$STEP_TO" "${_argv[@]}"
  done
fi

EVIDENCE_JSON="$EVIDENCE_DIR/evidence.json"
HEAD_SHA="$(resolve_base_sha "$PROJ")"
TREE_DIGEST="$(work_tree_digest "$PROJ" 2>/dev/null || echo "")"
jq -n --argjson crit "[${CRIT_JSON}]" --arg proj "$PROJ" --arg sid "$SID" --arg base "$BASE_SHA" --arg stacks "$STACKS" --arg vprofile "$VPROFILE" --arg head "$HEAD_SHA" --arg tree "$TREE_DIGEST" '
  {project_dir:$proj, session_id:$sid, base_sha:$base, head_sha:$head, work_tree_digest:$tree, stacks:($stacks|split(" ")|map(select(.!=""))),
   verification_profile:$vprofile,
   criteria:$crit,
   overall_status: (
     # "pass" ONLY when at least one criterion actually passed and nothing failed/was inconclusive.
     # An empty or all-"skipped" set is NOT a pass — it means nothing was verified → inconclusive,
     # so the gate records review debt instead of silently accepting unverified work.
     if   ($crit|map(select(.status=="fail"))|length)         > 0 then "fail"
     elif ($crit|map(select(.status=="inconclusive"))|length) > 0 then "inconclusive"
     elif ($crit|map(select(.status=="pass"))|length)         > 0 then "pass"
     else "inconclusive" end)
  }' > "$EVIDENCE_JSON" 2>/dev/null || { echo "$EVIDENCE_DIR/evidence.json"; exit 1; }

echo "$EVIDENCE_JSON"
