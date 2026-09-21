#!/bin/bash
set -u
BIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$BIN_DIR/.." && pwd)"
SUP_DIR="$ROOT/supervisor"
. "$BIN_DIR/supervisor-lib.sh"
mkdir -p "$SUP_INSTANCES"

cleanup_global_marker() { _any_instance || rm -f "$SUP_STATE/night-mode"; }

# A start that does not happen has to say so — to the director AND to the log.
#
# The workspace crash was invisible for exactly this reason: the only refusal path wrote one line to
# stderr, the app swallowed it when its own timeout fired first, and `supervisor.log` held nothing
# at all for that project. Reading the sources was the only way to learn what had happened.
refuse_start() {   # $1=project dir, $2=reason (may be several lines)
  printf '❌ %s\n' "$2" >&2
  mkdir -p "$SUP_STATE" 2>/dev/null || true
  { printf '%s [start] REFUSED %s\n' "$(date '+%F %T')" "$1"
    printf '%s\n' "$2" | sed 's/^/    /'
  } >> "$SUP_STATE/supervisor.log" 2>/dev/null || true
}

append_client_context() {
  local file="${SUPERVISOR_CHAT_CONTEXT_FILE:-}"
  [ -n "$file" ] && [ -s "$file" ] || return 0
  echo; echo "# APP CHAT CONTEXT"
  cat "$file"
}

set_direct_chat_mode() { # $1 = instance dir
  if [ -n "${SUPERVISOR_CHAT_CONTEXT_FILE:-}" ]; then
    : > "$1/direct-chat"
  else
    rm -f "$1/direct-chat"
  fi
}

extra_add_dir_flags() {
  local file="${SUPERVISOR_EXTRA_DIRS_FILE:-}" dir=""
  [ -n "$file" ] && [ -s "$file" ] || return 0
  while IFS= read -r dir || [ -n "$dir" ]; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    printf -- '--add-dir %s ' "$(shq "$(canon_path "$dir")")"
  done < "$file"
}

skills_bg() {  # $1 = project dir
  local proj="$1"
  [ "${SUPERVISOR_SKILL_AUTONOMOUS:-1}" = 1 ] || return 0
  [ -n "${SUPERVISOR_NO_SKILL_PICK:-}" ] && return 0   # tests / opt-out
  [ -n "$proj" ] && [ -d "$proj" ] || return 0
  nohup bash -c "
    $(shq "$BIN_DIR/skill-resolver.sh") index          >> $(shq "$SUP_STATE/supervisor.log") 2>&1
    $(shq "$BIN_DIR/skill-resolver.sh") suggest $(shq "$proj") --record >> $(shq "$SUP_STATE/supervisor.log") 2>&1
    $(shq "$BIN_DIR/skill-resolver.sh") resolve $(shq "$proj") >> $(shq "$SUP_STATE/supervisor.log") 2>&1
  " >/dev/null 2>&1 &
}

stop_instance() {  # $1 = slug
  local slug="$1" idir proj branch session
  idir="$(instance_dir "$slug")"; [ -d "$idir" ] || return 0
  proj="$(cat "$idir/project" 2>/dev/null)"
  branch="$(cat "$idir/branch" 2>/dev/null || true)"
  session="$(cat "$idir/session" 2>/dev/null || session_name "$slug")"
  [ -f "$idir/watchdog.pid" ] && kill "$(cat "$idir/watchdog.pid")" 2>/dev/null
  local rid rdir a
  rid="$(cat "$idir/run-id" 2>/dev/null || true)"
  if [ -n "$rid" ]; then
    rdir="$(run_dir "$rid")"; mkdir -p "$rdir" 2>/dev/null || true
    for a in reports evidence report scope-violation.json findings.jsonl; do
      [ -e "$idir/$a" ] && cp -R "$idir/$a" "$rdir/" 2>/dev/null || true
    done
  fi
  rm -rf "$idir"   # removing the dir makes the watchdog loop exit
  echo "☀️ Зупинено: $proj"
  echo "   сесія '$session' залишена (tmux attach -t $session; закрити: tmux kill-session -t $session)"
  if [ -n "$branch" ]; then
    echo "   🌿 гілка $branch — git -C \"$proj\" log --oneline ..$branch | merge | branch -D"
  fi
}

stop_legacy() {  # clean up a pre-refactor single 'night' session
  [ -f "$SUP_STATE/watchdog.pid" ] && { kill "$(cat "$SUP_STATE/watchdog.pid")" 2>/dev/null; rm -f "$SUP_STATE/watchdog.pid"; }
  local proj branch
  proj="$(cat "$SUP_STATE/night-project" 2>/dev/null || true)"
  branch="$(cat "$SUP_STATE/night-branch" 2>/dev/null || true)"
  rm -f "$SUP_STATE/night-project" "$SUP_STATE/night-branch" "$SUP_STATE/night-standards.md" "$SUP_STATE/paused-for-limit.json"
  echo "☀️ Зупинено легасі-сесію (single 'night')."
  [ -n "$branch" ] && echo "   🌿 гілка $branch у $proj"
  echo "   tmux 'night' залишено (закрити: tmux kill-session -t night)"
}

cmd="${1:-status}"; [ $# -gt 0 ] && shift

case "$cmd" in
  start)
    NO_ATTACH=0; DIRARG=""
    _want_branch=0
    for a in "$@"; do
      if [ "$_want_branch" = 1 ]; then SUPERVISOR_WORK_BRANCH="$a"; _want_branch=0; continue; fi
      case "$a" in
        --no-attach) NO_ATTACH=1 ;;
        --branch) _want_branch=1 ;;
        --branch=*) SUPERVISOR_WORK_BRANCH="${a#--branch=}" ;;
        *) [ -z "$DIRARG" ] && DIRARG="$a" ;;
      esac
    done
    export SUPERVISOR_WORK_BRANCH
    PROJECT_DIR="$(canon_path "${DIRARG:-$PWD}")"
    [ -d "$PROJECT_DIR" ] || { echo "❌ Проєкт не знайдено: ${DIRARG:-$PWD}" >&2; exit 1; }
    command -v tmux >/dev/null 2>&1 || { echo "❌ tmux не встановлено (brew install tmux)" >&2; exit 1; }
    [ -s "$SUP_DIR/STANDARDS.md" ] || { echo "❌ нема/порожній $SUP_DIR/STANDARDS.md" >&2; exit 1; }

    # A folder full of repositories is a workspace, and a workspace is not a project.
    #
    # Checked here, before the instance directory is cleared and before any tmux session is
    # touched: a refusal must not cost the director anything that was already working.
    # `workspace_container_reason` answers an established repository without walking the tree, so
    # an ordinary start pays nothing for this.
    if _container="$(workspace_container_reason "$PROJECT_DIR")"; then
      refuse_start "$PROJECT_DIR" "$_container"
      exit 1
    fi

    if _legacy_present && ! _any_instance; then
      echo "⚠️ Активна стара (легасі) нічна сесія. Спершу мігруй, щоб не втратити нагляд:" >&2
      echo "      night-shift stop --all && tmux kill-session -t night" >&2
      echo "   потім повтори: night-shift start \"$PROJECT_DIR\"" >&2
      exit 1
    fi

    SLUG="$(slug_for "$PROJECT_DIR")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"

    if [ -d "$IDIR" ] && tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "🌙 Вже запущено для цього проєкту (сесія $SESSION)."
      echo "   Підключитись: night-shift attach \"$PROJECT_DIR\""
      exit 0
    fi
    if [ -d "$IDIR" ]; then
      [ -f "$IDIR/watchdog.pid" ] && kill "$(cat "$IDIR/watchdog.pid")" 2>/dev/null
      rm -rf "$IDIR"
    fi
    tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION" 2>/dev/null

    STD_TMP="$(mktemp)"
    {
      cat "$SUP_DIR/STANDARDS.md"
      echo
      worker_language_rule
      append_client_context
    } > "$STD_TMP" 2>/dev/null
    [ -s "$STD_TMP" ] || { echo "❌ не вдалося згенерувати system prompt. Старт скасовано." >&2; rm -f "$STD_TMP"; exit 1; }

    ORIG_REF=""; ORIG_HEAD=""; BRANCH=""; CHECKPOINTED=0; BRANCH_CREATED=0
    if command -v git >/dev/null 2>&1; then
      _top="$(cd "$PROJECT_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)"
      GIT_CREATED=0
      if [ "$_top" != "$PROJECT_DIR" ]; then
        # Connecting a folder is not consent to change it.
        #
        # The engine used to answer "no git here?" with "then I will make one" — in a folder of
        # videos, in a pile of documents, in somebody's export. The director said it plainly: offer,
        # do not create. So a folder without git is now a wall with a door rather than a silent
        # `git init`, and the door is a button in Bulava (exit code 76 is what it listens for).
        #
        # The wall is not politeness, it is the rollback: a night that writes into a folder with no
        # baseline has no way back, and nothing to show a review. Read-only work needs no git and
        # is not affected — this gate stands in front of an autonomous run.
        if ! git_consent_given "$PROJECT_DIR"; then
          refuse_start "$PROJECT_DIR" "У цій теці немає git, а без нього нічній зміні нема куди відкочуватись і нема що показати на перевірці.
Створити тут git? Bulava запитає це кнопкою — або дозволь вручну:
      night-shift allow-git \"$PROJECT_DIR\"
Якщо git тут не потрібен (документи, відео, чужий експорт) — просто не запускай у ній автономну зміну."
          rm -f "$STD_TMP"; exit 76
        fi
        if ( cd "$PROJECT_DIR" && git init -q ); then
          GIT_CREATED=1
          # Written before the first `git add`, so node_modules and a python venv never reach the
          # object store at all. `.git/info/exclude`, not the director's `.gitignore` — our
          # checkpoint's housekeeping must not show up as a change in their project.
          seed_heavy_excludes "$PROJECT_DIR"
          echo "$(date '+%F %T') [start] '$PROJECT_DIR' had no git of its own — created one, with the director's recorded consent" >> "$SUP_STATE/supervisor.log"
        else
          refuse_start "$PROJECT_DIR" "Не вдалося створити git-репозиторій у цій теці — без нього нічній зміні нема куди відкочуватись."
          rm -f "$STD_TMP"; exit 1
        fi
      fi
      ORIG_REF="$(cd "$PROJECT_DIR" && git symbolic-ref --short HEAD 2>/dev/null || true)"
      [ -n "$ORIG_REF" ] || ORIG_REF="$(resolve_base_sha "$PROJECT_DIR")"
      ORIG_HEAD="$(resolve_base_sha "$PROJECT_DIR")"
      exclude_uncommitted_nested() {   # stdin = git's stderr; returns 0 if it excluded anything
        local paths; paths="$(sed -n "s/^error: '\(.*\)' does not have a commit checked out$/\1/p")"
        [ -n "$paths" ] || return 1
        mkdir -p .git/info
        printf '%s\n' "$paths" | sed 's#/*$#/#' >> .git/info/exclude
        echo "⚠️ git: у теці є вкладені репозиторії без комітів — не беру їх у checkpoint: $(printf '%s' "$paths" | tr '\n' ' ')" >&2
        return 0
      }
      harness_exclude() {
        local gitdir ex pat
        gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 0
        ex="$gitdir/info/exclude"
        mkdir -p "$gitdir/info" 2>/dev/null || return 0
        for pat in 'AUDIT-*.md' 'REVIEW-DEBT.md'; do
          grep -qxF "$pat" "$ex" 2>/dev/null || printf '%s\n' "$pat" >> "$ex" 2>/dev/null || true
        done
      }
      do_checkpoint() {   # 0 committed · 1 failed · 2 nothing to commit · 3 too big to checkpoint
        harness_exclude
        # Measured BEFORE `git add`, because `git add` is where the cost is paid: once it has
        # written half a gigabyte of objects the damage is done, and the app that was waiting for
        # this start has already given up.
        local over; over="$(checkpoint_overrun .)"
        if [ -n "$over" ]; then printf '%s\n' "$over" >&2; return 3; fi

        local err rc
        err="$(git add -A 2>&1 >/dev/null)"; rc=$?
        if printf '%s' "$err" | grep -q 'does not have a commit checked out'; then
          printf '%s' "$err" | exclude_uncommitted_nested || return 1
          git add -A 2>/dev/null || return 1
        elif [ "$rc" != 0 ] || printf '%s' "$err" | grep -q '^fatal:'; then
          printf '%s\n' "$err" >&2
          return 1                                # a failed stage must abort, not "succeed"
        fi
        for _hf in AUDIT-*.md REVIEW-DEBT.md; do
          git ls-files --error-unmatch "$_hf" >/dev/null 2>&1 && git rm --cached --quiet "$_hf" 2>/dev/null || true
        done

        local secrets; secrets="$(mktemp)" || return 1
        if ! staged_secret_paths_z > "$secrets"; then
          rm -f "$secrets"
          echo "❌ secret-scan: не зміг перевірити застейджені файли — наосліп не комічу." >&2
          return 1
        fi
        if [ -s "$secrets" ]; then
          while IFS= read -r -d "" f; do
            [ -n "$f" ] && git rm --cached -q -f -- "$f" 2>/dev/null
          done < "$secrets"
          { echo ""; echo "## $(date '+%F %T') — secret-scan (night-shift)"; \
            echo "НЕ закомічено (схоже на секрети). Додай у .gitignore:"; \
            tr "\0" "\n" < "$secrets" | grep -v '^$' | sed 's/^/- /'; } >> BLOCKED.md 2>/dev/null
          mkdir -p .git/info && tr "\0" "\n" < "$secrets" | grep -v '^$' >> .git/info/exclude 2>/dev/null
          echo "⚠️ secret-scan: не комічу можливі секрети (див. BLOCKED.md): $(tr "\0" " " < "$secrets")" >&2
          local again; again="$(mktemp)" || { rm -f "$secrets"; return 1; }
          if ! staged_secret_paths_z > "$again" || [ -s "$again" ]; then
            rm -f "$secrets" "$again"; return 1
          fi
          rm -f "$again"
        fi
        rm -f "$secrets"

        git diff --cached --quiet 2>/dev/null && return 2   # nothing (non-secret) to commit
        git -c user.email=night-shift@local -c user.name=night-shift commit -qm "$1" >/dev/null 2>&1 || return 1
        return 0
      }
      abort_checkpoint() {  # $1=which
        local msg="git: checkpoint ($1) не вдався — старт скасовано, git-страховки нема."
        # A repository this run created seconds ago, that never reached a commit, holds nothing but
        # our own half-finished index. Leaving it behind is what turned one failed start into a
        # folder that failed the same way every time afterwards — and into a 495 MB .git with the
        # director's secrets in its index. Anything older than this run is left strictly alone.
        if [ "${GIT_CREATED:-0}" = 1 ] && [ -d "$PROJECT_DIR/.git" ] \
           && ! ( cd "$PROJECT_DIR" && git rev-parse HEAD >/dev/null 2>&1 ); then
          rm -rf "$PROJECT_DIR/.git"
          msg="$msg Прибрав .git, який щойно створив — тека лишилась такою, якою була."
        else
          msg="$msg Перевір репо вручну."
        fi
        refuse_start "$PROJECT_DIR" "$msg"
        rm -f "$STD_TMP"; exit 1
      }
      if ! ( cd "$PROJECT_DIR" && git rev-parse HEAD >/dev/null 2>&1 ); then
        ( cd "$PROJECT_DIR" && do_checkpoint "Initial commit (before night shift)" ); rc=$?
        [ "$rc" = 1 ] && abort_checkpoint "initial"
        [ "$rc" = 3 ] && abort_checkpoint "initial — тека завелика"
        [ "$rc" = 0 ] && CHECKPOINTED=1
        # An empty folder stages nothing, so this left the repository with no commit at all — and
        # then there is no commit for the run to be measured against. A night that ended with five
        # commits and forty-four tests was reported as having changed nothing, for exactly this.
        # An empty first commit costs nothing and gives every later diff something to stand on.
        if [ "$rc" = 2 ]; then
          ( cd "$PROJECT_DIR" && git -c user.email=night-shift@local -c user.name=night-shift \
              commit -q --allow-empty -m "Initial commit (before night shift)" >/dev/null 2>&1 ) \
            || abort_checkpoint "initial (empty folder)"
          CHECKPOINTED=1
        fi
      elif ( cd "$PROJECT_DIR" && { ! git diff-index --quiet HEAD -- 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard | head -1)" ]; } ); then
        ( cd "$PROJECT_DIR" && do_checkpoint "Checkpoint before night shift $(date '+%F %H:%M')" ); rc=$?
        [ "$rc" = 1 ] && abort_checkpoint "checkpoint"
        [ "$rc" = 3 ] && abort_checkpoint "checkpoint — тека завелика"
        [ "$rc" = 0 ] && CHECKPOINTED=1
      fi
      cur="$(cd "$PROJECT_DIR" && git symbolic-ref --short HEAD 2>/dev/null || true)"
      action="$(choose_branch_action "$cur")"
      case "${action%% *}" in
        reuse)
          BRANCH="${action#reuse }"
          ;;
        inplace)
          BRANCH=""
          echo "🌿 Гілку не створюю — HEAD відчеплений, працюю на місці."
          ;;
        use)
          BRANCH="${action#use }"
          if [ "$cur" = "$BRANCH" ]; then
            :   # already there
          elif ( cd "$PROJECT_DIR" && git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null ); then
            if ! ( cd "$PROJECT_DIR" && git checkout -q "$BRANCH" >/dev/null 2>&1 ); then
              echo "❌ git: не вдалося перейти на гілку $BRANCH. Старт скасовано." >&2
              ( cd "$PROJECT_DIR" && git checkout -q "$ORIG_REF" 2>/dev/null; [ "$CHECKPOINTED" = 1 ] && [ -n "$ORIG_HEAD" ] && git reset --soft "$ORIG_HEAD" 2>/dev/null ) || true
              rm -f "$STD_TMP"; exit 1
            fi
          else
            if ! ( cd "$PROJECT_DIR" && git checkout -qb "$BRANCH" >/dev/null 2>&1 ) \
               || [ "$(cd "$PROJECT_DIR" && git symbolic-ref --short HEAD 2>/dev/null)" != "$BRANCH" ]; then
              echo "❌ git: не вдалося створити гілку $BRANCH. Старт скасовано." >&2
              ( cd "$PROJECT_DIR" && git checkout -q "$ORIG_REF" 2>/dev/null; [ "$CHECKPOINTED" = 1 ] && [ -n "$ORIG_HEAD" ] && git reset --soft "$ORIG_HEAD" 2>/dev/null ) || true
              rm -f "$STD_TMP"; exit 1
            fi
            BRANCH_CREATED=1
            echo "🌿 Створив гілку $BRANCH — на замовлення бригадира."
          fi
          ;;
        *)
          BRANCH="night/$(date +%Y%m%d-%H%M%S)-$$"
          if ! ( cd "$PROJECT_DIR" && git checkout -qb "$BRANCH" >/dev/null 2>&1 ) \
             || [ "$(cd "$PROJECT_DIR" && git symbolic-ref --short HEAD 2>/dev/null)" != "$BRANCH" ]; then
            echo "❌ git: не вдалося створити гілку $BRANCH. Старт скасовано." >&2
            ( cd "$PROJECT_DIR" && git checkout -q "$ORIG_REF" 2>/dev/null; [ "$CHECKPOINTED" = 1 ] && [ -n "$ORIG_HEAD" ] && git reset --soft "$ORIG_HEAD" 2>/dev/null ) || true
            rm -f "$STD_TMP"; exit 1
          fi
          BRANCH_CREATED=1
          ;;
      esac
    fi

    rollback_start() {
      tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION" 2>/dev/null
      [ -f "$IDIR/watchdog.pid" ] && kill "$(cat "$IDIR/watchdog.pid")" 2>/dev/null
      if command -v git >/dev/null 2>&1 && [ -n "$ORIG_REF" ]; then
        ( cd "$PROJECT_DIR" \
          && git checkout -q "$ORIG_REF" 2>/dev/null \
          && { [ -n "$BRANCH" ] && [ "$BRANCH_CREATED" = 1 ] && git branch -D "$BRANCH" >/dev/null 2>&1; true; } \
          && { [ "$CHECKPOINTED" = 1 ] && [ -n "$ORIG_HEAD" ] && git reset --soft "$ORIG_HEAD" 2>/dev/null; true; } ) || true
      fi
      rm -rf "$IDIR"; cleanup_global_marker
    }

    mkdir -p "$IDIR"
    printf '%s\n' "$PROJECT_DIR" > "$IDIR/project"
    printf '%s\n' "$SESSION"     > "$IDIR/session"
    [ -n "$BRANCH" ] && printf '%s\n' "$BRANCH" > "$IDIR/branch"
    mv "$STD_TMP" "$IDIR/standards.md"
    : > "$IDIR/started-at"
    RUN_ID="$(uuidgen 2>/dev/null || printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}")"
    printf '%s\n' "$RUN_ID" > "$IDIR/run-id"
    [ -s "$IDIR/run-id" ] || { echo "❌ не вдалося записати run-id (BP-2). Відкат." >&2; rollback_start; exit 1; }
    skills_bg "$PROJECT_DIR"
    set_direct_chat_mode "$IDIR"
    rm -f "$IDIR/handshake-ok" "$IDIR/claude-session-id"
    BASE_SHA="$(resolve_base_sha "$PROJECT_DIR")"
    [ -n "$BASE_SHA" ] && printf '%s\n' "$BASE_SHA" > "$IDIR/base-sha"
    # …and the same for every other repository this run may write in, or a night that does its work
    # in a sibling repository is measured as having done nothing.
    record_extra_repos "$IDIR"
    [ -n "$BRANCH" ] && printf '%s\n' "$BRANCH" > "$IDIR/base-branch"
    ln -sf "$BIN_DIR/worker-outcome.sh" "$IDIR/report-outcome" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-outcome.sh" "$IDIR/report-outcome" 2>/dev/null || true
    ln -sf "$BIN_DIR/report-finding.sh" "$IDIR/report-finding" 2>/dev/null \
      || cp -f "$BIN_DIR/report-finding.sh" "$IDIR/report-finding" 2>/dev/null || true
    ln -sf "$BIN_DIR/challenge-criterion.sh" "$IDIR/challenge-criterion" 2>/dev/null \
      || cp -f "$BIN_DIR/challenge-criterion.sh" "$IDIR/challenge-criterion" 2>/dev/null || true
    ln -sf "$BIN_DIR/add-check.sh" "$IDIR/add-check" 2>/dev/null \
      || cp -f "$BIN_DIR/add-check.sh" "$IDIR/add-check" 2>/dev/null || true
    ln -sf "$BIN_DIR/consult-codex.sh" "$IDIR/consult-codex" 2>/dev/null \
      || cp -f "$BIN_DIR/consult-codex.sh" "$IDIR/consult-codex" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-task-boundary.sh" "$IDIR/task-boundary" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-task-boundary.sh" "$IDIR/task-boundary" 2>/dev/null || true
    ln -sf "$BIN_DIR/history.sh" "$IDIR/history" 2>/dev/null \
      || cp -f "$BIN_DIR/history.sh" "$IDIR/history" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-capture.sh" "$IDIR/capture" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-capture.sh" "$IDIR/capture" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-ui.sh" "$IDIR/ui" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-ui.sh" "$IDIR/ui" 2>/dev/null || true
    ln -sf "$BIN_DIR/web-shot.py" "$IDIR/web-shot" 2>/dev/null \
      || cp -f "$BIN_DIR/web-shot.py" "$IDIR/web-shot" 2>/dev/null || true
    ln -sf "$BIN_DIR/web-video.py" "$IDIR/web-video" 2>/dev/null \
      || cp -f "$BIN_DIR/web-video.py" "$IDIR/web-video" 2>/dev/null || true
    ln -sf "$BIN_DIR/artifact.sh" "$IDIR/artifact" 2>/dev/null \
      || cp -f "$BIN_DIR/artifact.sh" "$IDIR/artifact" 2>/dev/null || true

    warn_if_paid_api_env "$SUP_STATE/supervisor.log" || true
    printf 'subscription\n' > "$IDIR/auth-mode"
    # The same choices the launch line below carries, written where a later process can read them.
    # A preflight or a consultation started by the app is not a child of this tmux session.
    run_env_save "$IDIR"
    if [ -n "${SUPERVISOR_CLAUDE_CMD:-}" ]; then
      RAW_LAUNCH="$SUPERVISOR_CLAUDE_CMD"
    else
      EFFORT_FLAG="$(claude_effort_launch_flag)"
      MODEL_FLAG=""; [ -n "${SUPERVISOR_CLAUDE_MODEL:-}" ] && MODEL_FLAG="--model $(shq "$SUPERVISOR_CLAUDE_MODEL") "
      SETTINGS_FLAG=""; WORKER_SETTINGS="$SUP_STATE/worker-settings.json"; [ -f "$WORKER_SETTINGS" ] && SETTINGS_FLAG="--settings $(shq "$WORKER_SETTINGS") "
      EXTRA_ADD_FLAGS="$(extra_add_dir_flags)"
      RAW_LAUNCH="claude ${EFFORT_FLAG}${MODEL_FLAG}${SETTINGS_FLAG}--permission-mode $(shq "${SUPERVISOR_PERMISSION_MODE:-auto}") --add-dir $(shq "$IDIR") ${EXTRA_ADD_FLAGS}--append-system-prompt-file $(shq "$IDIR/standards.md"); $(shq "$BIN_DIR/night-shift.sh") stop $(shq "$PROJECT_DIR")"
    fi
    LAUNCH="$(subscription_env_prefix) ORCHESTRATOR_RUN_ID=$(shq "$RUN_ID") $(run_env_stamp) $RAW_LAUNCH"
    if [ -z "${SUPERVISOR_TMUX_FAIL:-}" ]; then
      tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR" "$LAUNCH"
    fi
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "❌ tmux-сесію не створено. Відкат." >&2; rollback_start; exit 1
    fi

    WD_CMD="${SUPERVISOR_WATCHDOG_CMD:-$BIN_DIR/watchdog.sh}"
    nohup "$WD_CMD" "$SLUG" >/dev/null 2>&1 &
    echo $! > "$IDIR/watchdog.pid"
    sleep 1
    if ! kill -0 "$(cat "$IDIR/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
      echo "❌ watchdog не піднявся. Відкат." >&2; rollback_start; exit 1
    fi

    await_handshake "$IDIR" "$SLUG" || { rollback_start; exit 1; }

    touch "$SUP_STATE/night-mode"

    echo "🌙 Нічна зміна: $PROJECT_DIR"
    echo "   Сесія:        $SESSION"
    [ -n "$BRANCH" ] && echo "   Гілка:        $BRANCH $([ "$BRANCH_CREATED" = 1 ] && echo '(нова)' || echo '(існуюча, переви­користано)')"
    echo "   Зупинити:     night-shift stop \"$PROJECT_DIR\"  (або exit/Ctrl-D у Клода)"

    if [ "$NO_ATTACH" = 0 ] && [ -z "${SUPERVISOR_CLAUDE_CMD:-}" ] && [ -t 0 ] && [ -t 1 ]; then
      echo "   (під'єднуюсь… Ctrl-b d — від'єднатися, робота лишиться у фоні)"
      exec tmux attach -t "$SESSION"
    fi
    echo "   Підключитись: night-shift attach \"$PROJECT_DIR\""
    ;;

  scan-folder)
    # One scanner for both.
    #
    # The rule for «what kind of folder is this» lived twice — in the engine and in the application —
    # and drifted in three places at once: depth was counted from different things, one of them
    # treated a broken store as a repository and the other did not, and nested dependencies leaked
    # into the engine's list. The suite found every divergence, and each one meant the application
    #
    # So now only the engine answers and the application asks. The output is machine-readable and
    #   kind=repo|container|plain|storage|unknown
    #   complete=yes|no
    #   why=<why the survey is incomplete>
    #   repo<TAB><path>            — one line per repository found
    #   storage<TAB>bare|broken<TAB><path>
    _d="$(canon_path "${1:-$PWD}")"
    [ -d "$_d" ] || { echo "kind=unknown"; echo "complete=no"; echo "why=теки не знайдено"; exit 0; }

    _self="$(git_storage_kind "$_d")"
    case "$_self" in
      bare|broken)
        echo "kind=storage"; echo "complete=yes"
        printf 'storage\t%s\t%s\n' "$_self" "$_d"
        exit 0 ;;
    esac
    _top="$(cd "$_d" && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "$_top" = "$_d" ] && ( cd "$_d" && git rev-parse --verify --quiet HEAD >/dev/null 2>&1 ); then
      echo "kind=repo"; echo "complete=yes"; exit 0
    fi
    # A subfolder of someone else's repository. Git must not be created here — it would make two
    # histories in one tree, and the outer one would stop describing its own contents.
    if [ -n "$_top" ] && [ "$_top" != "$_d" ]; then
      echo "kind=inside"; echo "complete=yes"
      printf 'repo\t%s\n' "$_top"
      exit 0
    fi

    _found="$(nested_repos_in "$_d")"; _rc=$?
    _why="$(printf '%s\n' "$_found" | sed -n 's/^?//p' | head -1)"
    _repos="$(printf '%s\n' "$_found" | grep '^/' || true)"
    _stores="$(printf '%s\n' "$_found" | sed -n 's/^!//p')"
    _n=0; [ -n "$_repos" ] && _n="$(printf '%s\n' "$_repos" | grep -c .)"

    if [ -n "$_stores" ]; then echo "kind=storage"
    elif [ "$_n" -gt 0 ]; then
      # A repository with its own history and one nested checkout is a project, not a collection.
      if [ "$_top" = "$_d" ] && [ "$_n" -lt 2 ]; then echo "kind=repo"; else echo "kind=container"; fi
    elif [ "$_rc" = 3 ]; then echo "kind=unknown"
    else echo "kind=plain"
    fi
    [ "$_rc" = 3 ] && { echo "complete=no"; [ -n "$_why" ] && echo "why=$_why"; } || echo "complete=yes"
    [ -n "$_repos" ] && printf '%s\n' "$_repos" | while IFS= read -r _r; do
      [ -n "$_r" ] && printf 'repo\t%s\n' "$_r"
    done
    [ -n "$_stores" ] && printf '%s\n' "$_stores" | while IFS= read -r _s; do
      [ -n "$_s" ] && printf 'storage\t%s\t%s\n' "${_s%% *}" "${_s#* }"
    done
    exit 0
    ;;

  allow-git)
    # The director agreed that git may appear in this folder. The consent lives in the run's state,
    # not in the folder: saying yes must write nothing into anybody's files by itself.
    _d="$(canon_path "${1:-$PWD}")"
    [ -d "$_d" ] || { echo "❌ Теки не знайдено: ${1:-$PWD}" >&2; exit 1; }
    if _why="$(workspace_container_reason "$_d")"; then
      echo "❌ Тут git не потрібен і не буде:" >&2
      printf '%s\n' "$_why" >&2
      exit 1
    fi
    if ( cd "$_d" && git rev-parse --show-toplevel 2>/dev/null | grep -qx "$_d" ); then
      echo "🌿 У цій теці вже є свій git — згода не потрібна."
      exit 0
    fi
    git_consent_record "$_d" || { echo "❌ не зміг записати згоду" >&2; exit 1; }
    # `${_d}`, not `$_d`: a «»» follows, and bash 3.2 — knowing nothing of UTF-8 — takes the first
    # byte of that character into the variable name. The result is `_d\xC2`, which nobody set, and
    # under `set -u` the whole subshell dies with «unbound variable». The braces end the name.
    echo "🌿 Гаразд: створю git у «${_d}», коли там почнеться робота."
    echo "$(date '+%F %T') [allow-git] consent recorded for '$_d'" >> "$SUP_STATE/supervisor.log"
    ;;

  resume)
    if [ "${SUPERVISOR_ENABLE_RESUME:-0}" != 1 ]; then
      echo "❌ resume вимкнено (експериментально; потрібен надійний session-id + транзакційний стан). Використай свіжого воркера." >&2
      exit 2
    fi
    NO_ATTACH=0; RPOS=()
    for a in "$@"; do
      case "$a" in --no-attach) NO_ATTACH=1 ;; *) RPOS+=("$a") ;; esac
    done
    PROJECT_DIR="$(canon_path "${RPOS[0]:-$PWD}")"
    RESUME_SID="${RPOS[1]:-}"
    RESUME_BRANCH="${RPOS[2]:-}"; [ "$RESUME_BRANCH" = "-" ] && RESUME_BRANCH=""
    [ -d "$PROJECT_DIR" ] || { echo "❌ Проєкт не знайдено: ${RPOS[0]:-$PWD}" >&2; exit 1; }
    [ -n "$RESUME_SID" ] || { echo "❌ resume: не передано Claude session id" >&2; exit 1; }
    command -v tmux >/dev/null 2>&1 || { echo "❌ tmux не встановлено" >&2; exit 1; }
    [ -s "$SUP_DIR/STANDARDS.md" ] || { echo "❌ нема/порожній $SUP_DIR/STANDARDS.md" >&2; exit 1; }

    SLUG="$(slug_for "$PROJECT_DIR")"; IDIR="$(instance_dir "$SLUG")"; SESSION="$(session_name "$SLUG")"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "🌙 Сесія вже жива для цього проєкту — resume не потрібен ($SESSION)."; exit 0
    fi
    if [ -d "$IDIR" ]; then
      [ -f "$IDIR/watchdog.pid" ] && kill "$(cat "$IDIR/watchdog.pid")" 2>/dev/null
      rm -rf "$IDIR"
    fi

    if command -v git >/dev/null 2>&1 && [ -n "$RESUME_BRANCH" ]; then
      if ( cd "$PROJECT_DIR" && git rev-parse --verify "$RESUME_BRANCH" >/dev/null 2>&1 ); then
        ( cd "$PROJECT_DIR" && git checkout -q "$RESUME_BRANCH" 2>/dev/null ) \
          || echo "⚠️ resume: не перемкнувся на '$RESUME_BRANCH' (незакоммічені зміни?) — продовжую на поточній" >&2
      else
        echo "⚠️ resume: гілки '$RESUME_BRANCH' нема — продовжую на поточній" >&2
      fi
    fi

    STD_TMP="$(mktemp)"
    {
      cat "$SUP_DIR/STANDARDS.md"; echo
      worker_language_rule
      append_client_context
    } > "$STD_TMP" 2>/dev/null
    [ -s "$STD_TMP" ] || { echo "❌ не вдалося згенерувати system prompt" >&2; rm -f "$STD_TMP"; exit 1; }

    mkdir -p "$IDIR"
    printf '%s\n' "$PROJECT_DIR" > "$IDIR/project"
    printf '%s\n' "$SESSION"     > "$IDIR/session"
    CUR_BRANCH="$(cd "$PROJECT_DIR" && git symbolic-ref --short HEAD 2>/dev/null || true)"
    [ -n "$CUR_BRANCH" ] && { printf '%s\n' "$CUR_BRANCH" > "$IDIR/branch"; printf '%s\n' "$CUR_BRANCH" > "$IDIR/base-branch"; }
    mv "$STD_TMP" "$IDIR/standards.md"
    : > "$IDIR/started-at"
    RUN_ID="$(uuidgen 2>/dev/null || printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}")"
    printf '%s\n' "$RUN_ID" > "$IDIR/run-id"
    set_direct_chat_mode "$IDIR"
    rm -f "$IDIR/handshake-ok" "$IDIR/claude-session-id"
    BASE_SHA="$(resolve_base_sha "$PROJECT_DIR")"
    [ -n "$BASE_SHA" ] && printf '%s\n' "$BASE_SHA" > "$IDIR/base-sha"
    record_extra_repos "$IDIR"
    ln -sf "$BIN_DIR/worker-outcome.sh" "$IDIR/report-outcome" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-outcome.sh" "$IDIR/report-outcome" 2>/dev/null || true
    ln -sf "$BIN_DIR/report-finding.sh" "$IDIR/report-finding" 2>/dev/null \
      || cp -f "$BIN_DIR/report-finding.sh" "$IDIR/report-finding" 2>/dev/null || true
    ln -sf "$BIN_DIR/challenge-criterion.sh" "$IDIR/challenge-criterion" 2>/dev/null \
      || cp -f "$BIN_DIR/challenge-criterion.sh" "$IDIR/challenge-criterion" 2>/dev/null || true
    ln -sf "$BIN_DIR/add-check.sh" "$IDIR/add-check" 2>/dev/null \
      || cp -f "$BIN_DIR/add-check.sh" "$IDIR/add-check" 2>/dev/null || true
    ln -sf "$BIN_DIR/consult-codex.sh" "$IDIR/consult-codex" 2>/dev/null \
      || cp -f "$BIN_DIR/consult-codex.sh" "$IDIR/consult-codex" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-task-boundary.sh" "$IDIR/task-boundary" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-task-boundary.sh" "$IDIR/task-boundary" 2>/dev/null || true
    ln -sf "$BIN_DIR/history.sh" "$IDIR/history" 2>/dev/null \
      || cp -f "$BIN_DIR/history.sh" "$IDIR/history" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-capture.sh" "$IDIR/capture" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-capture.sh" "$IDIR/capture" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-ui.sh" "$IDIR/ui" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-ui.sh" "$IDIR/ui" 2>/dev/null || true
    ln -sf "$BIN_DIR/web-shot.py" "$IDIR/web-shot" 2>/dev/null \
      || cp -f "$BIN_DIR/web-shot.py" "$IDIR/web-shot" 2>/dev/null || true
    ln -sf "$BIN_DIR/web-video.py" "$IDIR/web-video" 2>/dev/null \
      || cp -f "$BIN_DIR/web-video.py" "$IDIR/web-video" 2>/dev/null || true
    ln -sf "$BIN_DIR/artifact.sh" "$IDIR/artifact" 2>/dev/null \
      || cp -f "$BIN_DIR/artifact.sh" "$IDIR/artifact" 2>/dev/null || true

    warn_if_paid_api_env "$SUP_STATE/supervisor.log" || true
    printf 'subscription\n' > "$IDIR/auth-mode"
    # The same choices the launch line below carries, written where a later process can read them.
    # A preflight or a consultation started by the app is not a child of this tmux session.
    run_env_save "$IDIR"
    EFFORT_FLAG="$(claude_effort_launch_flag)"
    MODEL_FLAG=""; [ -n "${SUPERVISOR_CLAUDE_MODEL:-}" ] && MODEL_FLAG="--model $(shq "$SUPERVISOR_CLAUDE_MODEL") "
    SETTINGS_FLAG=""; WORKER_SETTINGS="$SUP_STATE/worker-settings.json"; [ -f "$WORKER_SETTINGS" ] && SETTINGS_FLAG="--settings $(shq "$WORKER_SETTINGS") "
    EXTRA_ADD_FLAGS="$(extra_add_dir_flags)"
    RAW_LAUNCH="claude --resume $(shq "$RESUME_SID") ${EFFORT_FLAG}${MODEL_FLAG}${SETTINGS_FLAG}--permission-mode $(shq "${SUPERVISOR_PERMISSION_MODE:-auto}") --add-dir $(shq "$IDIR") ${EXTRA_ADD_FLAGS}--append-system-prompt-file $(shq "$IDIR/standards.md"); $(shq "$BIN_DIR/night-shift.sh") stop $(shq "$PROJECT_DIR")"
    LAUNCH="$(subscription_env_prefix) ORCHESTRATOR_RUN_ID=$(shq "$RUN_ID") $(run_env_stamp) $RAW_LAUNCH"
    tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR" "$LAUNCH"
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "❌ resume: tmux-сесію не створено" >&2; rm -rf "$IDIR"; exit 1
    fi

    WD_CMD="${SUPERVISOR_WATCHDOG_CMD:-$BIN_DIR/watchdog.sh}"
    nohup "$WD_CMD" "$SLUG" >/dev/null 2>&1 &
    echo $! > "$IDIR/watchdog.pid"
    sleep 1
    if ! kill -0 "$(cat "$IDIR/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
      echo "❌ resume: watchdog не піднявся" >&2; tmux kill-session -t "$SESSION" 2>/dev/null; rm -rf "$IDIR"; exit 1
    fi

    if ! await_handshake "$IDIR" "$SLUG"; then
      tmux kill-session -t "$SESSION" 2>/dev/null
      rm -rf "$IDIR"
      exit 1
    fi

    touch "$SUP_STATE/night-mode"
    echo "🌙 Відновлено: $PROJECT_DIR"
    echo "   Сесія:  $SESSION (resume $RESUME_SID)"
    [ -n "$CUR_BRANCH" ] && echo "   Гілка:  $CUR_BRANCH"
    if [ "$NO_ATTACH" = 0 ] && [ -t 0 ] && [ -t 1 ]; then
      exec tmux attach -t "$SESSION"
    fi
    ;;

  stop)
    if [ "${1:-}" = "--all" ]; then
      if [ -d "$SUP_INSTANCES" ]; then for dd in "$SUP_INSTANCES"/*/; do [ -d "$dd" ] && stop_instance "$(basename "$dd")"; done; fi
      _legacy_present && stop_legacy
      cleanup_global_marker
      echo "☀️ Усі нічні зміни зупинено."
      exit 0
    fi
    ADIR="$(canon_path "${1:-$PWD}")"
    SLUG="$(slug_for "$ADIR")"
    if [ -d "$(instance_dir "$SLUG")" ]; then
      stop_instance "$SLUG"
    elif _legacy_present && ! _any_instance; then
      stop_legacy
    else
      echo "Немає активної нічної зміни для: $ADIR"
      echo "(подивись усі: night-shift status)"
    fi
    cleanup_global_marker
    ;;

  status)
    found=0
    if [ -d "$SUP_INSTANCES" ]; then
      for dd in "$SUP_INSTANCES"/*/; do
        [ -f "$dd/project" ] || continue
        found=1
        sl="$(basename "$dd")"; sess="$(cat "$dd/session" 2>/dev/null)"
        proj="$(cat "$dd/project" 2>/dev/null)"; br="$(cat "$dd/branch" 2>/dev/null || echo '-')"
        wok="dead"; [ -f "$dd/watchdog.pid" ] && kill -0 "$(cat "$dd/watchdog.pid" 2>/dev/null)" 2>/dev/null && wok="alive"
        tok="no"; tmux has-session -t "$sess" 2>/dev/null && tok="yes"
        echo "🌙 $proj"
        echo "    сесія=$sess (tmux:$tok)  watchdog=$wok  гілка=$br"
        { [ "$wok" = dead ] || [ "$tok" = no ]; } && echo "    ⚠️ нездоровий стан — полагодь: night-shift stop \"$proj\""
      done
    fi
    if _legacy_present && ! _any_instance; then
      found=1; echo "🌙 (легасі single-session режим; tmux 'night': $(tmux has-session -t night 2>/dev/null && echo yes || echo no))"
      echo "    мігрувати: night-shift stop --all  →  tmux kill-session -t night  →  night-shift start у кожному проєкті"
    fi
    [ "$found" = 0 ] && echo "Нічних змін не запущено."
    if [ -f "$SUP_STATE/usage.json" ]; then
      jq -r '"ліміти: Claude 5h " + ((.five_hour.used_percentage // 0)|floor|tostring) + "% (reset " + ((.five_hour.resets_at // 0)|strflocaltime("%H:%M")) + ")"' "$SUP_STATE/usage.json" 2>/dev/null || true
    fi
    ;;

  attach)
    ADIR="$(canon_path "${1:-$PWD}")"
    SLUG="$(slug_for "$ADIR")"; SESSION="$(session_name "$SLUG")"
    if tmux has-session -t "$SESSION" 2>/dev/null; then exec tmux attach -t "$SESSION"
    elif tmux has-session -t night 2>/dev/null && ! _any_instance; then exec tmux attach -t night
    else echo "Немає сесії для $ADIR (дивись night-shift status)"; exit 1; fi
    ;;

  list)
    if [ -d "$SUP_INSTANCES" ]; then
      for dd in "$SUP_INSTANCES"/*/; do [ -f "$dd/project" ] && echo "$(cat "$dd/session" 2>/dev/null)  ←  $(cat "$dd/project")"; done
    fi
    ;;

  uninstall)
    # Everything install.sh did to this machine, undone — and nothing else.
    #
    # Publishing a tool that edits Claude Code's global settings without a documented way back is
    # a trust problem, not a convenience one: the first question anybody sensible asks about a
    # `curl | bash` is how they get rid of it. So this removes the commands, takes the statusline
    # and the worker settings back out, and STOPS — it does not touch the queue, the run state or
    # anybody's own hooks, because those are not ours to delete.
    force=0
    for a in "$@"; do case "$a" in --force|-f) force=1 ;; esac; done

    if _any_instance && [ "$force" = 0 ]; then
      echo "Зараз іде робота. Спини її (night-shift stop --all) або передай --force." >&2
      exit 1
    fi

    echo "прибираю команди з ~/.local/bin"
    for c in night-shift deep-audit night-queue report-finding report-outcome night-trace night-artifact; do
      link="$HOME/.local/bin/$c"
      # Only our own symlinks. Somebody else's `night-trace` is somebody else's.
      if [ -L "$link" ] && case "$(readlink "$link")" in "$ROOT"/*) true ;; *) false ;; esac; then
        rm -f "$link"
      fi
    done

    echo "прибираю слеш-команди Claude Code"
    for c in deep-audit night queue; do
      dst="$HOME/.claude/commands/$c.md"
      [ -f "$dst" ] && cmp -s "$ROOT/claude-commands/$c.md" "$dst" && rm -f "$dst"
    done

    echo "повертаю ~/.claude/settings.json"
    ROOT="$ROOT" python3 - <<'PYEOF'
import json, os, pathlib
root = os.environ["ROOT"]
p = pathlib.Path.home() / ".claude" / "settings.json"
try:
    s = json.loads(p.read_text())
    if not isinstance(s, dict):
        raise ValueError
except Exception:
    print("  (немає що повертати)")
    raise SystemExit(0)

# Only the statusline WE set. Somebody who pointed it elsewhere keeps theirs.
line = s.get("statusLine")
if isinstance(line, dict) and root in (line.get("command") or ""):
    del s["statusLine"]

hooks = s.get("hooks", {})
for key in list(hooks):
    hooks[key] = [e for e in hooks[key] if root not in json.dumps(e)]
    if not hooks[key]:
        del hooks[key]
if "hooks" in s and not s["hooks"]:
    del s["hooks"]

p.write_text(json.dumps(s, indent=2, ensure_ascii=False) + "\n")
print("  прибрано все, що вказувало на движок; решта налаштувань на місці")
PYEOF
    rm -f "$HOME/.claude/supervisor/worker-settings.json"

    echo ""
    echo "Готово. Перезапусти Claude Code."
    echo "Лишилось недоторканим (це твоє, не наше):"
    echo "  ~/.claude/supervisor  — черга, стан прогонів, звіти"
    echo "  $ROOT  — сам движок; видали теку, якщо він більше не потрібен"
    ;;

  version)
    echo "night-shift $(cat "$ROOT/VERSION" 2>/dev/null || echo "від $(date -r "$ROOT/install.sh" '+%Y-%m-%d' 2>/dev/null || echo "?")")"
    echo "  движок: $ROOT"
    echo "  стан:   $SUP_STATE"
    ;;

  *)
    echo "usage: night-shift start [dir] | resume <dir> <session-id> [branch] | stop [dir|--all]"
    echo "       night-shift status | attach [dir] | list | version | uninstall [--force]"
    exit 1
    ;;
esac
