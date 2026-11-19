#!/bin/bash
# A prompt of any size reaches Claude and Codex: on stdin, never as an argument.
#
# Linux caps one argument, and one environment string, at 128 KiB (MAX_ARG_STRLEN = 131072 bytes),
# whatever ARG_MAX says. A large task in Cyrillic, two bytes a letter, plus its research made a
# 149 490-byte position prompt; `claude -p … "$prompt"` and `codex exec … "$prompt"` failed in
# execve with E2BIG, both independent positions died in five seconds, and the run went on DEGRADED
# with the cause only in a log.
#
# macOS has no such per-argument cap, so the stubs below enforce Linux's: any argument or
# environment string over 131072 bytes and they exit 126 with "Argument list too long", as the
# kernel would. Otherwise they answer with the number of bytes they read from stdin.
set -u
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$TMP/state" "$TMP/project" "$TMP/stub"
export SUPERVISOR_STATE_DIR="$TMP/state"
unset SUPERVISOR_CHAT_CONTEXT_FILE SUPERVISOR_EXTRA_DIRS_FILE
. "$BIN/supervisor-lib.sh"
IDIR="$(instance_dir "$(slug_for "$TMP/project")")"
mkdir -p "$IDIR"
printf '%s\n' "$(canon_path "$TMP/project")" > "$IDIR/project"
: > "$IDIR/started-at"

cat > "$TMP/stub/usage" <<'EOF'
#!/bin/bash
mkdir -p "$SUPERVISOR_STATE_DIR"
echo '{"five_hour":{"used_percentage":1,"resets_at":0,"window_minutes":300}}' > "$SUPERVISOR_STATE_DIR/codex-usage.json"
EOF
chmod +x "$TMP/stub/usage"
export SUPERVISOR_CLAUDE_USAGE_CMD="$TMP/stub/usage" SUPERVISOR_CODEX_USAGE_CMD="$TMP/stub/usage"

# The Linux limit, enforced by the stub on itself, then the answer: how much came in on stdin.
LIMIT_CHECK='
for a in "$@"; do [ "${#a}" -gt 0 ] && [ "$(printf "%s" "$a" | wc -c)" -gt 131072 ] && { echo "$0: Argument list too long" >&2; exit 126; }; done
while IFS= read -r -d "" e; do [ "$(printf "%s" "$e" | wc -c)" -gt 131072 ] && { echo "$0: Argument list too long (env)" >&2; exit 126; }; done < <(env -0)
n="$(wc -c | tr -d " ")"
printf "%s\n" "$*" > "'"$TMP"'/argv.$(basename "$0")"
'
cat > "$TMP/stub/claude" <<EOF
#!/bin/bash
$LIMIT_CHECK
case " \$* " in
  *" stream-json "*) printf '{"type":"result","subtype":"success","is_error":false,"result":"STDIN %s bytes"}\n' "\$n" ;;
  *) printf 'STDIN %s bytes\n' "\$n" ;;
esac
EOF
cat > "$TMP/stub/codex" <<EOF
#!/bin/bash
$LIMIT_CHECK
out=""; prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
last="\${!#}"
[ "\$last" = "-" ] || { echo "the prompt was not read from stdin (last argument: \$last)" >&2; exit 2; }
if [ -n "\$out" ]; then printf 'STDIN %s bytes\n' "\$n" > "\$out"; else printf 'STDIN %s bytes\n' "\$n"; fi
EOF
chmod +x "$TMP/stub/claude" "$TMP/stub/codex"

# 150 000 Cyrillic letters: 300 000 bytes, more than twice the cap.
BIG="$(python3 -c 'print("ї" * 150000, end="")')"
BYTES="$(printf '%s' "$BIG" | wc -c | tr -d ' ')"
[ "$BYTES" -gt 262144 ] && ok "the prompt is $BYTES bytes, over twice the 131072-byte cap" || bad "prompt only $BYTES bytes"

echo "===== an independent position, each engine ====="
for who in claude codex; do
  rm -f "$IDIR/peer-$who.md" "$IDIR/peer-$who.unavailable" "$TMP/argv.$who"
  printf '%s' "$BIG" > "$IDIR/peer-prompt.txt"
  PATH="$TMP/stub:$PATH" SUPERVISOR_PEER_POLL=1 \
    bash "$BIN/preflight.sh" --art "$IDIR" --stage peer --engine "$who" "$TMP/project" "задача" >/dev/null 2>&1
  got="$(cat "$IDIR/peer-$who.md" 2>/dev/null)"
  case "$got" in
    "STDIN "*" bytes"*) n="${got#STDIN }"; n="${n%% *}"
       [ "$n" -ge "$BYTES" ] && ok "$who's position came back; it read $n bytes on stdin" \
                             || bad "$who read only $n of $BYTES bytes" ;;
    *) bad "$who gave no position: $(cat "$IDIR/peer-$who.unavailable" 2>/dev/null)" ;;
  esac
  [ "$(wc -c < "$TMP/argv.$who" 2>/dev/null || echo 999999)" -lt 4096 ] \
    && ok "and its arguments stayed small ($(wc -c < "$TMP/argv.$who" | tr -d ' ') bytes)" || bad "$who's arguments carried the prompt"
  ls "$IDIR"/*.prompt "$IDIR"/.*.prompt 2>/dev/null | grep -q . && bad "a prompt file was left behind" || ok "and no prompt file was left behind"
done

echo "===== a CLI the system refuses to start is the engine's fault, and said so ====="
cp "$TMP/stub/claude" "$TMP/claude.stdin-stub"
printf '#!/bin/bash\necho "$0: Argument list too long" >&2\nexit 126\n' > "$TMP/stub/claude"; chmod +x "$TMP/stub/claude"
rm -f "$IDIR/peer-claude.md" "$IDIR/peer-claude.unavailable"
printf 'short\n' > "$IDIR/peer-prompt.txt"
PATH="$TMP/stub:$PATH" SUPERVISOR_PEER_POLL=1 \
  bash "$BIN/preflight.sh" --art "$IDIR" --stage peer --engine claude "$TMP/project" "задача" >/dev/null 2>&1
case "$(cat "$IDIR/peer-claude.unavailable" 2>/dev/null)" in
  *"помилка рушія"*"126"*) ok "exit 126 reads as an engine error: $(cut -c1-90 "$IDIR/peer-claude.unavailable")" ;;
  *) bad "exit 126 reason: $(cat "$IDIR/peer-claude.unavailable" 2>/dev/null)" ;;
esac
cp "$TMP/claude.stdin-stub" "$TMP/stub/claude"

echo "===== the planning calls and render, with a task over the cap ====="
# The functions as they are in preflight.sh, run against the same stubs.
eval "$(sed -n '/^RENDER_KEYS=/,/^}/p; /^prompt_is_sound()/,/^}/p; /^codex_ro()/,/^}/p; /^claude_plan()/p' "$BIN/preflight.sh")"
PROJ="$TMP/project"; LOG="$TMP/log"; STAGE_LOG="$TMP/stage.log"
printf 'Task: {{TASK}}\nResearch: {{RESEARCH}}\n' > "$TMP/tpl.md"
task="$BIG"
rendered="$(RESEARCH="$BIG" PATH="$TMP/stub:$PATH" render "$TMP/tpl.md")"; rc=$?
want=$(( BYTES * 2 + 17 ))   # the template's text, its last newline taken by $(…)
[ "$rc" = 0 ] && [ "$(printf '%s' "$rendered" | wc -c | tr -d ' ')" = "$want" ] \
  && ok "render fills a template with two values over the cap ($want bytes)" \
  || bad "render: rc=$rc, $(printf '%s' "$rendered" | wc -c | tr -d ' ') bytes, want $want"
# Through a stub perl that enforces the cap, so the environment is checked as Linux would.
cat > "$TMP/stub/perl" <<'EOF'
#!/bin/bash
while IFS= read -r -d '' e; do
  [ "$(printf '%s' "$e" | wc -c)" -gt 131072 ] && { echo "perl: Argument list too long (env)" >&2; exit 126; }
done < <(env -0)
exec /usr/bin/perl "$@"
EOF
chmod +x "$TMP/stub/perl"
rendered="$(RESEARCH="$BIG" PATH="$TMP/stub:$PATH" render "$TMP/tpl.md" 2>"$TMP/render.err")"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$rendered" | wc -c | tr -d ' ')" = "$want" ] \
  && ok "and perl, held to the cap on its environment, still renders it" || bad "render under the cap: rc=$rc $(cat "$TMP/render.err")"

RESEARCH="kept between calls"
r1="$(render "$TMP/tpl.md")"; r2="$(render "$TMP/tpl.md")"
[ "$RESEARCH" = "kept between calls" ] && printf '%s' "$r2" | grep -q "Research: kept between calls" \
  && ok "a value set for the whole script is still there for the next render" || bad "render dropped the caller's RESEARCH: «${RESEARCH-unset}» / $r2"
unset RESEARCH

out="$(PATH="$TMP/stub:$PATH" codex_ro 30 --output-schema /dev/null -o "$TMP/ro.out" "$BIG")"; rc=$?
[ "$rc" = 0 ] && grep -q "STDIN $BYTES bytes" "$TMP/ro.out" && ok "codex_ro passes the prompt on stdin, its flags kept" \
  || bad "codex_ro: rc=$rc $(cat "$TMP/ro.out" 2>/dev/null) $(tail -2 "$STAGE_LOG")"
grep -q -- "--output-schema /dev/null -o $TMP/ro.out -$" "$TMP/argv.codex" && ok "and the flags arrive in order, '-' last" \
  || bad "codex_ro argv: $(cat "$TMP/argv.codex")"
out="$(PATH="$TMP/stub:$PATH" claude_plan 30 "$BIG")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "STDIN $BYTES bytes" ] && ok "claude_plan passes the prompt on stdin" || bad "claude_plan: rc=$rc out=$out $(tail -2 "$STAGE_LOG")"

echo "===== no other call puts a prompt in argv ====="
# Every `codex exec` / `claude -p` in the engine: the prompt comes from stdin (`-` for codex).
left="$(grep -rnE '(codex exec|"\$CODEX_BIN" exec|claude -p)' "$BIN" "$BIN/../hooks" 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'codex exec would refuse' \
  | while IFS= read -r line; do
      f="${line%%:*}"; n="${line#*:}"; n="${n%%:*}"
      block="$(sed -n "${n},$((n + 3))p" "$f")"
      printf '%s' "$block" | grep -qE '"\$(prompt|PROMPT|1|2)"[[:space:]]*(</dev/null|2>|\)|$)' && echo "$f:$n"
    done)"
[ -z "$left" ] && ok "every codex exec and claude -p reads its prompt from stdin" || { bad "still in argv:"; printf '%s\n' "$left" | sed 's/^/      /'; }

echo
[ "$fails" -eq 0 ] && echo "✅ prompt via stdin: all checks pass" || echo "❌ prompt via stdin: $fails failed"
[ "$fails" -eq 0 ]
