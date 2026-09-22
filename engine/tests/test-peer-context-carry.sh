#!/bin/bash
# "Let's do 1 and 2" has to be readable by an engineer who never saw the conversation.
#
# Codex arrives cold by design — that independence is the whole point of asking two engineers. But
# a message can be an ANSWER, and an answer without its question is not a short message, it is an
# unreadable one. The director hit this exactly:
#
#     Claude:  Are we doing: 1. the sync feature, 2. the design fix?
#     Director: Let's do 1 and 2
#     Codex:   What are 1 and 2?
#
# The follow-up brief has carried the last reply since `thread_brief` started including it. The
# NEW-task brief carried nothing at all — and whether a sentence refers back is a different
# question from whether the engine classified it as a fresh job, so the reference has to travel on
# both paths. It travels as REFERENCE, not as a position: the prompt says so in as many words,
# because a second opinion that reads the first one as a plan has stopped being a second opinion.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/state"; mkdir -p "$SUPERVISOR_STATE_DIR"
export HOME="$TMP/home"; mkdir -p "$HOME"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE 2>/dev/null || true
. "$BIN/supervisor-lib.sh"

PROJ="$TMP/project"; mkdir -p "$PROJ"
git -C "$PROJ" init -q 2>/dev/null
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
printf 'one\n' > "$PROJ/a.txt"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm base
PROJ="$(canon_path "$PROJ")"

IDIR="$(instance_dir "$(slug_for "$PROJ")")"; mkdir -p "$IDIR"
printf '%s\n' "$PROJ" > "$IDIR/project"
printf '%s\n' "carry-test-run" > "$IDIR/run-id"

# The transcript Claude Code keeps of its own session, with the question in it.
SID="11112222-3333-4444-5555-666677778888"
printf '%s\n' "$SID" > "$IDIR/claude-session-id"
TR="$HOME/.claude/projects/-tmp-project"; mkdir -p "$TR"
QUESTION='Чи робимо наступне: 1. фіча синхронізації між пристроями, 2. фіча виправлення дизайну?'
jq -nc --arg t "не зважай на це, це старіша репліка" \
   '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}' > "$TR/$SID.jsonl"
jq -nc --arg t "$QUESTION" \
   '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}' >> "$TR/$SID.jsonl"

echo "===== the last thing Claude said is recoverable at all ====="
GOT="$(claude_last_reply "$IDIR")"
case "$GOT" in *"фіча синхронізації"*) ok "the question is found in Claude's own transcript" ;;
               *) bad "nothing came back: ${GOT:-<empty>}" ;; esac
# Cut on whole lines: `tail -c` used to open the excerpt with half a character.
# Through the engine's own gate, not `iconv >/dev/null`: Apple's iconv answers "Inappropriate
# ioctl for device" on valid multibyte input when its stdout is /dev/null, so this check was one
# Cyrillic kilobyte away from failing a correct excerpt.
if printf '%s' "$GOT" | text_is_utf8; then
  ok "and it is valid UTF-8 from its first byte"
else
  bad "the excerpt starts mid-character"
fi

echo "===== a FOLLOW-UP brief carries it ====="
thread_bind "$IDIR" "$QUESTION" msg-1 1 new >/dev/null 2>&1
BRIEF="$(thread_brief "$IDIR" "$PROJ" "Давай 1 та 2" 2>/dev/null)"
case "$BRIEF" in *"фіча синхронізації"*) ok "the brief says what the answer is answering" ;;
                 *) bad "the follow-up brief lost the question" ;; esac
case "$BRIEF" in *"Давай 1 та 2"*) ok "and the answer itself is in it" ;;
                 *) bad "the new message is missing from the brief" ;; esac

echo "===== a NEW-task brief carries it too — the classifier does not decide readability ====="
# The path the director actually fell through: the engine read the reply as a fresh job, and the
# peer prompt for a fresh job had no conversation in it whatsoever.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/codex" <<'EOF'
#!/bin/bash
if [ "${1:-}" = login ]; then echo "Logged in using ChatGPT"; exit 0; fi
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '{"scale":"small","needs_plan":false,"needs_external_research":false}' > "$out"
echo '{"type":"turn.completed"}'
EOF
chmod +x "$TMP/stub/codex"
rm -f "$IDIR/peer-prompt.txt"
# PIPE_RELATION=new is how the pipeline tells preflight the message was accepted as a fresh job.
# Without it this fixture drifts onto the follow-up path — which already carried the reference —
# and the test would pass while proving nothing about the path the director actually fell through.
PATH="$TMP/stub:$PATH" PIPE_RELATION=new SUPERVISOR_DESIGN_RESEARCH=0 SUPERVISOR_PLAN_TIMEOUT=20 \
  bash "$BIN/preflight.sh" --art "$IDIR" --stage context "$PROJ" "Давай 1 та 2" >/dev/null 2>&1
grep -q "one of two senior engineers independently examining" "$IDIR/peer-prompt.txt" 2>/dev/null \
  && ok "the fixture really is on the NEW-task path" \
  || bad "this fixture drifted onto the follow-up path — it proves nothing about a fresh job"

[ -s "$IDIR/peer-prompt.txt" ] && ok "the new-task peer prompt was written" \
                              || bad "no peer prompt produced"
PP="$(cat "$IDIR/peer-prompt.txt" 2>/dev/null)"
case "$PP" in *"фіча синхронізації"*) ok "and it carries what the message replies to" ;;
               *) bad "Codex would again be asked to read «Давай 1 та 2» with nothing to read it against" ;; esac
case "$PP" in *"Давай 1 та 2"*) ok "alongside the message itself" ;;
               *) bad "the message is missing from its own prompt" ;; esac

echo "===== …and it is framed as reference, never as a position to agree with ====="
# Independence is the reason there are two engineers. A prompt that hands over the other one's
# reasoning without saying what it is has quietly turned the second opinion into an echo.
case "$PP" in *"not a position to agree with"*) ok "the prompt says what this text is, and is not" ;;
               *) bad "the other engineer's words arrive unlabelled" ;; esac

echo "===== no transcript, no invention ====="
rm -f "$IDIR/claude-session-id"
EMPTY="$(claude_last_reply "$IDIR")"
[ -z "$EMPTY" ] && ok "with nothing to quote it quotes nothing" || bad "invented context: $EMPTY"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
