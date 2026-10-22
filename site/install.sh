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
# Where: macOS, Linux, and Windows through WSL2 (`install.ps1` sets that up and calls this inside
# the distribution). On a Mac that already has the Bulava app it installs no second engine — the
# terminal commands are pointed at the app's own, so the two never fight over Claude Code's hooks.
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

OS="$(uname -s)"
case "$OS" in
  Darwin) note "macOS" ;;
  Linux)
    if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
      grep -qi 'wsl2\|microsoft-standard' /proc/sys/kernel/osrelease 2>/dev/null \
        || die "це WSL1 — tmux і git у ньому ненадійні. Онови дистрибутив до WSL2:  wsl --set-version <дистрибутив> 2"
      note "Linux у WSL2 (${WSL_DISTRO_NAME:-?})"
    else
      note "Linux"
    fi ;;
  MINGW*|MSYS*|CYGWIN*)
    die "це Git Bash / MSYS на Windows. Рушію потрібен справжній Linux — постав через WSL2 у PowerShell:
     irm https://bulava.app/install.ps1 | iex" ;;
  *) die "$OS не підтримується — лише macOS, Linux і Windows через WSL2." ;;
esac

# One package manager line that would put the missing pieces in place, for the system at hand.
install_hint() {   # $@ = missing tools
  if [ "$OS" = Darwin ]; then
    if command -v brew >/dev/null 2>&1; then printf 'brew install %s' "$*"
    else printf 'постав Homebrew (https://brew.sh), тоді:  brew install %s' "$*"; fi
  elif command -v apt-get >/dev/null 2>&1; then printf 'sudo apt-get install -y %s' "$*"
  elif command -v dnf >/dev/null 2>&1; then printf 'sudo dnf install -y %s' "$*"
  elif command -v pacman >/dev/null 2>&1; then printf 'sudo pacman -S --needed %s' "$*"
  elif command -v zypper >/dev/null 2>&1; then printf 'sudo zypper install -y %s' "$*"
  elif command -v apk >/dev/null 2>&1; then printf 'sudo apk add %s' "$*"
  else printf 'встанови через пакетний менеджер системи: %s' "$*"; fi
}

missing=""
for tool in curl tar git python3 jq tmux; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
# GNU systems: `file` decides which of several Codex installs is real, and `ps` comes from procps.
if [ "$OS" = Linux ]; then
  command -v file >/dev/null 2>&1 || missing="$missing file"
  command -v ps >/dev/null 2>&1 || missing="$missing procps"
fi
if [ -n "$missing" ]; then
  printf '\n❌ немає:%s\n' "$missing" >&2
  printf '   Постав так:  %s\n' "$(install_hint $missing)" >&2
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

# ---------------------------------------------------------------- one engine per Mac
#
# Bulava installs its engine at launch, into Application Support, and points Claude Code's hooks and
# ~/.local/bin at it. A second engine here would take those hooks over for the app's runs too, and
# the app would take them back at its next launch — two versions trading places under running work.
# With the app present, the terminal uses the app's engine: same commands, same state, one copy.
APP_ENGINE="$HOME/Library/Application Support/Bulava/engine"
if [ "$OS" = Darwin ] && [ -f "$APP_ENGINE/bin/verify.sh" ] && [ "${NIGHT_SHIFT_SEPARATE_ENGINE:-0}" != 1 ]; then
  say "Bulava вже встановлено — беру його движок"
  mkdir -p "$HOME/.local/bin"
  for pair in night-shift:night-shift.sh deep-audit:deep-audit.sh night-queue:queue.sh \
              report-finding:report-finding.sh report-outcome:worker-outcome.sh \
              night-trace:trace.sh night-artifact:artifact.sh; do
    ln -sf "$APP_ENGINE/bin/${pair#*:}" "$HOME/.local/bin/${pair%%:*}"
  done
  note "команди в ~/.local/bin ведуть у движок застосунку; хуки й налаштування Claude Code — його ж"
  note "застосунок оновлює движок сам, тож і термінал оновлюється разом із ним"
  say "готово"
  cat <<DONE
  Перевір:         night-shift doctor
  Налаштування:    night-shift config set claude.model opus   (застосунок їх не бачить і не змінює)
  Узяти з Bulava:  night-shift config import-app
DONE
  exit 0
fi

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
    rc="~/.bashrc"; case "${SHELL:-}" in */zsh) rc="~/.zshrc" ;; */fish) rc="~/.config/fish/config.fish" ;; esac
    printf '\n  ⚠️  ~/.local/bin не в PATH. Додай у %s:\n' "$rc"
    printf '      export PATH="$HOME/.local/bin:$PATH"\n'
    ;;
esac

say "готово"
cat <<DONE
  Перевір:        night-shift doctor
  Запусти роботу: night-shift start /шлях/до/проєкту --model opus --effort high
  Налаштування:   night-shift config keys
  Автодоповнення: eval "\$(night-shift completion ${SHELL##*/})"
  Прибрати все:   night-shift uninstall
DONE
if [ "$OS" = Darwin ]; then
  cat <<DONE

  Застосунок робить те саме у вікні, плюс знімки екрана як доказ роботи:
  https://bulava.app
DONE
fi
