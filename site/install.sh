#!/bin/bash
# night-shift — the engine behind Bulava, installed on its own.
#
#   curl -fsSL https://bulava.app/install.sh | bash
#
# What this does, in full, so that reading it is not necessary but is never a surprise:
#
#   1. checks what is missing and stops if anything is, naming it;
#   2. downloads the published source of the engine into ~/.night-shift;
#   3. runs the engine's own installer, which links seven commands into ~/.local/bin,
#      writes three slash commands into ~/.claude/commands, sets Claude Code's status line
#      and writes the worker hooks into ~/.claude/supervisor/worker-settings.json.
#
# It backs up ~/.claude/settings.json before touching it, and `night-shift uninstall` takes all
# of it back out again.
#
# What it cannot give you: the runs that prove themselves with a screenshot. macOS grants screen
# recording and accessibility to a signed application, not to a shell script, so those need the
# Bulava app — https://bulava.app.
set -eu

REPO="${NIGHT_SHIFT_REPO:-Stepanokdev/bulava}"
REF="${NIGHT_SHIFT_REF:-main}"
DEST="${NIGHT_SHIFT_HOME:-$HOME/.night-shift}"

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
die()  { printf '\n❌ %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- what has to be here already
say "дивлюсь, чого бракує"

[ "$(uname -s)" = "Darwin" ] || die "поки що тільки macOS — движок керує сесіями через tmux і питає у macOS про ліміти."

missing=""
for tool in curl tar git python3 jq tmux; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  printf '\n❌ немає:%s\n' "$missing" >&2
  if command -v brew >/dev/null 2>&1; then
    printf '   Постав так:  brew install%s\n' "$missing" >&2
  else
    printf '   Постав Homebrew (https://brew.sh), тоді:  brew install%s\n' "$missing" >&2
  fi
  exit 1
fi
note "curl, tar, git, python3, jq, tmux — на місці"

# The two accounts. Not fatal: somebody may be installing before signing in, and refusing here
# would mean they cannot even read `night-shift status` to find out what is wrong.
for cli in claude codex; do
  if command -v "$cli" >/dev/null 2>&1; then
    note "$cli знайдено"
  else
    printf '  ⚠️  %s не знайдено — без нього движок не запустить роботу.\n' "$cli"
    [ "$cli" = claude ] && printf '     https://claude.ai/code\n'
    [ "$cli" = codex ]  && printf '     https://developers.openai.com/codex/cli\n'
  fi
done

# ---------------------------------------------------------------- the engine itself
say "беру движок"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
URL="https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF"

curl -fsSL -m 120 -o "$TMP/src.tar.gz" "$URL" \
  || die "не завантажилось: $URL"
# Only the engine comes out of the archive. The application is 20 MB of Swift that a terminal
# install has no use for, and unpacking it would make `night-shift` look like it half-installed
# something else.
tar -xzf "$TMP/src.tar.gz" -C "$TMP" \
  || die "архів не розпакувався"
SRC="$(find "$TMP" -maxdepth 2 -type d -name engine | head -1)"
[ -n "$SRC" ] && [ -x "$SRC/install.sh" ] \
  || die "в архіві немає движка — схоже, репозиторій $REPO@$REF виглядає інакше"
note "версія з $REPO@$REF"

# Replaced, not merged. A previous install's files are not ours to keep guessing about, and the
# state that actually matters lives in ~/.claude/supervisor, which is somewhere else entirely.
if [ -d "$DEST" ]; then
  note "оновлюю те, що вже стоїть у $DEST"
  rm -rf "$DEST.previous"
  mv "$DEST" "$DEST.previous"
fi
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST" || die "не вдалося покласти движок у $DEST"
printf '%s@%s %s\n' "$REPO" "$REF" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DEST/VERSION"
rm -rf "$DEST.previous"

# ---------------------------------------------------------------- hand over to its own installer
say "встановлюю"
bash "$DEST/install.sh" || die "установник движка не завершився — дивись, що він сказав вище"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *)
    printf '\n  ⚠️  ~/.local/bin не в PATH. Додай у ~/.zshrc:\n'
    printf '      export PATH="$HOME/.local/bin:$PATH"\n'
    ;;
esac

say "готово"
cat <<DONE
  Перевір:        night-shift status
  Запусти роботу: night-shift start /шлях/до/проєкту
  Прибрати все:   night-shift uninstall

  Застосунок робить те саме у вікні, плюс знімки екрана як доказ роботи:
  https://bulava.app
DONE
