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
    # The verifier's build products stay behind. A run's evidence is its logs and its verdicts; the
    # app it built is gigabytes, and every one of those copies was one more app under his bundle id
    # for macOS to choose between — 24 of them were sitting in here, 19 GB in all.
    for a in reports evidence report scope-violation.json findings.jsonl; do
      [ -e "$idir/$a" ] || continue
      rsync -a --exclude 'DerivedData/' "$idir/$a" "$rdir/" 2>/dev/null \
        || cp -R "$idir/$a" "$rdir/" 2>/dev/null || true
    done
  fi
  # A chat that started on top of the director's uncommitted work keeps its base for a resume.
  save_run_base "$idir" "$slug"
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
    # The director's answer about uncommitted work already in the folder (see `ask_about_dirty_tree`
    # below). The app hands it over in the environment, a terminal as flags; the flags win.
    DIRTY_CHOICE="${SUPERVISOR_DIRTY:-}"
    DIRTY_SEEN="${SUPERVISOR_DIRTY_DIGEST:-}"
    DIRTY_MESSAGE="${SUPERVISOR_COMMIT_MESSAGE:-}"
    # Read once and dropped. An answer belongs to the one start it was given for: left exported, it
    # would ride into the tmux server's environment and be there for whatever starts next.
    unset SUPERVISOR_DIRTY SUPERVISOR_DIRTY_DIGEST SUPERVISOR_COMMIT_MESSAGE
    for a in "$@"; do
      if [ "$_want_branch" = 1 ]; then SUPERVISOR_WORK_BRANCH="$a"; _want_branch=0; continue; fi
      case "$a" in
        --no-attach) NO_ATTACH=1 ;;
        --branch) _want_branch=1 ;;
        --branch=*) SUPERVISOR_WORK_BRANCH="${a#--branch=}" ;;
        --dirty=*) DIRTY_CHOICE="${a#--dirty=}" ;;
        --dirty-digest=*) DIRTY_SEEN="${a#--dirty-digest=}" ;;
        --message=*) DIRTY_MESSAGE="${a#--message=}" ;;
        *) [ -z "$DIRARG" ] && DIRARG="$a" ;;
      esac
    done
    case "$DIRTY_CHOICE" in
      ""|keep|commit) ;;
      *) echo "❌ --dirty: «${DIRTY_CHOICE}» — можна keep або commit" >&2; exit 2 ;;
    esac
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
    # Our own leftover first: a `.git` the director let us make, with not a single file in it, is
    # what an interrupted removal leaves — nothing to repair, and not a reason to refuse forever.
    if git_consent_given "$PROJECT_DIR" && git_skeleton_only "$PROJECT_DIR"; then
      remove_created_git "$PROJECT_DIR" || true
    fi
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

    # The project brings MCP servers Claude has not been told about. It would stop to ask about them
    # before the session starts, where nobody can answer — so the question is asked here instead,
    # before anything is launched or changed. 78 is the question; see `project_mcp_servers`.
    _mcp_pending="$(project_mcp_pending "$PROJECT_DIR")"
    if [ -n "$_mcp_pending" ]; then
      _mcp_reader="$(question_reader mcp)"
      if [ "$_mcp_reader" = old-app ]; then
        _mcp_how="$(old_app_says)"
      elif [ "$_mcp_reader" = button ]; then
        _mcp_how="MCP-сервер може запускати код, тож вирішуєш ти. $(app_will_ask_says)"
      else
        _mcp_how="MCP-сервер може запускати код, тож вирішуєш ти — Bulava спитає кнопкою, або тут:
      night-shift mcp-decide \"$PROJECT_DIR\" enable   — увімкнути їх для роботи в цій теці
      night-shift mcp-decide \"$PROJECT_DIR\" skip     — працювати без них"
      fi
      refuse_start "$PROJECT_DIR" "Цей проєкт приносить свої MCP-сервери (.mcp.json), і про них Claude ще не питали: $(printf '%s' "$_mcp_pending" | tr '\n' ',' | sed 's/,$//; s/,/, /g').
Claude питає, чи їх вмикати, ще до початку роботи, а у фоні відповісти нікому. $_mcp_how"
      rm -f "$STD_TMP"; exit 78
    fi

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
          if [ "$(question_reader git)" = button ]; then
            _git_how="Створити тут git? Bulava спитає кнопкою під повідомленням."
          else
            _git_how="Створити тут git? Bulava запитає це кнопкою — або дозволь вручну:
      night-shift allow-git \"$PROJECT_DIR\""
          fi
          refuse_start "$PROJECT_DIR" "У цій теці немає git, а без нього нічній зміні нема куди відкочуватись і нема що показати на перевірці.
$_git_how
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
        local paths ex; paths="$(sed -n "s/^error: '\(.*\)' does not have a commit checked out$/\1/p")"
        [ -n "$paths" ] || return 1
        # The file git reads (`git_exclude_file`), which in a linked worktree is not under `.git`.
        ex="$(git_exclude_file .)" || return 1
        printf '%s\n' "$paths" | sed 's#/*$#/#' >> "$ex"
        echo "⚠️ git: у теці є вкладені репозиторії без комітів — не беру їх у checkpoint: $(printf '%s' "$paths" | tr '\n' ' ')" >&2
        return 0
      }
      do_checkpoint() {   # 0 committed · 1 failed · 2 nothing to commit · 3 too big to checkpoint
        harness_exclude_in .
        # Measured BEFORE `git add`, because `git add` is where the cost is paid: once it has
        # written half a gigabyte of objects the damage is done, and the app that was waiting for
        # this start has already given up.
        local over; over="$(checkpoint_overrun .)"
        if [ -n "$over" ]; then
          # Handed back rather than printed: the caller decides whether this is a list of files to
          # leave out (a question) or a folder that is simply too big (a refusal).
          if [ -n "${CHECKPOINT_OVER_NOTE:-}" ]; then printf '%s\n' "$over" > "$CHECKPOINT_OVER_NOTE"
          else printf '%s\n' "$over" >&2; fi
          return 3
        fi

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
          local ex; ex="$(git_exclude_file .)" \
            && tr "\0" "\n" < "$secrets" | grep -v '^$' >> "$ex" 2>/dev/null
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
          if remove_created_git "$PROJECT_DIR"; then
            msg="$msg Прибрав .git, який щойно створив — тека лишилась такою, якою була."
          else
            msg="$msg Не зміг до кінця прибрати .git, який щойно створив: $PROJECT_DIR/.git — його можна просто видалити."
          fi
        else
          msg="$msg Перевір репо вручну."
        fi
        refuse_start "$PROJECT_DIR" "$msg"
        rm -f "$STD_TMP"; exit 1
      }
      # The folder already holds uncommitted work, and nobody has said what to do with it: stop and
      # ask. Nothing is committed, staged or moved on the way out.
      #
      # This used to be a checkpoint: `git add -A` and a commit as `night-shift`, silently, into the
      # director's own branch. See `worktree_dirty` in supervisor-lib.sh for the evening that ended
      # it. 77 is the question, as 76 is the question about git itself — Bulava answers it with
      # buttons under the message, a terminal with the same three answers as flags.
      ask_about_dirty_tree() {   # $1 = an optional first line
        local n list more
        n="$(dirty_entries "$PROJECT_DIR" | grep -c .)"
        list="$(dirty_entries "$PROJECT_DIR" | head -12 | sed 's/^/      /')"
        more=""; [ "$n" -gt 12 ] && more="      … і ще $((n - 12))"
        local how reader
        reader="$(question_reader dirty)"
        if [ "$reader" = old-app ]; then
          how="$(old_app_says)"
        elif [ "$reader" = button ]; then
          how="$(app_will_ask_says)"
        else
          how="Скажи, що з ними робити, і запусти знову:
      night-shift start \"$PROJECT_DIR\" --dirty=keep     — почати, не чіпаючи змін (збережу знімок, з якого їх можна відновити)
      night-shift start \"$PROJECT_DIR\" --dirty=commit [--message=\"…\"]   — закомітити все від твого імені й почати
Або закоміть, сховай чи відкинь їх сам — і запусти ще раз."
        fi
        refuse_start "$PROJECT_DIR" "${1:+$1
}У теці є незакомічені зміни ($n) — без тебе я їх не комічу і не чіпаю:
$list${more:+
$more}
$how"
        rm -f "$STD_TMP"; exit 77
      }
      # A repository of the director's own that has no commit yet. There is nothing for a run to be
      # measured against, and the first commit in somebody's history is theirs to make — so the only
      # answers are «make it for me, as me» or «I will make it myself».
      ask_about_first_commit() {   # $1 = an optional first line
        local how reader
        reader="$(question_reader dirty)"
        if [ "$reader" = old-app ]; then
          how="$(old_app_says)"
        elif [ "$reader" = button ]; then
          how="$(app_will_ask_says)"
        else
          how="Перший коміт — твій:
      night-shift start \"$PROJECT_DIR\" --dirty=commit [--message=\"…\"]   — закомітити все, що є, від твого імені й почати
Або зроби перший коміт сам — і запусти ще раз."
        fi
        refuse_start "$PROJECT_DIR" "${1:+$1
}У цьому репозиторії ще немає жодного коміту, тож прогону нема від чого відраховувати свою роботу.
$how"
        rm -f "$STD_TMP"; exit 77
      }
      # Too big to checkpoint, and the weight is a handful of files the director can name: a screen
      # recording, a disk image, an export. 79 is the question — leave them out of checkpoints — and
      # the list is in `checkpoint-heavy/<slug>.json` (see `checkpoint_heavy_json`), which is what the
      # answer will be applied to. Asked only after `checkpoint_heavy_record` found files to name.
      #
      # A repository this start created a moment ago is taken away first, exactly as a failed first
      # checkpoint always took it: the answer lives in the engine's state and is written into the
      # next one (`seed_heavy_excludes`).
      ask_about_heavy_files() {   # $1 = what the checkpoint would have cost
        local rec list tracked how gone=""
        local mb='"      \(.path) — \(if .size >= 1073741824 then "\((.size * 10 / 1073741824 | floor) / 10) ГБ" else "\(.size / 1048576 | floor) МБ" end)"'
        rec="$(checkpoint_heavy_file "$PROJECT_DIR")"
        list="$(jq -r ".files[] | select(.tracked | not) | $mb" "$rec" 2>/dev/null | head -8)"
        tracked="$(jq -r ".files[] | select(.tracked) | $mb" "$rec" 2>/dev/null | head -8)"
        if [ "${GIT_CREATED:-0}" = 1 ] && [ -d "$PROJECT_DIR/.git" ] \
           && ! ( cd "$PROJECT_DIR" && git rev-parse HEAD >/dev/null 2>&1 ); then
          if remove_created_git "$PROJECT_DIR"; then
            gone="Прибрав .git, який щойно створив, — тека така, як була."
          else
            gone="Не зміг до кінця прибрати .git, який щойно створив: $PROJECT_DIR/.git. Історії в ньому немає — його можна просто видалити."
          fi
        fi
        if [ "$(question_reader heavy)" = button ]; then
          how="Bulava запропонує не брати їх у чекпоінт. Самі файли нікуди не дінуться."
        else
          how="Щоб не брати їх у чекпоінт, додай їх у .gitignore або винеси з теки — і запусти ще раз."
        fi
        refuse_start "$PROJECT_DIR" "${1:+$1
}${list:+Найбільше важать:
$list
}${tracked:+Ці git уже відстежує — правило ignore їх не прибере, їх треба закомітити самому або винести з теки:
$tracked
}$how${gone:+
$gone}"
        rm -f "$STD_TMP"; exit 79
      }
      # What the director saw is what gets committed. If the folder changed between the list on the
      # screen and the button, the answer was given about something else — ask again, with the list
      # as it is now.
      seen_is_current() {
        [ -z "$DIRTY_SEEN" ] || [ "$DIRTY_SEEN" = "$(dirty_digest "$PROJECT_DIR")" ]
      }
      # «Commit as me»: the director's own commit, made because they asked for it just now.
      #
      # Their identity from their own config — no `-c user.*` anywhere — and their own hooks run, as
      # for any commit they make. Everything on the list goes in: that is what the button says.
      #
      # Staged in a copy of their index, never in the index itself, and committed from that copy.
      # The list is checked again AFTER staging, so a file that appears in the moment between the
      # check and `git add` cannot ride along; and a commit that is refused — a hook, a secret — ends
      # with the copy thrown away and their index, the staged split included, never having moved.
      # Only a commit that went through replaces it.
      director_commit() {   # $1=message → 0 committed · 1 refused · 2 the folder changed · 3 too big, files listed (reasons on stderr)
        local msg="$1" ident gitdir idx err rc secrets over msgfile subject nested allow_empty=""
        local -a keep_out=()
        ident="$(director_identity .)"
        if [ -z "$ident" ]; then
          echo "У git не вказано, від чийого імені комітити (user.name і user.email). Налаштуй їх — або почни, не чіпаючи змін." >&2
          return 1
        fi
        over="$(checkpoint_overrun .)"
        if [ -n "$over" ]; then
          printf '%s\n' "$over" >&2
          checkpoint_heavy_record "$PROJECT_DIR" && return 3
          echo "Такий коміт краще зробити самому — або почни, не чіпаючи змін." >&2
          return 1
        fi
        gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
        # Beside the real one, so the swap at the end is a rename on the same filesystem.
        idx="$gitdir/night-shift-commit-index.$$"
        if [ -f "$gitdir/index" ]; then
          cp "$gitdir/index" "$idx" || { rm -f "$idx"; echo "Не зміг скопіювати індекс — комітити наосліп не буду." >&2; return 1; }
        fi
        drop_copy() { rm -f "$idx" "$idx.lock" 2>/dev/null; }

        # Nested repositories stay out: their files are their own history's, and a gitlink in the
        # director's commit is something they never asked for. Left out by pathspec, so nothing is
        # written into `.git/info/exclude` for a commit that may yet be refused.
        while IFS= read -r nested; do
          [ -n "$nested" ] && keep_out[${#keep_out[@]}]=":(exclude,literal)${nested%/}"
        done < <(nested_repo_entries .)
        err="$(GIT_INDEX_FILE="$idx" git add -A -- . ${keep_out[@]+"${keep_out[@]}"} 2>&1 >/dev/null)"; rc=$?
        if [ "$rc" != 0 ] || printf '%s' "$err" | grep -q '^fatal:'; then
          drop_copy; printf '%s\n' "$err" >&2; return 1
        fi
        [ "${#keep_out[@]}" -gt 0 ] && echo "⚠️ Вкладені репозиторії в коміт не беру — у них своя історія: $(nested_repo_entries . | tr '\n' ' ')" >&2
        for _hf in AUDIT-*.md REVIEW-DEBT.md; do
          GIT_INDEX_FILE="$idx" git ls-files --error-unmatch "$_hf" >/dev/null 2>&1 \
            && GIT_INDEX_FILE="$idx" git rm --cached --quiet "$_hf" 2>/dev/null || true
        done
        if ! seen_is_current; then
          drop_copy; echo "Поки ти вирішував, зміни в теці стали іншими." >&2; return 2
        fi

        # A key in a commit is a key on the remote. Nothing is dropped quietly and nothing is
        # written into their project: the commit does not happen, and they are told which files.
        secrets="$(mktemp)" || { drop_copy; return 1; }
        if ! GIT_INDEX_FILE="$idx" staged_secret_paths_z > "$secrets"; then
          rm -f "$secrets"; drop_copy
          echo "Не зміг перевірити файли на секрети — комітити наосліп не буду." >&2
          return 1
        fi
        if [ -s "$secrets" ]; then
          echo "Схоже на секрети — такого я не комічу: $(tr '\0' ' ' < "$secrets")" >&2
          echo "Прибери їх або додай у .gitignore — або почни, не чіпаючи змін." >&2
          rm -f "$secrets"; drop_copy; return 1
        fi
        rm -f "$secrets"

        msgfile="$(mktemp)" || { drop_copy; return 1; }
        if [ -n "$msg" ]; then
          printf '%s\n' "$msg" > "$msgfile"
        else
          { echo "Work in progress"; echo
            GIT_INDEX_FILE="$idx" git -c core.quotePath=false diff --cached --name-only 2>/dev/null | head -50 | sed 's/^/- /'
          } > "$msgfile"
        fi
        # The first commit of a repository that holds nothing yet is still a commit: it is what every
        # later diff stands on.
        git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || allow_empty="--allow-empty"
        err="$(GIT_INDEX_FILE="$idx" git commit -q $allow_empty -F "$msgfile" 2>&1)"; rc=$?
        rm -f "$msgfile"
        if [ "$rc" != 0 ]; then
          drop_copy
          echo "git commit не вдався — нічого не закомічено:" >&2
          printf '%s\n' "$err" | tail -15 >&2
          return 1
        fi
        # Committed. Their index becomes the one the commit was made from — it matches HEAD now.
        if ! mv -f "$idx" "$gitdir/index" 2>/dev/null; then
          drop_copy
          git read-tree --reset HEAD 2>/dev/null
        fi
        subject="$(git log -1 --format='%h %s' 2>/dev/null)"
        echo "🌿 Закомітив від імені $ident: $subject"
        return 0
      }

      harness_exclude_in "$PROJECT_DIR"
      DIRTY_MODE=""
      if ! ( cd "$PROJECT_DIR" && git rev-parse HEAD >/dev/null 2>&1 ) && [ "$GIT_CREATED" = 1 ]; then
        # A repository this start created a moment ago, with the director's consent: it has no
        # history of anybody's, and its first commit is the baseline the consent was for.
        _over_note="$(mktemp)"
        ( cd "$PROJECT_DIR" && CHECKPOINT_OVER_NOTE="$_over_note" do_checkpoint "Initial commit (before night shift)" ); rc=$?
        _over="$(cat "$_over_note" 2>/dev/null)"; rm -f "$_over_note"
        [ "$rc" = 1 ] && abort_checkpoint "initial"
        if [ "$rc" = 3 ]; then
          # Listed while the new `.git` is still here: counted the way the checkpoint counts, against
          # the same rules.
          checkpoint_heavy_record "$PROJECT_DIR" && ask_about_heavy_files "$_over"
          [ -n "$_over" ] && printf '%s\n' "$_over" >&2
          abort_checkpoint "initial — тека завелика"
        fi
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
      elif ! ( cd "$PROJECT_DIR" && git rev-parse HEAD >/dev/null 2>&1 ); then
        [ "$DIRTY_CHOICE" = commit ] || ask_about_first_commit
        seen_is_current || ask_about_first_commit "Поки ти вирішував, у теці щось змінилось — глянь ще раз."
        _why="$(cd "$PROJECT_DIR" && director_commit "$DIRTY_MESSAGE" 2>&1)"; _rc=$?
        [ "$_rc" = 2 ] && ask_about_first_commit "Поки ти вирішував, у теці щось змінилось — глянь ще раз."
        [ "$_rc" = 3 ] && ask_about_heavy_files "$(printf '%s\n' "$_why" | head -1)"
        [ "$_rc" = 0 ] || { refuse_start "$PROJECT_DIR" "$_why"; rm -f "$STD_TMP"; exit 1; }
        printf '%s\n' "$_why"
      elif ( cd "$PROJECT_DIR" && worktree_dirty . ); then
        case "$DIRTY_CHOICE" in
          commit)
            seen_is_current || ask_about_dirty_tree "Поки ти вирішував, зміни в теці стали іншими — ось вони зараз."
            _why="$(cd "$PROJECT_DIR" && director_commit "$DIRTY_MESSAGE" 2>&1)"; _rc=$?
            [ "$_rc" = 2 ] && ask_about_dirty_tree "Поки ти вирішував, зміни в теці стали іншими — ось вони зараз."
            [ "$_rc" = 3 ] && ask_about_heavy_files "$(printf '%s\n' "$_why" | head -1)"
            [ "$_rc" = 0 ] || { refuse_start "$PROJECT_DIR" "$_why"; rm -f "$STD_TMP"; exit 1; }
            printf '%s\n' "$_why"
            ;;
          keep)
            # Measured before anything is hashed, like the checkpoint was: the snapshot writes the
            # same objects `git add` would.
            _over="$(cd "$PROJECT_DIR" && checkpoint_overrun .)"
            if [ -n "$_over" ]; then
              checkpoint_heavy_record "$PROJECT_DIR" && ask_about_heavy_files "$_over"
              refuse_start "$PROJECT_DIR" "$_over
Такий обсяг незакомічених змін я не беру в знімок. Закоміть або сховай їх сам — і запусти ще раз."
              rm -f "$STD_TMP"; exit 1
            fi
            DIRTY_MODE=keep
            ;;
          *) ask_about_dirty_tree ;;
        esac
      fi
      # A commit the director asked for is theirs from here on. A start that fails later must not
      # take it back — CHECKPOINTED stays for the engine's own first commit only — and on a detached
      # HEAD the way back has to be the commit they just made, not the one before it.
      ORIG_REF="$(cd "$PROJECT_DIR" && git symbolic-ref --short HEAD 2>/dev/null || true)"
      [ -n "$ORIG_REF" ] || ORIG_REF="$(resolve_base_sha "$PROJECT_DIR")"
      [ "$CHECKPOINTED" = 1 ] || ORIG_HEAD="$(resolve_base_sha "$PROJECT_DIR")"
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
        # The director's work never left the folder, so a snapshot of a start that did not happen
        # is only clutter under a hidden ref.
        [ -n "${SNAPSHOT_REF:-}" ] && git -C "$PROJECT_DIR" update-ref -d "$SNAPSHOT_REF" 2>/dev/null
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
    SNAPSHOT_REF=""; SNAPSHOT=""
    if [ "${DIRTY_MODE:-}" = keep ]; then
      # «Start, leave my changes»: their work stays exactly where it is, and the run is measured
      # against a snapshot of it rather than against HEAD — so the review sees the worker's changes
      # and only those, and the scope gate cannot mistake a draft of theirs for a file the worker
      # made. Taken after the branch is chosen, so it stands on the commit the run starts from.
      SNAPSHOT_REF="refs/night-shift/$RUN_ID"
      if ! SNAPSHOT="$(snapshot_director_work "$PROJECT_DIR" "$SNAPSHOT_REF")" || [ -z "$SNAPSHOT" ]; then
        SNAPSHOT_REF=""
        refuse_start "$PROJECT_DIR" "Не вдалося зберегти знімок твоїх змін, а без нього поверх них я не починаю. У теці нічого не змінено."
        rollback_start; exit 1
      fi
      untracked_manifest "$PROJECT_DIR" > "$IDIR/base-untracked"
      : > "$IDIR/base-snapshot"
      printf '%s\n' "$SNAPSHOT_REF" > "$IDIR/snapshot-ref"
      prune_director_snapshots "$PROJECT_DIR"
      director_work_brief "$PROJECT_DIR" "$SNAPSHOT_REF" "$SNAPSHOT" >> "$IDIR/standards.md"
      echo "🧷 Твої незакомічені зміни лишились як були. Знімок для відновлення: $SNAPSHOT_REF"
      echo "   (повернути все, разом із застейдженим: git stash apply --index $SNAPSHOT_REF)"
      echo "$(date '+%F %T') [start] '$PROJECT_DIR' — the director's uncommitted work left in place, snapshot $SNAPSHOT_REF" >> "$SUP_STATE/supervisor.log"
    fi
    BASE_SHA="${SNAPSHOT:-$(resolve_base_sha "$PROJECT_DIR")}"
    [ -n "$BASE_SHA" ] && printf '%s\n' "$BASE_SHA" > "$IDIR/base-sha"
    # What git ignored at the start, so the scope gate never deletes it (see `ignored_manifest`).
    ignored_manifest "$PROJECT_DIR" > "$IDIR/base-ignored" 2>/dev/null || true
    # A fresh start measures itself; a base kept for an earlier session's resume no longer applies.
    forget_run_base "$SLUG"
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
    ln -sf "$BIN_DIR/worker-share.sh" "$IDIR/phone-link" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-share.sh" "$IDIR/phone-link" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-decide.sh" "$IDIR/decide" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-decide.sh" "$IDIR/decide" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-browser.sh" "$IDIR/browser" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-browser.sh" "$IDIR/browser" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-automation.sh" "$IDIR/automation" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-automation.sh" "$IDIR/automation" 2>/dev/null || true
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
    GEN="$(new_worker_generation "$IDIR")"
    LAUNCH_ENV="$(subscription_env_prefix) ORCHESTRATOR_RUN_ID=$(shq "$RUN_ID") $(run_env_stamp)"
    if [ -n "${SUPERVISOR_CLAUDE_CMD:-}" ]; then
      RAW_LAUNCH="$SUPERVISOR_CLAUDE_CMD"
    else
      EFFORT_FLAG="$(claude_effort_launch_flag)"
      MODEL_FLAG=""; [ -n "${SUPERVISOR_CLAUDE_MODEL:-}" ] && MODEL_FLAG="--model $(shq "$SUPERVISOR_CLAUDE_MODEL") "
      SETTINGS_FLAG=""; WORKER_SETTINGS="$(worker_settings_for "$IDIR" "$PROJECT_DIR")"; [ -n "$WORKER_SETTINGS" ] && [ -f "$WORKER_SETTINGS" ] && SETTINGS_FLAG="--settings $(shq "$WORKER_SETTINGS") "
      EXTRA_ADD_FLAGS="$(extra_add_dir_flags)$(browser_mcp_flags "$IDIR")"
      CLAUDE_FLAGS="${EFFORT_FLAG}${MODEL_FLAG}${SETTINGS_FLAG}--permission-mode $(shq "${SUPERVISOR_PERMISSION_MODE:-auto}") --add-dir $(shq "$IDIR") ${EXTRA_ADD_FLAGS}--append-system-prompt-file $(shq "$IDIR/standards.md")"
      STOP_TAIL="$(shq "$BIN_DIR/night-shift.sh") stop --generation"
      RAW_LAUNCH="claude ${CLAUDE_FLAGS}; ${STOP_TAIL} $(shq "$GEN") $(shq "$PROJECT_DIR")"
      save_relaunch_template "$IDIR" "$LAUNCH_ENV claude --resume @CLAUDE_SESSION@ ${CLAUDE_FLAGS}; ${STOP_TAIL} @GENERATION@ $(shq "$PROJECT_DIR")"
    fi
    LAUNCH="$LAUNCH_ENV $RAW_LAUNCH"
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

  dirty-state)
    # What a start would ask about, asked without starting: the folder's uncommitted work, as JSON.
    #
    # Bulava reads this to show the list under a message that stopped on exit 77, to watch the
    # folder while the director sorts it out in their own tool, and to hand back the digest the
    # answer will be checked against. Read-only — no index refresh, no lock.
    _d="$(canon_path "${1:-$PWD}")"
    [ -d "$_d" ] || { echo '{"error":"no-folder"}'; exit 1; }
    if [ "$(git -C "$_d" rev-parse --show-toplevel 2>/dev/null)" != "$_d" ]; then
      echo '{"error":"no-repo"}'; exit 0
    fi
    dirty_state_json "$_d" "${2:-300}"
    ;;

  commit-preview)
    # What «Commit as me» would commit, read without committing: staged into a throwaway copy of the
    # index exactly as `director_commit` stages it (nested repositories and the harness's own litter
    # left out), checked for secrets, and — only when nothing looks like one — the diff, so a model
    # can title the commit and point at anything that should not go in.
    #
    # The diff is never produced when the scan finds something or cannot run: a key must not reach
    # a model on its way to being refused. Each file is capped and so is the whole, because what a
    # title needs is the shape of the change, and a lockfile can be megabytes.
    _d="$(canon_path "${1:-$PWD}")"
    _cap="${2:-60000}"; case "$_cap" in ''|*[!0-9]*) _cap=60000 ;; esac
    [ -d "$_d" ] || { echo '{"error":"no-folder"}'; exit 1; }
    if [ "$(git -C "$_d" rev-parse --show-toplevel 2>/dev/null)" != "$_d" ]; then
      echo '{"error":"no-repo"}'; exit 0
    fi
    cd "$_d" || exit 1
    _gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 1
    _tmp="$(mktemp -d 2>/dev/null)" || exit 1
    trap 'rm -rf "$_tmp"' EXIT
    _idx="$_tmp/index"
    if [ -f "$_gitdir/index" ]; then cp "$_gitdir/index" "$_idx" || exit 1; fi
    _digest="$(dirty_digest "$_d")"
    _keep=()
    while IFS= read -r _n; do
      [ -n "$_n" ] && _keep[${#_keep[@]}]=":(exclude,literal)${_n%/}"
    done < <(nested_repo_entries .)
    GIT_INDEX_FILE="$_idx" git add -A -- . ${_keep[@]+"${_keep[@]}"} >/dev/null 2>&1 \
      || { echo '{"error":"stage-failed"}'; exit 0; }
    for _hf in AUDIT-*.md REVIEW-DEBT.md; do
      GIT_INDEX_FILE="$_idx" git ls-files --error-unmatch "$_hf" >/dev/null 2>&1 \
        && GIT_INDEX_FILE="$_idx" git rm --cached --quiet "$_hf" 2>/dev/null || true
    done
    _scan=ok
    GIT_INDEX_FILE="$_idx" staged_secret_paths_z > "$_tmp/secrets" || _scan=failed
    : > "$_tmp/diff"; _trunc=false
    if [ "$_scan" = ok ] && [ ! -s "$_tmp/secrets" ]; then
      GIT_INDEX_FILE="$_idx" git -c core.quotePath=false diff --cached --stat=120 2>/dev/null >> "$_tmp/diff"
      printf '\n' >> "$_tmp/diff"
      while IFS= read -r -d '' _f; do
        _size="$(wc -c < "$_tmp/diff" | tr -d ' ')"
        [ "$_size" -ge "$_cap" ] && { _trunc=true; break; }
        GIT_INDEX_FILE="$_idx" git -c core.quotePath=false diff --cached --no-ext-diff -- "$_f" 2>/dev/null \
          | head -c 4000 >> "$_tmp/diff"
        printf '\n' >> "$_tmp/diff"
      done < <(GIT_INDEX_FILE="$_idx" git diff --cached --name-only -z 2>/dev/null)
    fi
    _files="$(GIT_INDEX_FILE="$_idx" git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
    git log -20 --format='%s' 2>/dev/null > "$_tmp/recent" || : > "$_tmp/recent"
    tr '\0' '\n' < "$_tmp/secrets" | grep -v '^$' > "$_tmp/secret-lines" || :
    head -c "$_cap" "$_tmp/diff" | jq -R -s -c \
      --arg digest "$_digest" --arg scan "$_scan" --argjson files "${_files:-0}" \
      --argjson truncated "$_trunc" \
      --rawfile secrets "$_tmp/secret-lines" --rawfile recent "$_tmp/recent" '
      { digest: $digest, scan: $scan, files: $files, truncated: $truncated,
        secrets: ($secrets | split("\n") | map(select(length > 0))),
        recent: ($recent | split("\n") | map(select(length > 0))),
        diff: . }'
    ;;

  heavy-state)
    # The files the last start in this folder could not checkpoint, as JSON (`checkpoint_heavy_json`).
    #
    # Bulava reads this to put the list under a message that stopped on exit 79. It is what the start
    # saw — not counted again — so the answer goes to the files that were on the screen.
    _d="$(canon_path "${1:-$PWD}")"
    _rec="$(checkpoint_heavy_file "$_d")"
    [ -s "$_rec" ] || { echo '{"error":"none"}'; exit 1; }
    cat "$_rec"
    ;;

  heavy-exclude)
    # The director's answer to 79: leave the listed untracked files out of checkpoints in this folder —
    # `local` (the default) in the engine's record and `.git/info/exclude`, `gitignore` in the project's
    # own `.gitignore`. Tracked files are reported, never untracked or touched; no file is deleted.
    _d="$(canon_path "${1:-$PWD}")"
    [ -d "$_d" ] || { echo "❌ Теки не знайдено: ${1:-$PWD}" >&2; exit 1; }
    case "${2:-local}" in local|gitignore) ;; *) echo "❌ heavy-exclude: local або gitignore" >&2; exit 2 ;; esac
    if ! _sum="$(checkpoint_leave_out "$_d" "${2:-local}")"; then
      echo "❌ Не знайшов, які файли лишити поза чекпоінтом, або не зміг їх записати." >&2
      exit 1
    fi
    printf '%s\n' "$_sum"
    echo "$(date '+%F %T') [heavy-exclude] '$_d' (${2:-local}): $(printf '%s' "$_sum" | jq -r '.rules | length' 2>/dev/null) rule(s)" >> "$SUP_STATE/supervisor.log"
    ;;

  mcp-state)
    # The project's own MCP servers and which of them Claude has not been told about — for Bulava
    # to name when it asks.
    _d="$(canon_path "${1:-$PWD}")"
    [ -d "$_d" ] || { echo '{"error":"no-folder"}'; exit 1; }
    mcp_state_json "$_d"
    ;;

  mcp-decide)
    # The director's answer about a project's MCP servers: enable them, or work without them. Kept in
    # the engine's state and handed to each worker through its settings — nothing is written into
    # the project. With no names, it answers for every server still waiting.
    _d="$(canon_path "${1:-$PWD}")"; _how="${2:-}"
    [ -d "$_d" ] || { echo "❌ Теки не знайдено: ${1:-$PWD}" >&2; exit 1; }
    case "$_how" in enable|skip) ;; *) echo "usage: night-shift mcp-decide <dir> enable|skip [server…]" >&2; exit 2 ;; esac
    shift 2
    if [ $# -gt 0 ]; then _names="$(printf '%s\n' "$@")"; else _names="$(project_mcp_pending "$_d")"; fi
    if [ -z "$_names" ]; then echo "Тут немає MCP-серверів, про які треба вирішувати."; exit 0; fi
    # shellcheck disable=SC2086
    _old_ifs="$IFS"; IFS=$'\n'; set -- $_names; IFS="$_old_ifs"
    mcp_decision_record "$_d" "$_how" "$@" || { echo "❌ не зміг записати рішення" >&2; exit 1; }
    [ "$_how" = enable ] && echo "🔌 Увімкну для роботи в «${_d}»: $*" || echo "🔌 Працюватиму в «${_d}» без: $*"
    echo "$(date '+%F %T') [mcp-decide] $_how for '$_d': $*" >> "$SUP_STATE/supervisor.log"
    ;;

  mcp-carry)
    # The director's MCP answers for a folder, carried to a copy of it — a linked worktree Bulava
    # made to work in. The answers are kept per folder, so without this the copy starts with every
    # server «not asked about» and the start refuses with 78 in the middle of the night. Only what
    # was decided travels (`mcp_carry_decisions`); nothing decided, nothing written.
    if [ $# -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then echo "usage: night-shift mcp-carry <src> <dst>" >&2; exit 2; fi
    _src="$(canon_path "$1")"; _dst="$(canon_path "$2")"
    [ -d "$_src" ] || { echo "❌ Теки не знайдено: $1" >&2; exit 1; }
    [ -d "$_dst" ] || { echo "❌ Теки не знайдено: $2" >&2; exit 1; }
    _carried="$(mcp_carry_decisions "$_src" "$_dst")" || { echo "❌ не зміг записати рішення" >&2; exit 1; }
    if [ -z "$_carried" ]; then echo "Про MCP-сервери «${_src}» ще нічого не вирішено — переносити нічого."; exit 0; fi
    _on="$(printf '%s' "$_carried" | jq -r '.enabled | join(", ")' 2>/dev/null)"
    _off="$(printf '%s' "$_carried" | jq -r '.disabled | join(", ")' 2>/dev/null)"
    echo "🔌 Переніс рішення про MCP з «${_src}» у «${_dst}»:${_on:+ увімкнено $_on}${_on:+${_off:+;}}${_off:+ без $_off}"
    echo "$(date '+%F %T') [mcp-carry] '$_src' -> '$_dst': enable [${_on}] skip [${_off}]" >> "$SUP_STATE/supervisor.log"
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

  revive)
    # Brings a run whose session or watchdog died back IN PLACE (`instance_revive`): the same
    # directory, run id and Claude conversation. Unlike `resume` it deletes nothing — it is what a
    # run that still owes work gets. Exit: 0 whole again, 1 failed, 3 nothing to start it from,
    # 4 refused for good (stopped or replaced), 5 not now (its Claude is still running).
    PROJECT_DIR="$(canon_path "${1:-$PWD}")"
    command -v tmux >/dev/null 2>&1 || { echo "❌ tmux не встановлено" >&2; exit 1; }
    SLUG="$(slug_for "$PROJECT_DIR")"
    instance_revive "$SLUG"; rc=$?
    case "$rc" in
      0) echo "TIER=revived"; echo "🌙 Сесію піднято на місці: $PROJECT_DIR" ;;
      3) echo "нема з чого підняти сесію (нема інстанса, шаблону запуску чи session id)" >&2 ;;
      4) echo "підняття відхилено: сесію зупинено або замінено іншим прогоном" >&2 ;;
      5) echo "не зараз: Claude цієї розмови ще працює — другого не запускаю" >&2 ;;
      *) echo "❌ не вдалося підняти сесію — див. supervisor.log" >&2 ;;
    esac
    exit "$rc"
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
    # Before anything is touched: a conversation alive somewhere else is not started a second time.
    # Asked under the conversation's own lock, held until this resume is confirmed or rolled back —
    # two folders resuming one id at the same moment would otherwise each find nobody running it.
    if ! session_lock "$RESUME_SID" "$SLUG"; then
      echo "$(date '+%F %T') [resume] REFUSED '$PROJECT_DIR' — conversation $RESUME_SID is being started by $(session_lock_owner "$RESUME_SID") right now" >> "$SUP_STATE/supervisor.log"
      echo "❌ resume: цю розмову Claude саме зараз відновлюють в іншому місці — другу копію не запускаю." >&2
      exit 4
    fi
    trap 'session_unlock "$RESUME_SID"' EXIT
    if HOLDER="$(claude_session_holder "$RESUME_SID" "$SLUG")"; then
      echo "$(date '+%F %T') [resume] REFUSED '$PROJECT_DIR' — conversation $RESUME_SID is live in $HOLDER" >> "$SUP_STATE/supervisor.log"
      echo "❌ resume: ця розмова Claude вже працює в іншому місці ($HOLDER) — другу копію не запускаю." >&2
      exit 4
    fi
    # One bringing-back of a run at a time: a revival of the same run (the app's, the watchdog's)
    # holds the same lock, and two of them would each put the other's folder aside.
    if ! revive_lock "$SLUG"; then
      echo "❌ resume: цей прогін зараз піднімає інший процес — спробуй ще раз за хвилину." >&2
      exit 1
    fi
    trap 'revive_unlock "$SLUG"; session_unlock "$RESUME_SID"' EXIT
    # The run this replaces is put aside, not deleted, until the new one is confirmed: a resume that
    # does not come up must leave things as they were — the review, the receipts and the thread the
    # app reads with it. A failed one used to take all of that with it.
    ASIDE=""
    if [ -d "$IDIR" ]; then
      [ -f "$IDIR/watchdog.pid" ] && kill "$(cat "$IDIR/watchdog.pid")" 2>/dev/null
      ASIDE="$SUP_STATE/resume-aside/$SLUG.$$"
      mkdir -p "$SUP_STATE/resume-aside" 2>/dev/null
      if ! mv "$IDIR" "$ASIDE" 2>/dev/null; then
        echo "❌ resume: не вдалося відкласти попередній прогін ($IDIR) — нічого не змінено." >&2
        exit 1
      fi
    fi
    resume_rollback() {
      tmux kill-session -t "$SESSION" 2>/dev/null
      rm -rf "$IDIR"
      [ -n "$ASIDE" ] && [ -d "$ASIDE" ] || return 0
      # Never into a folder something made meanwhile: `mv` would nest the old run inside it.
      if [ ! -e "$IDIR" ] && mv "$ASIDE" "$IDIR" 2>/dev/null; then return 0; fi
      echo "$(date '+%F %T') [resume] could not put the previous run back in $IDIR — it is kept in $ASIDE" >> "$SUP_STATE/supervisor.log"
      return 0
    }

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
    [ -s "$STD_TMP" ] || { echo "❌ не вдалося згенерувати system prompt" >&2; rm -f "$STD_TMP"; resume_rollback; exit 1; }

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
    if restore_run_base "$IDIR" "$SLUG" "$PROJECT_DIR"; then
      # The session this resumes started on top of the director's uncommitted work: it is measured
      # against the base the review last accepted, not against HEAD, and the worker is reminded
      # which files are not its own.
      BASE_SHA="$(read_base_sha "$IDIR")"
      director_work_brief "$PROJECT_DIR" "$(cat "$IDIR/snapshot-ref" 2>/dev/null)" "$BASE_SHA" >> "$IDIR/standards.md"
      echo "$(date '+%F %T') [resume] '$PROJECT_DIR' — snapshot base $BASE_SHA restored" >> "$SUP_STATE/supervisor.log"
    else
      forget_run_base "$SLUG"
      ignored_manifest "$PROJECT_DIR" > "$IDIR/base-ignored" 2>/dev/null || true
    fi
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
    ln -sf "$BIN_DIR/worker-share.sh" "$IDIR/phone-link" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-share.sh" "$IDIR/phone-link" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-decide.sh" "$IDIR/decide" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-decide.sh" "$IDIR/decide" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-browser.sh" "$IDIR/browser" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-browser.sh" "$IDIR/browser" 2>/dev/null || true
    ln -sf "$BIN_DIR/worker-automation.sh" "$IDIR/automation" 2>/dev/null \
      || cp -f "$BIN_DIR/worker-automation.sh" "$IDIR/automation" 2>/dev/null || true
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
    SETTINGS_FLAG=""; WORKER_SETTINGS="$(worker_settings_for "$IDIR" "$PROJECT_DIR")"; [ -n "$WORKER_SETTINGS" ] && [ -f "$WORKER_SETTINGS" ] && SETTINGS_FLAG="--settings $(shq "$WORKER_SETTINGS") "
    EXTRA_ADD_FLAGS="$(extra_add_dir_flags)$(browser_mcp_flags "$IDIR")"
    GEN="$(new_worker_generation "$IDIR")"
    LAUNCH_ENV="$(subscription_env_prefix) ORCHESTRATOR_RUN_ID=$(shq "$RUN_ID") $(run_env_stamp)"
    CLAUDE_FLAGS="${EFFORT_FLAG}${MODEL_FLAG}${SETTINGS_FLAG}--permission-mode $(shq "${SUPERVISOR_PERMISSION_MODE:-auto}") --add-dir $(shq "$IDIR") ${EXTRA_ADD_FLAGS}--append-system-prompt-file $(shq "$IDIR/standards.md")"
    STOP_TAIL="$(shq "$BIN_DIR/night-shift.sh") stop --generation"
    if [ -n "${SUPERVISOR_CLAUDE_CMD:-}" ]; then
      RAW_LAUNCH="$SUPERVISOR_CLAUDE_CMD"
    else
      RAW_LAUNCH="claude --resume $(shq "$RESUME_SID") ${CLAUDE_FLAGS}; ${STOP_TAIL} $(shq "$GEN") $(shq "$PROJECT_DIR")"
      save_relaunch_template "$IDIR" "$LAUNCH_ENV claude --resume @CLAUDE_SESSION@ ${CLAUDE_FLAGS}; ${STOP_TAIL} @GENERATION@ $(shq "$PROJECT_DIR")"
    fi
    LAUNCH="$LAUNCH_ENV $RAW_LAUNCH"
    tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR" "$LAUNCH"
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "❌ resume: tmux-сесію не створено" >&2; resume_rollback; exit 1
    fi

    WD_CMD="${SUPERVISOR_WATCHDOG_CMD:-$BIN_DIR/watchdog.sh}"
    nohup "$WD_CMD" "$SLUG" >/dev/null 2>&1 &
    echo $! > "$IDIR/watchdog.pid"
    sleep 1
    if ! kill -0 "$(cat "$IDIR/watchdog.pid" 2>/dev/null)" 2>/dev/null; then
      echo "❌ resume: watchdog не піднявся" >&2; resume_rollback; exit 1
    fi

    if ! await_handshake "$IDIR" "$SLUG" "$(resume_handshake_wait)"; then
      # The new watchdog first: left running, it would watch the folder put back below.
      kill "$(cat "$IDIR/watchdog.pid" 2>/dev/null)" 2>/dev/null
      resume_rollback
      exit 1
    fi
    [ -n "$ASIDE" ] && rm -rf "$ASIDE"
    # Released here and not on exit: the attach below replaces this process, and no trap survives it.
    # From here the conversation's own instance answers for it (`claude_session_holder`).
    revive_unlock "$SLUG"; session_unlock "$RESUME_SID"; trap - EXIT

    touch "$SUP_STATE/night-mode"
    echo "🌙 Відновлено: $PROJECT_DIR"
    echo "   Сесія:  $SESSION (resume $RESUME_SID)"
    [ -n "$CUR_BRANCH" ] && echo "   Гілка:  $CUR_BRANCH"
    if [ "$NO_ATTACH" = 0 ] && [ -t 0 ] && [ -t 1 ]; then
      exec tmux attach -t "$SESSION"
    fi
    ;;

  stop)
    # A worker's own launch line ends in `stop --generation <g>`. When that worker has been
    # replaced in place (`worker_relaunch`), its tail still runs as it dies — and must not take
    # down the instance its successor is now working in.
    STOP_GEN=""
    if [ "${1:-}" = "--generation" ]; then STOP_GEN="${2:-}"; shift 2 || shift $#; fi
    if [ "${1:-}" != "--all" ]; then
      _sidir="$(instance_dir "$(slug_for "$(canon_path "${1:-$PWD}")")")"
      if worker_tail_is_stale "$_sidir" "$STOP_GEN"; then
        echo "$(date '+%F %T') [night-shift] a replaced worker exited — its stop is not its successor's ($(basename "$_sidir"))" >> "$SUP_STATE/supervisor.log"
        exit 0
      fi
    fi
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
    echo "usage: night-shift start [dir] [--dirty=keep|commit [--message=…]] | resume <dir> <session-id> [branch] | revive <dir> | stop [dir|--all]"
    echo "       night-shift status | attach [dir] | list | dirty-state [dir] | commit-preview [dir] | heavy-state [dir] | heavy-exclude <dir> [local|gitignore] | mcp-state [dir] | mcp-decide <dir> enable|skip | mcp-carry <src> <dst> | version | uninstall [--force]"
    exit 1
    ;;
esac
