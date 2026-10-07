#!/bin/bash
# pipeline-share.sh — bringing a pipeline in from GitHub, and putting one out there.
#
#   pipeline-share.sh fetch <source> [--path SUB] [--ref REF]   → JSON: what it is, what the audit said
#   pipeline-share.sh install <quarantine> <id>                 → added to the library, switched off
#   pipeline-share.sh discard <quarantine>
#   pipeline-share.sh publish <package-dir> <repo> [--private]  → a GitHub repository (gh)
#
# A download never runs anything: the clone has hooks and fsmonitor off, its .git is deleted, and
# only the description, the layout, the prompts and a readme leave the quarantine. Every prompt is
# read by the static audit the skills go through and, when Codex is here, by Codex too. What is
# added arrives switched off, pinned to the commit it came from, until he has read it.
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; ROOT="$(cd "$BIN_DIR/.." && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
strip_paid_api_env "$SUP_STATE/supervisor.log" >/dev/null 2>&1 || true
TOOL="$BIN_DIR/pipeline-tool.py"
AUDIT="$BIN_DIR/skill-audit.sh"
QROOT="$SUP_STATE/pipelines-quarantine"

die() {  # $1=message $2=exit code
  jq -nc --arg e "$1" '{ok:false, error:$e}'
  echo "$1" >&2
  exit "${2:-1}"
}

# owner/repo, https://github.com/owner/repo[.git][/tree/<ref>/<path>], git@github.com:owner/repo.git
parse_source() {  # sets URL REPO REF_FROM_URL PATH_FROM_URL LOCAL
  local s="$1"
  URL=""; REPO=""; REF_FROM_URL=""; PATH_FROM_URL=""; LOCAL=""
  if [ -d "$s" ]; then LOCAL="$s"; return 0; fi
  case "$s" in
    https://github.com/*|http://github.com/*)
      local rest="${s#*github.com/}"; rest="${rest%/}"
      REPO="$(printf '%s' "$rest" | cut -d/ -f1-2)"; REPO="${REPO%.git}"
      case "$rest" in
        */tree/*|*/blob/*)
          local tail="${rest#*/tree/}"; [ "$tail" = "$rest" ] && tail="${rest#*/blob/}"
          REF_FROM_URL="${tail%%/*}"
          [ "$tail" != "$REF_FROM_URL" ] && PATH_FROM_URL="${tail#*/}"
          PATH_FROM_URL="${PATH_FROM_URL%/pipeline.json}"
          ;;
      esac ;;
    git@github.com:*) REPO="${s#git@github.com:}"; REPO="${REPO%.git}" ;;
    */*) case "$s" in *://*|*' '*) return 1 ;; esac; REPO="${s%.git}" ;;
    *) return 1 ;;
  esac
  printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || return 1
  URL="https://github.com/$REPO.git"
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  fetch)
    SRC="${1:-}"; shift 2>/dev/null || true
    SUB=""; REF=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --path) SUB="${2:-}"; shift 2 ;;
        --ref) REF="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$SRC" ] || die "Вкажи адресу репозиторію." 2
    parse_source "$SRC" || die "Не розумію цю адресу. Підійде owner/repo або посилання на github.com." 2
    [ -n "$SUB" ] || SUB="$PATH_FROM_URL"
    [ -n "$REF" ] || REF="$REF_FROM_URL"
    case "$SUB" in /*|*..*) die "Небезпечний шлях у джерелі: $SUB" 2 ;; esac
    case "$REF" in *..*|-*|*' '*) die "Дивна гілка або тег: $REF" 2 ;; esac
    mkdir -p "$QROOT"
    Q="$(mktemp -d "$QROOT/import-XXXXXX")" || die "Не можу створити карантин." 1
    SHA=""
    if [ -n "$LOCAL" ]; then
      cp -R "$LOCAL" "$Q/source" 2>/dev/null || { rm -rf "$Q"; die "Не можу скопіювати $LOCAL" 1; }
      SHA="$(git -C "$LOCAL" rev-parse HEAD 2>/dev/null || true)"
    else
      branch=(); [ -n "$REF" ] && branch=(--branch "$REF")
      if ! GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 perl -e 'alarm shift; exec @ARGV' 120 \
           git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.file.allow=never \
           clone --quiet --depth 1 --no-recurse-submodules "${branch[@]}" "$URL" "$Q/source" >/dev/null 2>&1; then
        rm -rf "$Q"; die "Не вдалося завантажити $REPO${REF:+ ($REF)}. Перевір адресу і чи репозиторій публічний." 1
      fi
      SHA="$(git -C "$Q/source" rev-parse HEAD 2>/dev/null || true)"
    fi
    rm -rf "$Q/source/.git"
    ins="$(python3 "$TOOL" inspect "$Q/source" ${SUB:+--path "$SUB"} 2>/dev/null)"; ins_rc=$?
    if [ "$ins_rc" = 9 ]; then
      cands="$(printf '%s' "$ins" | jq -c '.candidates // []')"
      rm -rf "$Q"
      jq -nc --argjson c "$cands" '{ok:false, error:"У репозиторії кілька пайплайнів — обери один.", candidates:$c}'
      exit 9
    fi
    [ "$ins_rc" = 0 ] || { rm -rf "$Q"; die "$(printf '%s' "$ins" | jq -r '.error // "Тут немає pipeline.json."' 2>/dev/null)" 3; }
    PKG_SRC="$(printf '%s' "$ins" | jq -r '.dir')"
    REL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$PKG_SRC" "$Q/source")"
    [ "$REL" = "." ] && REL=""
    # Only the files a pipeline is made of leave the download.
    mkdir -p "$Q/package/prompts"
    printf '%s' "$ins" | jq -r '.files[]' | while IFS= read -r f; do
      mkdir -p "$Q/package/$(dirname "$f")"; cp "$PKG_SRC/$f" "$Q/package/$f"
    done
    a_json="$("$AUDIT" "$Q/package" 2>/dev/null)"; a_rc=$?
    [ -n "$a_json" ] || a_json='{"verdict":"REJECT","findings":[{"category":"audit","severity":"HIGH","detail":"the audit did not answer"}]}'
    a_verdict="$(printf '%s' "$a_json" | jq -r '.verdict // "REJECT"')"
    b_verdict="SKIP"; b_notes=""
    if [ "$a_verdict" != REJECT ] && [ "${SUPERVISOR_SKILL_NO_CODEX:-0}" != 1 ] && command -v codex >/dev/null 2>&1; then
      prompt="$(cat "$ROOT/supervisor/PIPELINE-AUDIT-PROMPT.md")
<<UNTRUSTED_PIPELINE_DATA>>
$(find "$Q/package" -type f | LC_ALL=C sort | while read -r f; do echo "----- ${f#$Q/package/} -----"; clip_utf8 6000 < "$f"; echo; done)
<<END>>"
      b_out="$(perl -e 'alarm shift; exec @ARGV' "${SUPERVISOR_SKILL_AUDIT_TIMEOUT:-240}" codex exec $(codex_effort_flags) --sandbox read-only --skip-git-repo-check "$prompt" 2>>"${CODEX_LOG:-/dev/null}" </dev/null)"
      b_verdict="$(printf '%s' "$b_out" | grep -m1 -oiE 'VERDICT: *(PASS|PROPOSE|REJECT)' | grep -oiE 'PASS|PROPOSE|REJECT' | tr a-z A-Z)"
      [ -n "$b_verdict" ] || b_verdict="INCONCLUSIVE"
      b_notes="$(printf '%s' "$b_out" | grep -iA6 'VERDICT:' | tail -n +2 | head -6)"
    fi
    verdict="PASS"
    { [ "$a_verdict" = REJECT ] || [ "$b_verdict" = REJECT ]; } && verdict="REJECT"
    [ "$verdict" = PASS ] && [ "$a_verdict" = PROPOSE -o "$b_verdict" = PROPOSE -o "$b_verdict" = INCONCLUSIVE ] && verdict="PROPOSE"
    printf '%s\n' "$verdict" > "$Q/verdict"
    jq -nc --arg repo "$REPO" --arg path "${REL}" --arg ref "$REF" --arg sha "$SHA" --arg src "${LOCAL:-$URL}" \
      '{repo:(if $repo=="" then null else $repo end), path:$path, ref:(if $ref=="" then null else $ref end), sha:$sha, source:$src}' > "$Q/origin.json"
    ins_pkg="$(python3 "$TOOL" inspect "$Q/package" 2>/dev/null || echo '{}')"
    jq -nc --arg q "$Q" --arg v "$verdict" --arg bv "$b_verdict" --arg bn "$b_notes" \
      --argjson origin "$(cat "$Q/origin.json")" --argjson ins "$ins_pkg" --argjson audit "$a_json" \
      --argjson ignored "$(printf '%s' "$ins" | jq -c '.ignored // []')" \
      '{ok:true, quarantine:$q, verdict:$v, origin:$origin, pipeline:$ins.pipeline, validation:$ins.validation,
        skills:($ins.skills // []), files:($ins.files // []), ignored:$ignored, audit:$audit,
        review:{verdict:$bv, notes:$bn}}'
    ;;

  install)
    Q="${1:-}"; ID="${2:-}"
    case "$Q" in "$QROOT"/import-*) ;; *) die "Це не карантин імпорту." 2 ;; esac
    [ -d "$Q/package" ] || die "Карантин порожній — завантаж ще раз." 3
    [ "$(cat "$Q/verdict" 2>/dev/null)" = REJECT ] && die "Аудит відхилив цей пайплайн — його не можна додати." 8
    out="$(python3 "$TOOL" install "$Q/package" "$ID" --origin "$Q/origin.json")"; rc=$?
    printf '%s\n' "$out"
    [ "$rc" = 0 ] && rm -rf "$Q"
    exit "$rc"
    ;;

  discard)
    Q="${1:-}"
    case "$Q" in "$QROOT"/import-*) rm -rf "$Q" ;; esac
    jq -nc '{ok:true}'
    ;;

  publish)
    DIR="${1:-}"; NAME="${2:-}"; VIS="--public"
    [ "${3:-}" = "--private" ] && VIS="--private"
    [ -f "$DIR/pipeline.json" ] || die "У теці немає pipeline.json — спершу експортуй пайплайн." 2
    printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9_.-]+$' || die "Назва репозиторію: лише латиниця, цифри, крапка, дефіс." 2
    command -v gh >/dev/null 2>&1 || die "Немає GitHub CLI (gh). Встанови його або опублікуй теку вручну." 4
    gh auth status >/dev/null 2>&1 || die "GitHub CLI не ввійшов в акаунт." 4
    ( cd "$DIR" && { [ -d .git ] || git init -q -b main; } && git add -A && \
      git -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name || echo Bulava)}" \
          -c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email || echo bulava@localhost)}" \
          commit -q -m "Pipeline $(jq -r '.name // .id' pipeline.json)" ) >/dev/null 2>&1 || die "Не вдалося підготувати коміт." 1
    url="$(cd "$DIR" && gh repo create "$NAME" "$VIS" --source . --push 2>&1 | grep -Eo 'https://github.com/[^ ]+' | head -1)"
    [ -n "$url" ] || die "GitHub не створив репозиторій $NAME — можливо, така назва вже зайнята." 1
    jq -nc --arg u "$url" '{ok:true, url:$u}'
    ;;

  *) echo "usage: pipeline-share.sh fetch|install|discard|publish" >&2; exit 2 ;;
esac
