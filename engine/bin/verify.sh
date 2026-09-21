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

for _tdir in tests engine/tests; do
  ls "$PROJ/$_tdir"/test-*.sh >/dev/null 2>&1 || continue
  if ! should_build '\.sh$|\.bash$|tests/'; then
    skip_build "shell suite ($_tdir)" "bash tests"
    continue
  fi
  ran_any=1
  # Side by side, because a suite that cannot finish inside the step ceiling is a suite whose
  # result nobody ever collects: it comes back as a timeout no matter what the code does, round
  # after round. A shell test that needs the machine to itself is already broken in CI, so this
  # assumes what the engine's own suite guarantees — each test builds its own state directory.
  # SUPERVISOR_TEST_JOBS=1 puts it back in order when a failure needs to be read in sequence.
  run_step "shell suite passes ($_tdir)" "$STEP_TO" bash -c '
    dir='"$_tdir"'
    jobs="${SUPERVISOR_TEST_JOBS:-}"
    if [ -z "$jobs" ]; then
      jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
      [ "$jobs" -gt 8 ] 2>/dev/null && jobs=8
    fi
    case "$jobs" in ""|*[!0-9]*) jobs=4 ;; esac
    [ "$jobs" -lt 1 ] && jobs=1
    out="$(mktemp -d)"; trap "rm -rf "$out"" EXIT
    pids=()
    for t in "$dir"/test-*.sh; do
      ( bash "$t" >/dev/null 2>&1; echo $? > "$out/$(basename "$t").rc" ) &
      pids=(${pids[@]+"${pids[@]}"} "$!")
      if [ "${#pids[@]}" -ge "$jobs" ]; then wait "${pids[0]}" 2>/dev/null; pids=(${pids[@]:1}); fi
    done
    wait
    rc=0
    for t in "$dir"/test-*.sh; do
      [ "$(cat "$out/$(basename "$t").rc" 2>/dev/null || echo 1)" = 0 ] \
        || { echo "FAILED: $t"; rc=1; }
    done
    exit $rc'
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
