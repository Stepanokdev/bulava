#!/bin/bash
# The reviewer sees what a person sees (bin/lib/review-eyes.sh, bin/show-reviewer.sh):
#   • show-reviewer records a frame, replaces its caption, refuses what is not a frame or a clip
#   • the gate attaches shown frames with -i and puts the prompt after `--` (or -i eats it)
#   • the prompt names each frame with its caption and says how to judge by it
#   • and to look past the criteria for what is plainly broken; in a long project that reopens
#     work even when an earlier, accepted piece made it
#   • a clip arrives as frames taken from it
#   • an image the change added is attached without being shown
#   • visual work with no frames is told so; frames are a tool, not a condition of acceptance
#   • visual work gets the reviewer's own browser with look-only tools; =0 takes it away
#   • work that is not visual gets none of this
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUPERVISOR_STATE_DIR="$(mktemp -d)"
. "$ROOT/bin/supervisor-lib.sh"
GATE="$ROOT/hooks/review-gate.sh"
export SUPERVISOR_CODEX_USAGE_CMD="/usr/bin/true"
export CODEX_SESSIONS_DIR="$(mktemp -d)"
RID="eyes-test-run-id"

pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

# Fake codex: records its argv one per line, answers a review with PASS.
FAKE="$(mktemp -d)"; ARGV="$FAKE/argv"
cat > "$FAKE/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
if echo "$*" | grep -q "HANDOFF | BLOCKED"; then
  : > "$ARGV"; for a in "$@"; do printf '%s\n' "$a" >> "$ARGV"; done
  echo "STATE: COMPLETE"; echo "VERDICT: PASS"; exit 0
fi
echo "VERDICT: PASS"
EOF
# The browser is offered only where npx exists; the test does not depend on this machine's.
printf '#!/bin/bash\nexit 0\n' > "$FAKE/npx"
chmod +x "$FAKE/codex" "$FAKE/npx"
export ARGV
TR="$(mktemp)"; printf '%s\n' '{"message":{"role":"assistant","content":[{"type":"text","text":"готово, гра на http://127.0.0.1:4173"}]}}' > "$TR"

REPOS=()
cleanup(){ rm -rf "$SUPERVISOR_STATE_DIR" "$FAKE" "$TR" "$CODEX_SESSIONS_DIR" ${REPOS[@]+"${REPOS[@]}"}; }
trap cleanup EXIT

png(){ printf '\x89PNG\r\n\x1a\nfake-frame-%s' "$RANDOM" > "$1"; }
mkcase(){
  RID="eyes-run-$RANDOM$RANDOM"     # one run per case: a run id names exactly one instance
  PROJ="$(mktemp -d)"; REPOS+=("$PROJ")
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir src && echo base > src/app.ts && git add -A && git commit -qm init >/dev/null )
  IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
  printf '%s\n' "$(canon_path "$PROJ")" > "$IDIR/project"
  printf '%s\n' "$RID" > "$IDIR/run-id"
  printf '%s\n' "$(git -C "$PROJ" rev-parse HEAD)" > "$IDIR/base-sha"
  rm -f "$SUPERVISOR_STATE_DIR"/rounds-* "$SUPERVISOR_STATE_DIR"/remediations-* 2>/dev/null || true
  echo "change $RANDOM" >> "$PROJ/src/app.ts"
}
visual(){ printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**","evidence/**"],"surface":{"visual":true}}' > "$IDIR/runspec.json"; }
plain(){ printf '%s' '{"schema":1,"mode":"patch","write_paths":["src/**","evidence/**"]}' > "$IDIR/runspec.json"; }
show(){ ( cd "$PROJ" && ORCHESTRATOR_RUN_ID="$RID" bash "$ROOT/bin/show-reviewer.sh" "$@" ); }
rungate(){
  rm -f "$ARGV"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false}' "$1" "$TR" "$PROJ" \
    | ORCHESTRATOR_RUN_ID="$RID" SUPERVISOR_VERIFIER_ENABLED=0 PATH="$FAKE:$PATH" "$GATE" >/dev/null 2>&1
}
argv_has(){ grep -qxF -- "$1" "$ARGV" 2>/dev/null; }
# The value right after a flag, every time it appears.
after(){ awk -v f="$1" 'p{print; p=0} $0==f{p=1}' "$ARGV" 2>/dev/null; }
prompt(){ awk 'p{print} $0=="--"{p=1}' "$ARGV" 2>/dev/null; }

echo "===== show-reviewer records, replaces, refuses ====="
mkcase; visual
mkdir -p "$PROJ/evidence"; png "$PROJ/evidence/fp.png"; png "$PROJ/evidence/tp.png"
show evidence/fp.png "1. рука тримає бластер" >/dev/null
show evidence/fp.png "1. рука тримає бластер, ствол у приціл" >/dev/null
check "one entry per file"               '[ "$(grep -c . "$IDIR/review-frames.jsonl")" = 1 ]'
check "the newer caption wins"           'jq -r .caption "$IDIR/review-frames.jsonl" | grep -q "ствол у приціл"'
check "stored as an absolute path"       'jq -r .path "$IDIR/review-frames.jsonl" | grep -q "^/"'
echo "notes" > "$PROJ/evidence/notes.txt"
check "a text file is refused"           '! show evidence/notes.txt "x" >/dev/null 2>&1'
check "a missing file is refused"        '! show evidence/none.png "x" >/dev/null 2>&1'
show evidence/tp.png "3. від третьої особи" >/dev/null
check "--list names what was shown"      'show --list | grep -q "від третьої особи"'

echo "===== the gate attaches them and the prompt survives -i ====="
( cd "$PROJ" && git add -A && git commit -qm work )
rungate s-eyes-1
check "the reviewer was called"          '[ -s "$ARGV" ]'
check "the first frame is attached"      'after -i | grep -q "/evidence/fp.png$"'
check "the second frame is attached"     'after -i | grep -q "/evidence/tp.png$"'
check "the prompt comes after --"        'argv_has -- && prompt | grep -q "HANDOFF | BLOCKED"'
check "nothing after -i is the prompt"   '! after -i | grep -q "HANDOFF"'
check "the prompt lists the frames"      'prompt | grep -q "FRAMES ATTACHED TO THIS MESSAGE"'
check "with their captions"              'prompt | grep -q "ствол у приціл"'
check "and how to judge by them"         'prompt | grep -q "Use these frames to judge what a person sees"'
check "and to look past the criteria"    'prompt | grep -q "LOOK PAST THE CRITERIA FIRST"'
check "no pieces: no piece clause"       '! prompt | grep -q "one piece of a long project"'
check "a frame shown is not attached twice" '[ "$(after -i | grep -c "/evidence/fp.png$")" = 1 ]'

echo "===== visual work gets a browser of the reviewer's own ====="
check "the browser server is configured" 'after -c | grep -q "^mcp_servers.review_browser.command="'
check "headless and isolated"            'after -c | grep "^mcp_servers.review_browser.args=" | grep -q "\"--headless\",\"--isolated\""'
check "only look-only tools are offered" 'after -c | grep "^mcp_servers.review_browser.enabled_tools=" | grep -q "take_screenshot"'
check "no script evaluation among them"  '! after -c | grep "^mcp_servers.review_browser.enabled_tools=" | grep -q "evaluate_script"'
check "each offered tool is approved"    'after -c | grep -q "^mcp_servers.review_browser.tools.click.approval_mode=\"approve\"$"'
check "the prompt tells it to look"      'prompt | grep -q "YOUR OWN BROWSER"'
mkcase; visual; mkdir -p "$PROJ/evidence"; png "$PROJ/evidence/fp.png"
show evidence/fp.png "1. рука тримає бластер" >/dev/null
SUPERVISOR_REVIEW_BROWSER=0 rungate s-eyes-2
check "=0: the reviewer was called"      '[ -s "$ARGV" ]'
check "=0: no browser"                   '! after -c | grep -q review_browser'
check "=0: frames still attached"        'after -i | grep -q "/evidence/fp.png$"'

echo "===== a clip arrives as frames ====="
if command -v ffmpeg >/dev/null 2>&1; then
  mkcase; visual; mkdir -p "$PROJ/evidence"
  ffmpeg -nostdin -loglevel error -f lavfi -i testsrc=duration=3:size=320x240:rate=10 -pix_fmt yuv420p "$PROJ/evidence/cast.mp4" 2>/dev/null
  show evidence/cast.mp4 "2. закид" >/dev/null
  rungate s-eyes-clip
  check "frames from the clip are attached"  '[ "$(after -i | grep -c "review-eyes/clip1-[0-9]*\.jpg$")" -ge 3 ]'
  check "they are real images"               'for f in $(after -i); do [ -s "$f" ] || exit 1; done'
  check "each says which clip and when"      'prompt | grep -q "з кліпу cast.mp4: 2. закид"'
  check "the clip itself is not attached"    '! after -i | grep -q "cast.mp4$"'
else
  echo "  (no ffmpeg — clip case skipped)"
fi

echo "===== an image the change added is attached unasked ====="
mkcase; plain; mkdir -p "$PROJ/evidence"; png "$PROJ/evidence/after.png"
( cd "$PROJ" && git add -A && git commit -qm shot )
rungate s-eyes-diff
check "the added image is attached"      'after -i | grep -q "/evidence/after.png$"'
check "and named as the change's own"    'prompt | grep -q "зображення, яке ця зміна додала або змінила: evidence/after.png"'

echo "===== a texture the change added is not a frame ====="
mkcase; plain; mkdir -p "$PROJ/evidence/textures/grass"
png "$PROJ/evidence/textures/grass/diff.png"; png "$PROJ/evidence/rock_nor_1k.png"; png "$PROJ/evidence/pier-view.png"
( cd "$PROJ" && git add -A && git commit -qm textures )
rungate s-eyes-tex
check "a texture folder is skipped"       '! after -i | grep -q "/textures/"'
check "a normal map is skipped"           '! after -i | grep -q "rock_nor_1k"'
check "a picture beside them is attached" 'after -i | grep -q "/evidence/pier-view.png$"'

echo "===== visual work with nothing shown: the reviewer is told, and judges it itself ====="
mkcase; visual
rungate s-eyes-none
check "no frames attached"               '! argv_has -i'
check "the prompt says NO FRAMES"        'prompt | grep -q "NO FRAMES"'
check "and how the worker shows one"     'prompt | grep -q "show-reviewer"'
check "frames are a tool, not a condition" 'prompt | grep -q "Frames are a tool, not a condition of acceptance"'
check "not every visual criterion is UNPROVEN" '! prompt | grep -q "Every criterion about what a person sees is UNPROVEN"'

echo "===== work that is not visual gets none of it ====="
mkcase; plain
rungate s-eyes-plain
check "no frames"                        '! argv_has -i'
check "no browser"                       '! grep -q review_browser "$ARGV"'
check "no visual block"                  '! prompt | grep -q "WHAT A PERSON SEES"'
check "the prompt still after --"        'argv_has -- && prompt | grep -q "HANDOFF | BLOCKED"'

echo "===== a long project: what an earlier piece broke still reopens work ====="
. "$ROOT/bin/lib/review-eyes.sh"; . "$ROOT/bin/lib/pieces.sh"
EYES="$(mktemp -d)"; REPOS+=("$EYES")
mkdir -p "$EYES/review-eyes"; printf '%s\t%s\n' "$EYES/grass.png" "трава біля води" > "$EYES/review-eyes/frames.tsv"
printf '%s' '{"pieces":[{"n":1,"title":"Ліс","state":"accepted"},{"n":2,"title":"Вода","state":"open"}]}' > "$EYES/pieces.json"
check "the piece clause is there"        'review_eyes_block "$EYES" 0 | grep -q "one piece of a long project"'
check "earlier pieces are not pre_existing" 'review_eyes_block "$EYES" 0 | grep -q "never \[pre_existing\]"'
check "taste does not reopen"            'review_eyes_block "$EYES" 0 | grep -q "matter of taste.*related_improvement"'
rm -f "$EYES/pieces.json"
check "without a plan, no piece clause"  '! review_eyes_block "$EYES" 0 | grep -q "one piece of a long project"'
check "but still look past the criteria" 'review_eyes_block "$EYES" 0 | grep -q "LOOK PAST THE CRITERIA FIRST"'
check "own screenshots too"              'review_eyes_block "$EYES" 1 | grep -q "looking past the criteria in them too"'

echo
echo "review eyes: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
