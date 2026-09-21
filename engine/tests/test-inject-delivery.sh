#!/bin/bash
# Does the text actually ARRIVE — all of it, unchanged?
#
# `tmux send-keys -l "$task"` refused 15.6KB with "command too long" and delivered nothing, so a
# continued run sat at an empty prompt while the launcher reported success. Delivery now goes through
# a paste buffer loaded from a file, with line-by-line typing as the fallback.
#
# Both paths are checked against a REAL tmux session whose pane just collects bytes, and the result
# is compared with `cmp` — byte for byte. Nothing here trusts a screen scrape: a screenshot cannot
# tell an LF turned into a carriage return, a multi-byte character cut in half, or a line beginning
# with a dash that tmux swallowed as an option.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tmux.sh"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

command -v tmux >/dev/null 2>&1 || { echo "⚠️  нема tmux — пропускаю"; exit 0; }

TMP="$(mktemp -d -t inject-delivery)" || exit 1
SESSION="bulava-inject-test-$$"
trap 'tmux kill-session -t "$SESSION" 2>/dev/null; rm -rf "$TMP"' EXIT

# The hardest text I can think of that a real prompt actually contains.
{
  printf 'ПРОДОВЖЕННЯ роботи — не починай з нуля.\n'
  printf -- '--- ЩО ДИРЕКТОР УЖЕ ВИРІШИВ (не переписуй) ---\n'
  printf -- '-R -t --sandbox  # a line that starts with dashes\n'
  printf '100%% готово, "лапки", '"'"'одинарні'"'"', $VAR, `backtick`, back\\slash\n'
  printf '{"json":"з двобайтовими символами: ґ, ї, є, —, ✅"}\n'
  printf '\n'                      # an empty line in the middle
  printf 'a %s b\n' "$(printf 'дуже-довгий-рядок-%.0s' $(seq 1 200))"   # ~5KB on one line
  # And bulk, to pass the limit that started all this.
  for i in $(seq 1 200); do
    printf 'Крок %s: зроби роботу повністю, без заглушок і "на потім".\n' "$i"
  done
  printf 'останній рядок без переводу'      # no trailing newline
} > "$TMP/prompt.txt"
size="$(wc -c < "$TMP/prompt.txt" | tr -d ' ')"
echo "===== a prompt of $size bytes, delivered to a real pane ====="
[ "$size" -gt 16000 ] || bad "the fixture is smaller than the limit it exists to cross ($size)"

# A pane that is just a sink: the tty in RAW mode, `cat -u` streaming what it receives into a file.
#
# Raw matters. A terminal in its default (canonical) mode buffers by line and accepts at most about a
# kilobyte before a newline — the first version of this test received 364 bytes of a 27KB prompt and
# blamed the delivery. Claude Code, like every full-screen application, puts the tty in raw mode and
# reads continuously; this reproduces that, and `-u` keeps stdio from holding the tail in a buffer.
start_sink() {  # $1=where to write
  rm -f "$1"
  tmux kill-session -t "$SESSION" 2>/dev/null
  tmux new-session -d -s "$SESSION" -x 200 -y 50 "stty raw -echo; exec cat -u > '$1'" || return 1
  sleep 1
}

# Nothing is echoed back, so what the sink WROTE is the evidence. Raw mode translates nothing, so
# the bytes on disk are the bytes that arrived — and the file is compared to the prompt itself.
finish_sink() {
  sleep 3
  tmux kill-session -t "$SESSION" 2>/dev/null
}

expected() { cat "$TMP/prompt.txt"; }

echo
echo "===== the paste-buffer path ====="
if start_sink "$TMP/got.txt"; then
  if _deliver_text "$SESSION" "$TMP/prompt.txt"; then ok "delivery reported success"; else bad "delivery failed outright"; fi
  finish_sink
  expected > "$TMP/want.txt"
  if cmp -s "$TMP/want.txt" "$TMP/got.txt"; then
    ok "every byte arrived, unchanged"
  else
    bad "the text was altered in flight: $(cmp "$TMP/want.txt" "$TMP/got.txt" 2>&1 | head -1)"
    printf '     want %s bytes, got %s\n' "$(wc -c < "$TMP/want.txt" | tr -d ' ')" "$(wc -c < "$TMP/got.txt" 2>/dev/null | tr -d ' ')"
  fi
  # The specific corruptions worth naming, so a failure says WHICH one.
  if grep -q $'\r' "$TMP/got.txt" 2>/dev/null; then
    bad "line feeds arrived as carriage returns — a TUI would read those as Enter"
  else
    ok "line feeds stayed line feeds (no premature submit)"
  fi
  if grep -q -- '^-R -t --sandbox' "$TMP/got.txt" 2>/dev/null; then
    ok "a line starting with dashes arrived as text"
  else
    bad "the dash-leading line was eaten as an option"
  fi
  if grep -q 'ґ, ї, є, —, ✅' "$TMP/got.txt" 2>/dev/null; then
    ok "multi-byte characters survived intact"
  else
    bad "a multi-byte character was cut"
  fi
else
  bad "could not start a tmux session to test against"
fi

echo
echo "===== the fallback path, with the buffer route disabled ====="
# Forced by making `tmux load-buffer` fail: a wrapper on PATH that rejects exactly that subcommand
# and passes everything else through. This is the branch that runs on a tmux without a usable
# buffer, and it is the one nobody would otherwise ever execute.
mkdir -p "$TMP/bin"
real_tmux="$(command -v tmux)"
cat > "$TMP/bin/tmux" <<EOF
#!/bin/bash
[ "\${1:-}" = "load-buffer" ] && exit 1
exec "$real_tmux" "\$@"
EOF
chmod +x "$TMP/bin/tmux"
if PATH="$TMP/bin:$PATH" bash -c ". '$BIN_DIR/supervisor-lib.sh'; \
     tmux kill-session -t '$SESSION' 2>/dev/null; \
     tmux new-session -d -s '$SESSION' -x 200 -y 50 \"stty raw -echo; exec cat -u > '$TMP/got2.txt'\" && \
     sleep 1 && _deliver_text '$SESSION' '$TMP/prompt.txt' && sleep 3"; then
  ok "the fallback reported success"
else
  bad "the fallback failed outright"
fi
tmux kill-session -t "$SESSION" 2>/dev/null
expected > "$TMP/want.txt"
if cmp -s "$TMP/want.txt" "$TMP/got2.txt"; then
  ok "the fallback also delivered every byte unchanged"
else
  bad "the fallback altered the text: $(cmp "$TMP/want.txt" "$TMP/got2.txt" 2>&1 | head -1)"
  printf '     want %s bytes, got %s\n' "$(wc -c < "$TMP/want.txt" | tr -d ' ')" "$(wc -c < "$TMP/got2.txt" 2>/dev/null | tr -d ' ')"
fi

echo
[ "$fails" = 0 ] && echo "✅ injection: the whole task reaches the worker" || echo "❌ $fails problem(s)"
exit "$fails"
