#!/bin/bash
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"; ROOT="$(cd "$BIN_DIR/.." && pwd)"
. "$BIN_DIR/supervisor-lib.sh"
. "$BIN_DIR/skill-resolver-lib.sh"
strip_paid_api_env "$SUP_STATE/supervisor.log" >/dev/null 2>&1 || true
AUDIT="$BIN_DIR/skill-audit.sh"; SCHEMA_TO="${SUPERVISOR_SKILL_AUDIT_TIMEOUT}"
now_iso(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }

cmd="${1:-status}"; shift 2>/dev/null || true

fetch_quarantine() {  # $1=source(dir or git url) $2=name → echoes quarantine skill dir
  local src="$1" name="$2" q; q="$QUARANTINE/${name}-$$"
  rm -rf "$q"; mkdir -p "$q"
  case "$src" in
    *://*|git@*)  # remote: shallow clone with hooks/fsmonitor disabled; never runs repo code.
      GIT_CONFIG_NOSYSTEM=1 git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        clone --depth 1 "$src" "$q/source" >/dev/null 2>&1 || { rm -rf "$q"; return 1; } ;;
    *)            # local fixture dir (tests / already-downloaded): copy, drop any .git.
      [ -d "$src" ] || { rm -rf "$q"; return 1; }
      cp -R "$src" "$q/source" 2>/dev/null || { rm -rf "$q"; return 1; } ;;
  esac
  rm -rf "$q/source/.git"
  echo "$q"
}

case "$cmd" in
  audit)
    "$AUDIT" "${1:?usage: audit <skill-dir>}"; exit $? ;;

  install)
    PROJ="$(canon_path "${1:?usage: install <project-dir> <source> [name] [--path <subdir>]}")"; SRC="${2:?source required}"
    SUBPATH=""; POSNAME=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --path) SUBPATH="${2:-}"; shift 2 ;;
        *) [ -z "$POSNAME" ] && POSNAME="$1"; shift ;;
      esac
    done
    NAME="$(safe_skill_name "${POSNAME:-$(basename "${SRC%.git}")}")" \
      || { echo "❌ unsafe skill name (traversal/empty): ${POSNAME:-$(basename "${SRC%.git}")}" >&2; exit 1; }
    TIER="$(source_tier "$SRC")"   # honest trust tier; unknown sources → 3, never auto-trusted
    Q="$(fetch_quarantine "$SRC" "$NAME")" || { echo "❌ fetch failed: $SRC" >&2; exit 1; }
    SKILLDIR="$Q/source"
    if [ -n "$SUBPATH" ]; then
      case "$SUBPATH" in
        /*|*..*) echo "❌ небезпечний шлях у джерелі: $SUBPATH" >&2; rm -rf "$Q"; exit 1 ;;
      esac
      cand="$Q/source/${SUBPATH#./}"
      real="$(cd "$cand" 2>/dev/null && pwd -P)" || { echo "❌ немає такої теки в джерелі: $SUBPATH" >&2; rm -rf "$Q"; exit 1; }
      qroot="$(cd "$Q/source" && pwd -P)"
      case "$real/" in "$qroot"/*) : ;; *) echo "❌ шлях виходить за межі карантину: $SUBPATH" >&2; rm -rf "$Q"; exit 1 ;; esac
      [ -f "$real/SKILL.md" ] || { echo "❌ у $SUBPATH немає SKILL.md — це не скіл" >&2; rm -rf "$Q"; exit 1; }
      SKILLDIR="$real"
    fi
    a_json="$("$AUDIT" "$SKILLDIR")"; a_rc=$?
    a_verdict="$(printf '%s' "$a_json" | jq -r '.verdict')"; has_script="$(printf '%s' "$a_json" | jq -r '.has_script')"
    printf '%s\n' "$a_json" > "$Q/audit.json"
    echo "$(date '+%F %T') [skill-resolver] $NAME stageA=$a_verdict has_script=$has_script" >> "$SUP_STATE/supervisor.log"
    if [ "$a_verdict" = "REJECT" ]; then
      echo "🚫 $NAME REJECTED by static audit — kept in quarantine ($Q), NOT installed." >&2
      printf '%s\n' "$a_json" | jq -r '.findings[]? | "   - [\(.severity)] \(.category): \(.detail)"' >&2
      printf 'REJECT\n' > "$Q/verdict"; exit 1
    fi
    b_verdict="SKIP"
    if [ "${SUPERVISOR_SKILL_NO_CODEX:-0}" != 1 ] && command -v codex >/dev/null 2>&1; then
      prompt="$(sed "s#{{SKILL_DIR}}#$SKILLDIR#" "$ROOT/supervisor/SKILL-AUDIT-PROMPT.md" 2>/dev/null)
<<UNTRUSTED_SKILL_DATA>>
$(find "$SKILLDIR" -type f -not -path '*/.git/*' 2>/dev/null | while read -r f; do echo "----- $f -----"; clip_utf8 4000 < "$f"; echo; done)
<<END>>"
      b_out="$(perl -e 'alarm shift; exec @ARGV' "$SCHEMA_TO" codex exec $(codex_effort_flags) --sandbox read-only --skip-git-repo-check "$prompt" 2>>"$CODEX_LOG")"
      b_verdict="$(printf '%s' "$b_out" | grep -m1 -oiE 'VERDICT: *(PASS|PROPOSE|REJECT)' | grep -oiE 'PASS|PROPOSE|REJECT' | tr a-z A-Z || echo INCONCLUSIVE)"
    fi
    [ "$b_verdict" = "REJECT" ] && { echo "🚫 $NAME rejected by Codex agent review — quarantined." >&2; printf 'REJECT\n' > "$Q/verdict"; exit 1; }

    # Decide auto-install (Ivan's autonomy + TIERED trust):
    #  - Tier-1 inert markdown (Anthropic-reviewed source, no runnable code) → auto-install.
    #  - Inert markdown from an unknown source (Tier 2/3) → needs a Stage-B agent PASS.
    #  - Any script-bearing skill → needs a Stage-B agent PASS (regardless of tier).
    # So an arbitrary remote markdown skill is NEVER treated as trusted without a review.
    do_install=0
    if [ "$has_script" = "false" ] && [ "$a_verdict" = "PASS" ] && { [ "$TIER" = 1 ] || [ "$b_verdict" = "PASS" ]; }; then do_install=1
    elif [ "$has_script" = "true" ] && [ "$b_verdict" = "PASS" ]; then do_install=1; fi
    if [ "$do_install" = 0 ]; then
      echo "⏸ $NAME not auto-installed (tier=$TIER stageA=$a_verdict stageB=$b_verdict has_script=$has_script) — quarantined for review at $Q" >&2
      printf 'QUARANTINE\n' > "$Q/verdict"; exit 2
    fi

    # Autonomous PROJECT-LOCAL install (Ivan: project scope, not global).
    skills_root="$PROJ/.claude/skills"
    dest="$skills_root/$NAME"
    mkdir -p "$skills_root"
    # Defence in depth: NAME is already sanitized, but verify dest resolves strictly under the
    # skills root before any rm -rf. Refuse (never delete) if it escapes.
    case "$dest" in
      "$skills_root"/*) : ;;
      *) echo "❌ refusing install: dest escapes skills root ($dest)" >&2; exit 1 ;;
    esac
    rm -rf "$dest"; cp -R "$SKILLDIR" "$dest" 2>/dev/null; rm -rf "$dest/.git"
    NAME="$NAME" SOURCE_URL="$SRC" REPO="$SRC" COMMIT="$(git -C "$SKILLDIR" rev-parse HEAD 2>/dev/null || echo local)" \
      TREE_SHA="$(tree_sha256 "$dest")" TIER="$TIER" SCOPE=project STAGE_A="$a_verdict" STAGE_B="$b_verdict" INSTALLED_AT="$(now_iso)" lock_add
    printf 'INSTALLED\n' > "$Q/verdict"
    echo "✅ $NAME installed project-local: $dest (pinned in $SKILLS_LOCK). Used autonomously; promote to global later if it proves out."
    echo "$(date '+%F %T') [skill-resolver] $NAME INSTALLED project-local ($dest)" >> "$SUP_STATE/supervisor.log"
    ;;

  remove)
    # Delete an installed skill and forget it in the lock. The app asks for this; the ENGINE does
    # it, because skill state is the engine's and a UI reaching into `.claude/skills` with its own
    # `rm -rf` is how a name like `../../src` becomes a deleted source tree.
    PROJ="$(canon_path "${1:-$PWD}")"; RAW="${2:-}"; WANT="${3:-}"
    [ -n "$RAW" ] || { echo "usage: skill-resolver.sh remove <project> <name> <scope>" >&2; exit 1; }
    case "$WANT" in project|global|plugin|"") : ;;
      *) echo "❌ невідома область: $WANT" >&2; exit 1 ;; esac
    NAME="$(safe_skill_name "$RAW")" || { echo "❌ небезпечна назва: $RAW" >&2; exit 1; }
    # The scope is part of the identity. Without it, `design` global and `design` project-local are
    # the same request, and the one that got deleted was whichever the search reached first.
    loc="$(skill_location "$PROJ" "$NAME" "$WANT")" \
      || { echo "не знайдено: $NAME${WANT:+ (область: $WANT)}" >&2; exit 1; }
    scope="${loc%%$'\t'*}"; dir="${loc#*$'\t'}"
    # A plugin's skill belongs to the plugin, not to us — removing it would break the plugin and
    # come back on its next update. Refuse rather than half-delete someone else's package.
    [ "$scope" = "plugin" ] && { echo "❌ $NAME належить плагіну — вимикай сам плагін, не окремий скіл" >&2; exit 1; }
    # Defence in depth: the name is sanitized already, but never rm -rf a path that does not
    # resolve strictly under the root it is supposed to be in.
    # A project has two skill roots, and the deletion has to be inside whichever one the skill
    # was actually found in — never merely inside "a" root.
    ok_root=0
    case "$scope" in
      project) for root in "$PROJ/.claude/skills" "$PROJ/.agents/skills"; do
                 case "$dir" in "$root"/*) ok_root=1 ;; esac
               done ;;
      global)  case "$dir" in "$HOME/.claude/skills"/*) ok_root=1 ;; esac ;;
    esac
    [ "$ok_root" = 1 ] || { echo "❌ шлях виходить за корінь скілів ($dir)" >&2; exit 1; }
    rm -rf "$dir" || { echo "❌ не вдалося видалити $dir" >&2; exit 1; }
    lock_remove "$NAME" "$scope"
    echo "🗑 $NAME видалено ($scope: $dir)"
    echo "$(date '+%F %T') [skill-resolver] $NAME REMOVED ($scope: $dir)" >> "$SUP_STATE/supervisor.log"
    exit 0 ;;

  update)
    # Re-install a locked skill from the source it came from, through the SAME pipeline as a first
    # install: fetch → quarantine → static audit → agent review. An update is new code from the
    # internet, so it earns no shortcut for having been trusted once.
    PROJ="$(canon_path "${1:-$PWD}")"; RAW="${2:-}"; WANT="${3:-project}"
    [ -n "$RAW" ] || { echo "usage: skill-resolver.sh update <project> <name> <scope>" >&2; exit 1; }
    NAME="$(safe_skill_name "$RAW")" || { echo "❌ небезпечна назва: $RAW" >&2; exit 1; }
    # The resolver only ever installs project-local, so only a project-scoped row can be updated
    # by it. Updating a GLOBAL row through this path used to install a project-local copy that
    # shadowed the global one — a new skill wearing the updated one's name.
    if [ "$WANT" != "project" ]; then
      echo "❌ $NAME у області «${WANT}» — резолвер ставить лише проєктно, оновлення створило б проєктну копію-двійника" >&2
      exit 1
    fi
    src="$(jq -r --arg n "$NAME" '[.skills[]? | select(.name == $n and ((.scope // "project") == "project"))][0].source_url // ""' "$SKILLS_LOCK" 2>/dev/null)"
    if [ -z "$src" ] || [ "$src" = "null" ]; then
      # A skill installed by hand has no recorded source, and guessing one would be inventing a
      # provenance the director never approved.
      echo "❌ $NAME не має записаного джерела в $SKILLS_LOCK — оновити нема звідки" >&2; exit 1
    fi
    echo "оновлюю $NAME з $src (через той самий аудит)"
    exec "$0" install "$PROJ" "$src" "$NAME" ;;

  verify)
    # Recompute each project-scoped skill's tree hash and COMPARE to the lock (tamper detection).
    PROJ="$(canon_path "${1:-$PWD}")"; rc=0
    [ -f "$SKILLS_LOCK" ] || { echo "no skills.lock"; exit 0; }
    while IFS= read -r row; do
      name="$(printf '%s' "$row" | jq -r .name)"; scope="$(printf '%s' "$row" | jq -r .scope)"; want="$(printf '%s' "$row" | jq -r .tree_sha256)"
      [ "$scope" = "project" ] || { echo "  $name [scope=$scope] (skip: not project-local)"; continue; }
      d="$PROJ/.claude/skills/$name"
      if [ ! -d "$d" ]; then echo "  ❌ $name MISSING at $d"; rc=1; continue; fi
      got="$(tree_sha256 "$d")"
      if [ "$got" = "$want" ]; then echo "  ✅ $name OK ($got)"; else echo "  ❌ $name TAMPERED (lock $want ≠ actual $got)"; rc=1; fi
    done < <(jq -c '.skills[]?' "$SKILLS_LOCK" 2>/dev/null)
    exit $rc ;;

  needs)
    # Surface skill needs the worker recorded (auto-discovery need→source is v2; this lists them
    # so they aren't lost and can be resolved with `install <project> <source>`).
    echo "pending skill-needs ($SKILL_NEEDS):"; ls -1 "$SKILL_NEEDS" 2>/dev/null | sed 's/^/  /' || echo "  (none)" ;;

  index)
    # Refresh the catalogue cache. One file per allowed source, fetched only when the cache has
    # gone stale — `--refresh` forces it. Prints what it learned and nothing it did not.
    force=0; case " $* " in *" --refresh "*) force=1 ;; esac
    ttl="${SUPERVISOR_SKILL_INDEX_TTL:-86400}"
    if [ "$force" = 0 ] && [ -f "$SKILL_INDEX" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$SKILL_INDEX" 2>/dev/null || stat -c %Y "$SKILL_INDEX" 2>/dev/null || echo 0) ))
      if [ "$age" -lt "$ttl" ]; then
        echo "індекс свіжий ($((age / 60)) хв): $(jq -r '.skills | length' "$SKILL_INDEX" 2>/dev/null || echo 0) записів із $(jq -r '.sources | length' "$SKILL_INDEX" 2>/dev/null || echo 0) джерел"
        exit 0
      fi
    fi
    mkdir -p "$ORCH_HOME" 2>/dev/null || true
    rows="$(mktemp)"; srcs="$(mktemp)"; trap 'rm -f "$rows" "$srcs"' EXIT
    ok_sources=0
    while IFS=$'\t' read -r sname srepo smanifest; do
      [ -n "$smanifest" ] || continue
      body="$(skill_fetch_manifest "$smanifest")" || { echo "  ⚠️  $sname — недоступне"; continue; }
      [ -n "$body" ] || { echo "  ⚠️  $sname — порожня відповідь"; continue; }
      printf '%s' "$body" | jq -e . >/dev/null 2>&1 || { echo "  ⚠️  $sname — не JSON"; continue; }
      n_before=$(wc -l < "$rows" | tr -d ' ')
      printf '%s' "$body" | skill_index_rows "$sname" "$srepo" >> "$rows"
      n_after=$(wc -l < "$rows" | tr -d ' ')
      echo "  ✅ $sname — $((n_after - n_before))"
      jq -nc --arg n "$sname" --arg r "$srepo" --arg at "$(now_iso)" \
         '{name:$n, repo:$r, fetched_at:$at}' >> "$srcs"
      ok_sources=$((ok_sources + 1))
    done < <(skill_sources_file | jq -r '.sources[]? | [.name, .repo, .manifest] | @tsv')

    if [ "$ok_sources" = 0 ]; then
      # Never overwrite a good cache with an empty one: a night without internet would otherwise
      # leave the index empty until someone noticed.
      echo "жодне джерело не відповіло — кеш лишається як був" >&2
      exit 1
    fi
    jq -sc --slurpfile srcs <(cat "$srcs") --arg at "$(now_iso)" \
       '{updated_at:$at, sources:$srcs, skills:(. | unique_by(.name + "|" + .source))}' \
       < <(cat "$rows") > "$SKILL_INDEX.tmp" 2>/dev/null \
      && mv -f "$SKILL_INDEX.tmp" "$SKILL_INDEX"
    echo "індекс: $(jq -r '.skills | length' "$SKILL_INDEX" 2>/dev/null || echo 0) записів із $ok_sources джерел → $SKILL_INDEX"
    exit 0 ;;

  suggest)
    # WHAT THIS PROJECT IS MISSING — read off the project itself, not guessed by a model.
    #
    # The director's ask was that skills be chosen for him: «pick the skills». The half that can be
    # done deterministically is deciding WHAT is needed; deciding WHERE to get it is the part that
    # touches the network, and that stays behind the quarantine pipeline. So this prints needs, and
    # with --record files them in the same channel a worker uses, where the resolver picks them up.
    #
    # Nothing is fetched and nothing is installed here.
    PROJ="${1:-$PWD}"; shift 2>/dev/null || true
    [ -d "$PROJ" ] || { echo "не тека: $PROJ" >&2; exit 1; }
    PROJ="$(canon_path "$PROJ")"
    record=0; case " $* " in *" --record "*) record=1 ;; esac
    feats="$(detect_features "$PROJ")"
    if [ -z "$(printf '%s' "$feats" | tr -d ' ')" ]; then
      echo "$(basename "$PROJ"): жодного сигналу — нічого пропонувати."; exit 0
    fi
    echo "$(basename "$PROJ") → $feats"
    missing=0
    # `skill_installed` and the mapping both look at THIS project, not the shell's cwd.
    export SKILL_FEATURE_PROJECT="$PROJ"
    for f in $feats; do
      sk="$(skill_for_feature "$f")"
      if [ -z "$sk" ]; then
        # No obtainable skill answers this signal. Saying nothing is what made the whole feature
        # look broken — the signal was found and then vanished. Say what it is instead, and do NOT
        # file a need: a need for a name no catalogue has is a note nobody can act on.
        note="$(skill_note_for_feature "$f")"
        [ -n "$note" ] && echo "  ℹ️  $f → $note" || echo "  ℹ️  $f → скіла під це немає"
        continue
      fi
      if skill_installed "$PROJ" "$sk"; then
        echo "  ✅ $f → $sk (вже є)"
      else
        missing=$((missing + 1))
        # Where it could come from, IF the index happens to know — and only from a source the
        # allowlist already permits. A candidate is a suggestion to the resolver, never an
        # install: the quarantine and the audit sit between this line and any code running.
        cand=""; cand_repo=""; cand_path=""; cand_source=""
        if [ -f "$SKILL_INDEX" ]; then
          read -r cand_source cand_repo cand_path <<< "$(jq -r --arg n "$sk" '
            [.skills[]? | select((.name // "") == $n)]
            | if length == 0 then "- - -"
              else "\(.[0].source // "-") \(.[0].repo // "-") \(.[0].path // "-")" end' \
            "$SKILL_INDEX" 2>/dev/null)"
          [ "$cand_source" = "-" ] && cand_source=""
          [ "$cand_repo" = "-" ] && cand_repo=""
          [ "$cand_path" = "-" ] && cand_path=""
          [ -n "$cand_repo" ] && cand="${cand_source}: ${cand_repo}${cand_path:+/$cand_path}"
        fi
        if [ -n "$cand" ]; then echo "  ➕ $f → $sk (бракує; є в індексі — $cand)"
        else echo "  ➕ $f → $sk (бракує; в індексі немає)"; fi
        if [ "$record" = 1 ]; then
          mkdir -p "$SKILL_NEEDS" 2>/dev/null || true
          # One file per need, named for the skill, so recording the same need twice does not
          # queue it twice — the channel is a set, not a log.
          # Structured, so `resolve` can act on it without guessing: which skill, why, and the
          # EXACT source — repository plus the path inside it, because a catalogue is a monorepo
          # and the repository alone is not an address.
          jq -n --arg skill "$sk" --arg feature "$f" --arg project "$PROJ" \
                --arg repo "$cand_repo" --arg path "$cand_path" --arg src "$cand_source" \
                --arg at "$(now_iso)" \
             '{skill:$skill, feature:$feature, project:$project, catalogue:$src,
               repo:$repo, path:$path, recorded_at:$at}' \
            > "$SKILL_NEEDS/$(safe_skill_name "$sk" || echo "$f").need" 2>/dev/null || true
        fi
      fi
    done
    [ "$missing" = 0 ] && echo "  нічого не бракує."
    [ "$record" = 1 ] && [ "$missing" -gt 0 ] && echo "  записано в $SKILL_NEEDS"
    exit 0 ;;

  resolve)
    # Carry recorded needs the rest of the way: fetch → quarantine → audit → project-local install.
    #
    # This is the half that was missing. `suggest --record` filed a need and nothing ever picked it
    # up, so "automatic skill selection" stopped at a note in a folder. Nothing here bypasses the
    # audit — resolve calls the SAME install path a human would, and a skill that does not pass
    # stays in quarantine with its need intact.
    PROJ="$(canon_path "${1:-$PWD}")"
    [ -d "$SKILL_NEEDS" ] || { echo "потреб немає"; exit 0; }
    installed=0; held=0; skipped=0
    for nf in "$SKILL_NEEDS"/*.need; do
      [ -f "$nf" ] || continue
      # A need written by a worker is one line of prose (that is what STANDARDS asks for) and has
      # no address in it. Those are for a human; only a structured need can be acted on.
      jq -e . "$nf" >/dev/null 2>&1 || { skipped=$((skipped + 1)); continue; }
      n_skill="$(jq -r '.skill // ""' "$nf")"; n_repo="$(jq -r '.repo // ""' "$nf")"
      n_path="$(jq -r '.path // ""' "$nf")";   n_proj="$(jq -r '.project // ""' "$nf")"
      [ -n "$n_skill" ] && [ -n "$n_repo" ] || { skipped=$((skipped + 1)); continue; }
      # A need recorded for a DIFFERENT project must not install itself into this one — compared
      # canonically, because `/var/…` and `/private/var/…` are the same directory and a need whose
      # path was not resolved was being dropped in silence.
      if [ -n "$n_proj" ]; then
        n_proj="$(canon_path "$n_proj" 2>/dev/null || printf '%s' "$n_proj")"
        [ "$n_proj" != "$PROJ" ] && { skipped=$((skipped + 1)); continue; }
      fi
      if skill_installed "$PROJ" "$n_skill"; then rm -f "$nf"; continue; fi
      echo "  ⏳ $n_skill ← $n_repo${n_path:+/$n_path}"
      # No path means the catalogue named a skill without saying where it lives. Installing from
      # the repository root would audit and install the WHOLE catalogue under that skill's name —
      # so this is left for a person rather than guessed at.
      if [ -z "$n_path" ]; then
        echo "  ⏭ $n_skill — джерело не каже, де саме він лежить; лишаю людині"
        skipped=$((skipped + 1)); continue
      fi
      "$0" install "$PROJ" "$n_repo" "$n_skill" --path "$n_path" >/dev/null 2>&1
      if [ $? -eq 0 ] && skill_installed "$PROJ" "$n_skill"; then
        rm -f "$nf"; installed=$((installed + 1)); echo "  ✅ $n_skill встановлено"
      else
        # The need stays: a skill held in quarantine is unfinished business, not a closed one.
        held=$((held + 1)); echo "  ⏸ $n_skill не пройшов аудит — лишається в карантині й у потребах"
      fi
    done
    echo "встановлено: $installed, у карантині: $held, для людини: $skipped"
    exit 0 ;;

  usage)
    # Which skills actually get used, and which have only ever cost context.
    #
    # No new instrumentation: a skill invocation is already recorded in Claude Code's transcript
    # as a tool_use named `Skill` with the skill name and a timestamp, so this reads evidence that
    # exists rather than asking anyone to start collecting it.
    #
    # It answers the question the director asked — «so that old skills nobody uses get cleaned out
    # once in a while» — and it answers it with a caveat printed next to the numbers: transcripts keep
    # what was kept, so "no uses" means "no evidence of use", not "never useful".
    exec python3 "$BIN_DIR/lib/skill-usage.py" "$@" ;;

  status)
    echo "quarantine: $QUARANTINE"; ls -1 "$QUARANTINE" 2>/dev/null | sed 's/^/  /' || true
    echo "locked skills:"; jq -r '.skills[]? | "  \(.name) [scope=\(.scope) tier=\(.tier)] \(.tree_sha256[0:12])"' "$SKILLS_LOCK" 2>/dev/null || echo "  (none)" ;;

  *) echo "usage: skill-resolver.sh audit <dir> | install <project> <source> [name] [--path <subdir>] | remove <project> <name> <scope> | update <project> <name> <scope> | verify | index [--refresh] | suggest [project] [--record] | resolve [project] | usage [project] [--json] | needs | status"; exit 1 ;;
esac
