#!/bin/bash
# Build the engine as a thing a stranger can install, and prove it carries nothing of its author's.
#
# The engine's memory used to live inside this checkout, so one person's clients, products and
# taste were committed alongside the product — and `git rm` does not undo that: every clone still
# downloads those objects out of history. Rather than rewrite the history of a working repository,
# this exports the engine as its own tree with no history at all, and then AUDITS what it exported.
#
#   publish-engine.sh [<out-dir>] [--git] [--tar]
#
# Exits non-zero, and produces nothing, if the audit finds anything personal. A refusal here is
# the point: it is the last moment before the material leaves the machine.
set -eu
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"

OUT=""; MAKE_GIT=0; MAKE_TAR=0
for a in "$@"; do
  case "$a" in
    --git) MAKE_GIT=1 ;;
    --tar) MAKE_TAR=1 ;;
    -h|--help) sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) OUT="$a" ;;
  esac
done
[ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/night-shift-engine-$(date +%Y%m%d-%H%M%S)"

# Never delete what the caller pointed at. The destination is a path they typed, the audit has
# not run yet, and a mistyped argument must not cost them a directory: refuse, stage somewhere
# of our own, and move into place only once the audit has passed.
if [ -e "$OUT" ]; then
  echo "❌ «${OUT}» уже існує. Вкажи новий шлях — я нічого не перезаписую." >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/night-shift-engine-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT INT TERM

# What ships: the engine's code, its prompts, its hooks. The engine keeps nothing it learned
# about anybody, so there is nothing personal here to leave behind — the audit below proves it
# rather than trusting it.
for item in bin hooks tests supervisor claude-commands assets install.sh ENGINE-README.md; do
  [ -e "$ROOT/$item" ] || continue
  cp -R "$ROOT/$item" "$STAGE/$item"
done
rm -rf "$STAGE/bin/__pycache__" "$STAGE/supervisor/memory" "$STAGE/supervisor/lessons" 2>/dev/null || true
find "$STAGE" -name '*.backup-*' -delete 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

# ---- audit: what did we actually just stage? -------------------------------------------------
fails=0
say()  { printf '  %s\n' "$1"; }
bad()  { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }
ok()   { printf '  \xe2\x9c\x85 %s\n' "$1"; }

echo "== аудит експорту =="

if [ -e "$STAGE/supervisor/lessons" ] || [ -e "$STAGE/supervisor/memory" ]; then
  bad "у експорті лишився накопичений шар памʼяті"
else
  ok "накопиченої памʼяті в експорті немає"
fi

# Names of the author's products and clients must not appear in what ships. They are read from
# the run state on THIS machine — the folders this engine has actually worked in — so the check
# adapts to whoever runs it instead of hard-coding one person's client list into a public
# repository. It used to read the memory store, which no longer exists; the instance and run
# directories name the same products and are still here.
#
# Resolved here rather than by sourcing supervisor-lib.sh: this script must stay runnable against
# an exported tree whose library is the copy under audit.
SUP_STATE="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
# The engine belongs to this product, so its own name is expected everywhere and is not a leak.
# Declared in config.sh rather than guessed from the parent directory: once exported, the parent
# is a temp folder, and the engine would start flagging itself.
. "$ROOT/supervisor/config.sh" 2>/dev/null || true
own="$(printf '%s' "${SUPERVISOR_PRODUCT_NAME:-}" | tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
names=""
for f in "$SUP_STATE"/instances/*/project "$SUP_STATE"/runs/*/project; do
  [ -f "$f" ] || continue
  b="$(basename "$(cat "$f" 2>/dev/null)" 2>/dev/null)"
  b="$(printf '%s' "$b" | tr -c 'A-Za-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  [ -z "$b" ] && continue
  [ "$b" = "$own" ] && continue
  case " $names " in *" $b "*) continue ;; esac
  [ ${#b} -ge 5 ] && names="$names $b"
done
hits=""
for n in $names; do
  # word-ish match, case-insensitive; skip our own audit text
  if grep -ril --exclude='publish-engine.sh' -- "$n" "$STAGE" >/dev/null 2>&1; then
    hits="$hits $n"
  fi
done
if [ -n "$hits" ]; then
  bad "у експорті згадуються продукти/клієнти:$hits"
  for n in $hits; do grep -ril --exclude='publish-engine.sh' -- "$n" "$STAGE" | sed 's|^|      |'; done
else
  ok "назв продуктів і клієнтів у експорті немає"
fi

# Secrets and absolute home paths travel badly and often carry a name with them.
if grep -rIl -E '(sk-[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|AuthKey_[A-Z0-9]+\.p8)' "$STAGE" >/dev/null 2>&1; then
  bad "у експорті є щось схоже на секрет"
  grep -rIl -E '(sk-[A-Za-z0-9_-]{20,}|BEGIN [A-Z ]*PRIVATE KEY|AuthKey_[A-Z0-9]+\.p8)' "$STAGE" | sed 's|^|      |'
else
  ok "секретів не знайдено"
fi

home_hits="$(grep -rIl -- "/Users/$(id -un)/" "$STAGE" 2>/dev/null | grep -v 'publish-engine.sh' || true)"
if [ -n "$home_hits" ]; then
  bad "у експорті лишились абсолютні шляхи домашньої теки"
  printf '%s\n' "$home_hits" | sed 's|^|      |'
else
  ok "абсолютних шляхів домашньої теки немає"
fi

# The engine must run on a machine that has never run it before: no state directory, nothing
# carried over. The stack detector is what the verifier and the screenshot backend ask first, so
# it is the honest smoke test now that there is no memory to build a prompt from.
if ( cd "$STAGE" && SUPERVISOR_STATE_DIR="$STAGE/.probe-state" \
     bash -c '. bin/supervisor-lib.sh; detect_stacks "'"$STAGE"'" >/dev/null' ) 2>/dev/null; then
  ok "движок стартує на чистій машині"
else
  bad "движок падає на чистій машині"
fi
rm -rf "$STAGE/.probe-state" 2>/dev/null || true

if [ "$fails" -ne 0 ]; then
  echo
  echo "❌ Експорт НЕ створено: $fails проблем(и). Нічого не публікуй, доки вони є."
  exit 1
fi

# Atomic when it can be (same filesystem), and either way it only ever creates $OUT.
if ! mv "$STAGE" "$OUT" 2>/dev/null; then
  mkdir -p "$OUT" && cp -R "$STAGE/." "$OUT/" && rm -rf "$STAGE"
fi
trap - EXIT INT TERM

if [ "$MAKE_GIT" = 1 ]; then
  ( cd "$OUT" && git init -q . && git add -A \
    && git -c user.name="Night Shift" -c user.email="engine@localhost" \
         commit -q -m "Night Shift engine — initial public tree (no prior history)" )
  echo
  echo "Репозиторій без історії: $OUT (комітів: 1)"
fi

if [ "$MAKE_TAR" = 1 ]; then
  ( cd "$(dirname "$OUT")" && tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")" )
  echo "Архів: $OUT.tar.gz"
fi

echo
echo "✅ Чистий движок: $OUT"
echo "   Ставиться так:  cd \"$OUT\" && ./install.sh"
