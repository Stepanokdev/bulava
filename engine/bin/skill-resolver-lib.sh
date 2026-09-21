#!/bin/bash
ORCH_HOME="${SUPERVISOR_ORCH_HOME:-$HOME/.orchestrator}"
QUARANTINE="$ORCH_HOME/skill-quarantine"
SKILLS_LOCK="${SUPERVISOR_SKILLS_LOCK:-$ORCH_HOME/skills.lock}"
SKILL_NEEDS="$ORCH_HOME/skill-needs"

source_tier() {  # $1=source url/path
  local s="$1" host="" repo="" allow="$ORCH_HOME/skill-sources.json" h
  case "$s" in
    *://*)  host="$(printf '%s' "$s" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+).*#\1#')"
            repo="$(printf '%s' "$s" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/([^/]+/[^/]+).*#\1#')" ;;
    git@*)  host="$(printf '%s' "$s" | sed -E 's#^git@([^:]+):.*#\1#')"
            repo="$(printf '%s' "$s" | sed -E 's#^git@[^:]+:([^/]+/[^/]+).*#\1#')" ;;
    *)      echo 3; return ;;   # local path / bare name / unknown → Tier 3
  esac
  repo="${repo%.git}"
  case "$host/$repo" in
    github.com/anthropics/skills|*.githubusercontent.com/anthropics/skills) echo 1; return;;
  esac
  case "$host" in claudeskills.info|www.claudeskills.info) echo 1; return;; esac
  if [ -f "$allow" ]; then
    while IFS= read -r h; do [ -n "$h" ] && [ "$host" = "$h" ] && { echo 2; return; }; done < <(jq -r '.tier2_hosts[]?' "$allow" 2>/dev/null)
  fi
  case "$host" in skills.sh|*.skills.sh) echo 2; return;; esac
  echo 3
}

safe_skill_name() {  # $1=raw name
  local raw="$1" n
  case "$raw" in */*|*..*) return 1;; esac      # separators / traversal → reject, don't mangle
  n="$(printf '%s' "$raw" | tr -cd 'A-Za-z0-9._-')"
  case "$n" in ''|.|..) return 1;; esac
  printf '%s' "$n"
}

tree_sha256() {  # $1=dir
  { find "$1" -type f -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort \
      | while IFS= read -r f; do shasum -a 256 "$f" 2>/dev/null; done; } | shasum -a 256 | cut -c1-64
}

lock_add() {  # env: NAME SOURCE_URL REPO COMMIT TREE_SHA TIER SCOPE STAGE_A STAGE_B INSTALLED_AT
  mkdir -p "$(dirname "$SKILLS_LOCK")"
  [ -f "$SKILLS_LOCK" ] || echo '{"version":1,"skills":[]}' > "$SKILLS_LOCK"
  local tmp; tmp="$(mktemp)"
  jq --arg name "$NAME" --arg url "${SOURCE_URL:-}" --arg repo "${REPO:-}" --arg commit "${COMMIT:-}" \
     --arg sha "${TREE_SHA:-}" --argjson tier "${TIER:-1}" --arg scope "${SCOPE:-project}" \
     --arg sa "${STAGE_A:-}" --arg sb "${STAGE_B:-}" --arg at "${INSTALLED_AT:-}" '
    .skills = ([.skills[] | select(.name != $name)] + [{
      name:$name, source_url:$url, repo:$repo, commit:$commit, tree_sha256:$sha,
      tier:$tier, scope:$scope, allowed_net:[], allowed_commands:[],
      audit:{stage_a:$sa, stage_b:$sb}, eval_score:null, installed_at:$at, review_date:$at
    }])' "$SKILLS_LOCK" > "$tmp" 2>/dev/null && mv "$tmp" "$SKILLS_LOCK"
}

detect_features() {  # $1=project dir → space-separated feature names
  local d="${1:-.}" out="" list
  local self_root; self_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  list="$(mktemp)" || return 0
  find "$d" \
    \( -name '.*' -a -type d \) -prune -o \
    \( -name node_modules -o -name build -o -name Pods -o -name DerivedData -o -name vendor \
       -o -name dist -o -name target -o -name venv -o -name env -o -name site-packages \
       -o -name Carthage -o -name bower_components -o -name __pycache__ \
       -o -path "$self_root" \) -prune -o \
    -type f \( -name '*.swift' -o -name '*.kt' -o -name '*.kts' -o -name '*.java' \
       -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.c' -o -name '*.cc' \
       -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.vue' \
       -o -name '*.py' -o -name '*.go' -o -name '*.rb' -o -name '*.dart' -o -name '*.rs' \
       -o -name '*.cs' -o -name '*.php' -o -name '*.gradle' -o -name 'package.json' \
       -o -name 'Podfile' -o -name 'pubspec.yaml' -o -name '*.entitlements' -o -name 'Info.plist' \) \
    -print0 2>/dev/null > "$list"
  [ -s "$list" ] || { rm -f "$list"; echo ""; return 0; }

  _fscan() {  # $1 = pattern → 0 if any scanned file matches
    xargs -0 grep -lE -e "$1" < "$list" 2>/dev/null | head -1 | grep -q .
  }
  _fscan 'import StoreKit|SKProduct|Product\.products|com\.android\.billingclient|BillingClient' \
    && out="$out in-app-purchase"
  _fscan 'UNUserNotificationCenter|FirebaseMessaging|registerForRemoteNotifications|expo-notifications' \
    && out="$out push-notifications"
  _fscan 'ASAuthorization|SignInWithApple|GoogleSignIn|supabase\.auth|next-auth|OAuth2|firebase/auth' \
    && out="$out auth"
  _fscan 'import Stripe|stripe\.com/v1|PaymentIntent|checkout\.session|"stripe"' && out="$out payments"
  _fscan 'import HealthKit|HKHealthStore' && out="$out healthkit"
  _fscan 'AVCaptureSession|MediaRecorder\(|getUserMedia' && out="$out media-capture"
  _fscan 'import CoreData|NSPersistentContainer|import SwiftData|@Model' && out="$out local-persistence"
  rm -f "$list"

  local locales
  locales=$(find "$d" \( -name '.*' -a -type d \) -prune -o \
    \( -name node_modules -o -name Pods -o -name build -o -name DerivedData -o -name vendor \) -prune -o \
    \( -name '*.lproj' -o -name 'values-*' \) -print 2>/dev/null | wc -l | tr -d ' ')
  [ "${locales:-0}" -gt 1 ] && out="$out localization"
  find "$d" \( -name '.*' -a -type d \) -prune -o \
    \( -name node_modules -o -name Pods -o -name build -o -name DerivedData \) -prune -o \
    -name '*.xcstrings' -print -quit 2>/dev/null | grep -q . \
    && out="$out localization"

  printf '%s\n' $out | sort -u | grep -v '^$' | tr '\n' ' '
}

# A feature signal → the skill that answers it, but ONLY a skill that can actually be had.
#
# The old table named five skills — storekit-subscriptions, push-notifications, auth-flows,
# payments-integration, localization-workflow — and not one of them exists in any catalogue this
# resolver can reach. So `suggest` printed "not in the index" for every project it ever looked at,
# `resolve` had nothing to fetch, and a need was filed and never picked up: eight of them had piled
# up in ~/.orchestrator/skill-needs, the oldest from July. One project went through that path
# many times and no skill was ever installed.
#
# A name that cannot be resolved is worse than no name: it produces a need nobody can satisfy and
# hides the real answer, which is usually "the director already owns a skill for this". So the
# table now maps only to skills the index knows or the machine already has, and everything else is
# deliberately silent — `skill_suggestion_for_feature` below says what a human should do with the
# signal instead.
skill_for_feature() {  # $1=feature → skill name, or nothing
  local f="$1" want=""
  case "$f" in
    localization)      want="localization-workflow" ;;
    auth)              want="auth-flows" ;;
    payments)          want="payments-integration" ;;
    in-app-purchase)   want="storekit-subscriptions" ;;
    push-notifications) want="push-notifications" ;;
    *)                 return 0 ;;   # a signal with no skill behind it is not a need
  esac
  [ -n "$want" ] || return 0
  # Installed already (any scope) → naming it is useful: `suggest` reports it as present.
  if skill_installed "${SKILL_FEATURE_PROJECT:-$PWD}" "$want"; then echo "$want"; return 0; fi
  # Not installed: only name it if it can actually be fetched, i.e. the catalogue has it.
  if [ -f "$SKILL_INDEX" ] \
     && jq -e --arg n "$want" '[.skills[]? | select((.name // "") == $n)] | length > 0' \
             "$SKILL_INDEX" >/dev/null 2>&1; then
    echo "$want"
  fi
  return 0
}

# What a signal means when no obtainable skill answers it.
#
# This is the honest half of the above: the signal is real and worth telling someone about, it just
# is not a download. Printed by `suggest` so a feature never disappears in silence.
skill_note_for_feature() {  # $1=feature → one line for a person, or nothing
  case "$1" in
    in-app-purchase)    echo "покупки в застосунку — скіла в каталозі немає; дивись памʼять продукту про підписки" ;;
    push-notifications) echo "пуші — скіла в каталозі немає; вимоги до платформи описані в памʼяті продукту" ;;
    auth)               echo "авторизація — скіла в каталозі немає; секрети та deep links описані в памʼяті продукту" ;;
    payments)           echo "платежі — скіла в каталозі немає" ;;
    localization)       echo "локалізація — скіла в каталозі немає" ;;
    healthkit)          echo "HealthKit" ;;
    media-capture)      echo "запис аудіо/відео" ;;
    local-persistence)  echo "локальне сховище" ;;
    *)                  : ;;
  esac
}

skill_installed() {  # $1=project dir $2=skill name
  local d="$1" n="$2"
  [ -f "$d/.claude/skills/$n/SKILL.md" ] && return 0
  [ -f "$d/.agents/skills/$n/SKILL.md" ] && return 0
  [ -f "$HOME/.claude/skills/$n/SKILL.md" ] && return 0
  ls "$HOME/.claude/plugins"/*/"$n"/SKILL.md >/dev/null 2>&1 && return 0
  ls "$HOME/.claude/plugins"/*/skills/"$n"/SKILL.md >/dev/null 2>&1 && return 0
  return 1
}

SKILL_INDEX="$ORCH_HOME/skill-index.json"

skill_sources_file() {
  local user="$ORCH_HOME/skill-sources.json" shipped="$ROOT/supervisor/skill-sources.json"
  [ -f "$shipped" ] || shipped="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supervisor" 2>/dev/null && pwd)/skill-sources.json"
  if [ -f "$user" ] && jq -e '.sources? | type == "array"' "$user" >/dev/null 2>&1; then
    jq -s '{sources: (map(.sources[]?) | unique_by(.manifest))}' "$shipped" "$user" 2>/dev/null && return 0
  fi
  cat "$shipped" 2>/dev/null
}

skill_fetch_manifest() {
  if [ -n "${SUPERVISOR_SKILL_FETCH_CMD:-}" ]; then
    "$SUPERVISOR_SKILL_FETCH_CMD" "$1"
    return $?
  fi
  curl -sS --fail --location --max-time 20 \
       --max-filesize "${SUPERVISOR_SKILL_INDEX_MAX:-2000000}" "$1" 2>/dev/null
}

skill_index_rows() {  # stdin = manifest json; $1 = source name; $2 = repo url
  jq -c --arg src "$1" --arg repo "$2" '
    (.plugins? // []) as $plugins
    | [ $plugins[]
        | . as $p
        | ( ($p.skills? // [])
            | if length > 0 then
                # THREE shapes in the wild, and the third was found only by running this against
                # the real catalogues: claude-plugins-official lists objects, anthropics/skills
                # lists PATHS as bare strings ("./skills/xlsx"), and some list neither. jq errors
                # on `.name` applied to a string, which silently emptied that whole source.
                map( if type == "string"
                     then { name: (split("/") | last), description: "", plugin: ($p.name? // ""),
                            # WHERE inside the repo it lives. Without this the installer only knew
                            # the catalogue, and a catalogue is a monorepo of many skills — it
                            # could not fetch the one that was actually needed.
                            path: (sub("^\\./"; "")) }
                     else { name: (.name? // .id? // ""),
                            description: (.description? // ""),
                            plugin: ($p.name? // ""),
                            path: ((.source? // .path? // "") | sub("^\\./"; "")) }
                     end )
              else
                [ { name: ($p.name? // ""),
                    description: ($p.description? // ""),
                    plugin: ($p.name? // ""),
                    path: (($p.source? // "") | if type == "string" then sub("^\\./"; "") else "" end) } ]
              end )
        | .[] ]
    | map(select(.name != ""))
    | map(. + {source: $src, repo: $repo})
    | .[]' 2>/dev/null
}

lock_remove() {  # $1=skill name $2=scope (required: two scopes may hold the same name)
  [ -f "$SKILLS_LOCK" ] || return 0
  local tmp; tmp="$(mktemp)"
  jq --arg name "$1" --arg scope "${2:-}" '
    .skills = [.skills[] | select((.name != $name) or ($scope != "" and (.scope // "project") != $scope))]
  ' "$SKILLS_LOCK" > "$tmp" 2>/dev/null && mv "$tmp" "$SKILLS_LOCK"
}

skill_location() {  # $1=project dir $2=name $3=scope(project|global|plugin|"") → "<scope>\t<dir>"
  local d="$1" n="$2" want="${3:-}" p
  case "$want" in
    project) [ -f "$d/.claude/skills/$n/SKILL.md" ] && { printf 'project\t%s\n' "$d/.claude/skills/$n"; return 0; }
             [ -f "$d/.agents/skills/$n/SKILL.md" ] && { printf 'project\t%s\n' "$d/.agents/skills/$n"; return 0; }
             return 1 ;;
    global)  [ -f "$HOME/.claude/skills/$n/SKILL.md" ] && { printf 'global\t%s\n' "$HOME/.claude/skills/$n"; return 0; }
             return 1 ;;
    plugin)  for p in "$HOME/.claude/plugins"/*/"$n" "$HOME/.claude/plugins"/*/skills/"$n"; do
               [ -f "$p/SKILL.md" ] && { printf 'plugin\t%s\n' "$p"; return 0; }
             done
             return 1 ;;
  esac
  [ -f "$d/.claude/skills/$n/SKILL.md" ] && { printf 'project\t%s\n' "$d/.claude/skills/$n"; return 0; }
  [ -f "$d/.agents/skills/$n/SKILL.md" ] && { printf 'project\t%s\n' "$d/.agents/skills/$n"; return 0; }
  [ -f "$HOME/.claude/skills/$n/SKILL.md" ] && { printf 'global\t%s\n' "$HOME/.claude/skills/$n"; return 0; }
  for p in "$HOME/.claude/plugins"/*/"$n" "$HOME/.claude/plugins"/*/skills/"$n"; do
    [ -f "$p/SKILL.md" ] && { printf 'plugin\t%s\n' "$p"; return 0; }
  done
  return 1
}
