#!/bin/bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Writing that an old install kept INSIDE the engine, which is not safe to leave alone.
#
# Before the store was split out, `_global.md` and `projects/*.md` lived in `supervisor/lessons/` —
# in the checkout itself. This engine ships no `supervisor/lessons` at all, and the app updates by
# `rsync --delete`, so the act of updating would delete those files. They are moved out to the
# store, which nothing reads any more, and the directory is removed only once every one of them is
# safely there.
#
# Run before anything else this script does, so their files are out of the way before any other
# step can touch the machine. If it cannot finish, the install still completes and the failure is
# reported at the end: by this point the app has already replaced the engine, and stopping here
# would leave one that looks installed and has no hooks.
LEGACY_RESCUE_FAILED=0
LEGACY_LESSONS="$ROOT/supervisor/lessons"
STORE="$HOME/.claude/supervisor/memory"   # read again at the end, where the failure is reported
if [ -d "$LEGACY_LESSONS" ]; then
  rescued=0
  rescue_failed=0

  # A destination nothing occupies. The timestamp this used to append is not one: two files
  # rescued in the same second, or two runs of this installer in the same second, resolve to the
  # same name, and `mv` would write straight over what the earlier rescue saved. A counter cannot
  # collide with itself.
  free_path() {  # $1 = the desired path → one that does not exist yet
    local want="$1" dir base n=1 candidate
    dir="$(dirname "$want")"; base="$(basename "$want" .md)"
    candidate="$want"
    while [ -e "$candidate" ]; do
      candidate="$dir/$base.from-engine-$n.md"
      n=$((n + 1))
    done
    printf '%s' "$candidate"
  }

  # `mv x && n=$((n+1))` looked like it would stop the script on a failed move. It does not:
  # `set -e` is disabled for every command in an AND list except the last, so a failed `mv` fell
  # through silently — and the `rm -rf` below then deleted the original it had not saved.
  rescue_one() {  # $1 = file, $2 = directory it belongs in
    local src="$1" dir="$2" dest
    mkdir -p "$dir" || return 1
    dest="$(free_path "$dir/$(basename "$src")")"
    mv "$src" "$dest" || return 1
    [ -e "$dest" ] || return 1
    rescued=$((rescued + 1))
    return 0
  }

  if [ -f "$LEGACY_LESSONS/_global.md" ]; then
    rescue_one "$LEGACY_LESSONS/_global.md" "$STORE" || rescue_failed=1
  fi
  for f in "$LEGACY_LESSONS"/projects/*.md; do
    [ -f "$f" ] || continue
    rescue_one "$f" "$STORE/projects" || rescue_failed=1
  done

  # A failed rescue is reported at the END, not here.
  #
  # By the time this script runs, the app has ALREADY replaced the engine by `rsync --delete`.
  # Stopping at this line left the hooks unwritten and the terminal commands unlinked, while the
  # copied files made the app report the engine as ready — an engine that looks installed and has
  # no gates is a worse state than the one this block is protecting against. Nothing below touches
  # the files at stake, so the install finishes and the exit code still says something went wrong.
  if [ "$rescue_failed" = 1 ]; then
    LEGACY_RESCUE_FAILED=1
  else
    # What is left is the practice modules an older engine shipped: the same for everyone, nobody's
    # writing. Removed only now, when every file that was somebody's is already elsewhere.
    rm -rf "$LEGACY_LESSONS"
    if [ "$rescued" -gt 0 ]; then
      echo "ℹ️  винесено $rescued файл(ів) старої памʼяті з движка → $STORE (їх більше не читають)"
    fi
  fi
fi

# A first install has no ~/.claude at all, and this used to die on the backup before doing
# anything — the one moment the script exists for.
mkdir -p ~/.claude
if [ -f ~/.claude/settings.json ]; then
  cp ~/.claude/settings.json ~/.claude/settings.json.backup-$(date +%Y%m%d-%H%M%S)
  echo "backup: ~/.claude/settings.json.backup-*"
else
  echo "нових налаштувань Claude Code тут ще немає — створюю"
fi

ROOT="$ROOT" python3 - <<'EOF'
import json, os, pathlib, shlex

ROOT = os.environ["ROOT"]

# Hook/statusLine `command` values are executed by Claude Code via `/bin/sh -c "<command>"`,
# so a path containing a space (the engine now lives under ".../Night Shift/engine") MUST be
# shell-quoted — otherwise sh word-splits it and every hook dies with
# "/bin/sh: .../Night: No such file or directory", silently disabling review-gate, write-gate,
# safety-check and answer-question. shlex.quote handles spaces and any other special char.
def cmd(rel):
    return shlex.quote(f"{ROOT}/{rel}")
p = pathlib.Path.home() / ".claude" / "settings.json"
# Missing or unreadable settings mean a fresh machine, not a broken one: start from an empty
# object rather than refusing to install.
try:
    s = json.loads(p.read_text())
    if not isinstance(s, dict):
        s = {}
except (FileNotFoundError, json.JSONDecodeError):
    s = {}

s["statusLine"] = {"type": "command", "command": cmd("bin/statusline.sh")}

# Supervisor hooks are WORKER-ONLY (see worker-settings.json below). The global config must
# only be GUARANTEED clean of them — idempotent de-pollution — while unrelated hooks (memex)
# are preserved. Older installs put these hooks here; strip them out.
hooks = s.setdefault("hooks", {})
hooks["PreToolUse"] = [e for e in hooks.get("PreToolUse", [])
                       if "answer-question.sh" not in json.dumps(e)
                       and "write-gate.sh" not in json.dumps(e)
                       and "control-guard.sh" not in json.dumps(e)]
hooks["PostToolUse"] = [e for e in hooks.get("PostToolUse", [])
                        if "control-guard.sh" not in json.dumps(e)]
hooks["Stop"] = [e for e in hooks.get("Stop", []) if "review-gate.sh" not in json.dumps(e)]
hooks["SessionStart"] = [e for e in hooks.get("SessionStart", []) if "safety-check.sh" not in json.dumps(e)]
for k in ("PreToolUse", "PostToolUse", "Stop", "SessionStart"):
    if k in hooks and not hooks[k]:
        del hooks[k]

allow = s.get("permissions", {}).get("allow", [])
before = len(allow)
s.setdefault("permissions", {})["allow"] = [a for a in allow if "sk-proj-" not in a]

p.write_text(json.dumps(s, indent=2, ensure_ascii=False) + "\n")

# Worker-only hooks: passed to each worker by night-shift.sh via `claude --settings`.
# 6h answer-question: may hold a question until Codex's 5h window resets.
# 1h review-gate: targeted review plus deterministic build/test verification.
sup = pathlib.Path.home() / ".claude" / "supervisor"
sup.mkdir(parents=True, exist_ok=True)
worker = {"hooks": {
    "Stop": [{"matcher": "", "hooks": [
        {"type": "command", "command": cmd("hooks/review-gate.sh"), "timeout": 3600}]}],
    "SessionStart": [{"matcher": "", "hooks": [
        {"type": "command", "command": cmd("hooks/safety-check.sh"), "timeout": 15}]}],
    "PreToolUse": [
        {"matcher": "Edit", "hooks": [
            {"type": "command", "command": cmd("hooks/write-gate.sh"), "timeout": 30}]},
        {"matcher": "Write", "hooks": [
            {"type": "command", "command": cmd("hooks/write-gate.sh"), "timeout": 30}]},
        {"matcher": "NotebookEdit", "hooks": [
            {"type": "command", "command": cmd("hooks/write-gate.sh"), "timeout": 30}]},
        # Bash is a file editor with extra steps. Without this the run's control state — the
        # pause, the director's decision about Codex, the terminal marker — was writable by the
        # very worker those files exist to hold, with one redirection.
        {"matcher": "Bash", "hooks": [
            {"type": "command", "command": cmd("hooks/write-gate.sh"), "timeout": 30},
            {"type": "command", "command": cmd("hooks/control-guard.sh"), "timeout": 30}]},
        {"matcher": "AskUserQuestion", "hooks": [
            {"type": "command", "command": cmd("hooks/answer-question.sh"), "timeout": 21600}]},
    ],
    # The other half of the control-state fence, and the half that does not guess.
    #
    # PreToolUse records what the run's control files look like; this compares them afterwards. A
    # file that moved across a shell command is treated as forged however it was written — which
    # is the only answer to a redirect spelling nobody anticipated or a filename built at runtime.
    "PostToolUse": [
        {"matcher": "Bash", "hooks": [
            {"type": "command", "command": cmd("hooks/control-guard.sh"), "timeout": 30}]},
    ],
}}
# The statusline in the WORKER settings too — it is the only source of Claude's rate limits.
#
# Claude Code hands `rate_limits` to the statusline command and nowhere else: there is no `claude
# usage`, and a subscription session exposes no headers to read. statusline.sh writes them to
# usage.json, which the watchdog, the review gate and the app all read to decide whether there is
# room to work. But `--settings` REPLACES the global file, so a worker rendered no statusline and
# refreshed nothing — usage.json was eight days stale on this machine while workers ran all night.
# With it here, every worker keeps it current, which is exactly when knowing the limits matters.
worker["statusLine"] = {"type": "command", "command": cmd("bin/statusline.sh")}
(sup / "worker-settings.json").write_text(json.dumps(worker, indent=2, ensure_ascii=False) + "\n")
print(f"statusLine set (global); supervisor hooks moved to worker-settings.json; "
      f"global de-polluted; removed {before - len(s['permissions']['allow'])} leaked-key entries")
EOF

mkdir -p ~/.claude/commands
# These are ours to update, but the file on disk may not be ours any more: somebody can have edited
# what /night says. That used to be a copy straight over the top — acceptable when a person pressed
# a button and watched it happen, and not acceptable now that the app installs itself at launch.
# Anything that differs from what we ship is kept beside it before it is replaced.
for c in deep-audit night queue; do
  dst=~/.claude/commands/$c.md
  if [ -f "$dst" ] && ! cmp -s "$ROOT/claude-commands/$c.md" "$dst"; then
    cp "$dst" "$dst.backup-$(date +%Y%m%d-%H%M%S)-$$"
    echo "backup: $dst.backup-*"
  fi
  cp "$ROOT/claude-commands/$c.md" "$dst"
done
echo "slash commands /deep-audit, /night, /queue installed"

mkdir -p ~/.local/bin
ln -sf "$ROOT/bin/night-shift.sh" ~/.local/bin/night-shift
ln -sf "$ROOT/bin/deep-audit.sh"  ~/.local/bin/deep-audit
ln -sf "$ROOT/bin/queue.sh"       ~/.local/bin/night-queue
ln -sf "$ROOT/bin/report-finding.sh" ~/.local/bin/report-finding
ln -sf "$ROOT/bin/worker-outcome.sh" ~/.local/bin/report-outcome
ln -sf "$ROOT/bin/trace.sh"          ~/.local/bin/night-trace
ln -sf "$ROOT/bin/artifact.sh"       ~/.local/bin/night-artifact
missing=""
for c in night-shift deep-audit night-queue report-finding report-outcome night-trace night-artifact; do
  [ -x ~/.local/bin/"$c" ] || missing="$missing $c"
done
[ -n "$missing" ] && echo "⚠️  не створено симлінки:$missing" || echo "terminal commands installed: night-shift, deep-audit, night-queue"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) echo "⚠️  ~/.local/bin не в PATH. Додай у ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# An older install left a learned-memory store at ~/.claude/supervisor/memory and a
# `supervisor-learn` / `night-memory` command. Nothing reads that store any more. The stale
# commands are removed so they cannot be run by habit; the files themselves are left alone,
# because they are the user's writing and deleting them is not this installer's call.
[ -f ~/.claude/commands/learn.md ] \
  && cp ~/.claude/commands/learn.md ~/.claude/commands/learn.md.backup-$(date +%Y%m%d-%H%M%S)-$$
rm -f ~/.local/bin/supervisor-learn ~/.local/bin/night-memory ~/.claude/commands/learn.md 2>/dev/null || true

if [ -d "$HOME/.claude/supervisor/memory" ]; then
  echo "ℹ️  ~/.claude/supervisor/memory більше не читається — файли лишились на диску недоторканими"
fi

if [ "$LEGACY_RESCUE_FAILED" = 1 ]; then
  echo ""
  echo "❌ Движок встановлено, але твої старі файли памʼяті лишились усередині нього." >&2
  echo "   Вони тут і нічого не видалено: $LEGACY_LESSONS" >&2
  echo "   Перенести їх у $STORE не вдалося — схоже, туди немає прав на запис." >&2
  echo "   Встановлення можна повторити кнопкою на екрані готовності, коли це буде полагоджено." >&2
  exit 1
fi

echo ""
echo "Готово. Перезапусти Claude Code, щоб хуки підхопились."
echo "Нічна зміна:    /night start <project-dir>  (або /night stop | /night status)"
echo "Глибокий аудит: /deep-audit  (або $ROOT/bin/deep-audit.sh)"
