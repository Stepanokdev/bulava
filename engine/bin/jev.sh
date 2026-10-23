#!/bin/bash
# The director's switch for Jev (see jev-lib.sh): the key, the mode, and how it has been deciding.
#
#   jev.sh status [--json]          mode, whether a key is stored (never the key), model
#   jev.sh key set                  store the key: typed (hidden); --clipboard reads the clipboard;
#                                   --env reads JEV_HANDED_KEY (how the app hands it over)
#   jev.sh key remove
#   jev.sh mode off|shadow|on       off is the default; shadow records, on decides
#   jev.sh test [--json]            one real call: model, seconds, input tokens
#   jev.sh log [N]                  the last N decisions (default 20)
set -u
SELF="${BASH_SOURCE[0]}"; while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
# The key handed over by the app is read before anything is sourced, and the variable is gone
# before anything is started: nothing this script runs is meant to see it.
HANDED_KEY="${JEV_HANDED_KEY:-}"; unset JEV_HANDED_KEY
. "$BIN_DIR/supervisor-lib.sh"
mkdir -p "$SUP_STATE"
# A key exported by hand would otherwise ride along into curl and anything else started from here.
strip_paid_api_env >/dev/null 2>&1 || true

usage() { sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'; }

store_key() {   # $1 = key → Keychain, through stdin so it never sits in anyone's argv
  printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' "$JEV_KEYCHAIN_SERVICE" "$JEV_KEYCHAIN_ACCOUNT" "$1" \
    | security -i >/dev/null 2>&1
}

case "${1:-status}" in
  status)
    has=false; jev_key >/dev/null && has=true
    if [ "${2:-}" = --json ]; then
      jq -nc --arg mode "$(jev_mode)" --argjson key "$has" --arg model "$SUPERVISOR_JEV_MODEL" \
         --argjson decisions "$(grep -c . "$SUP_STATE/jev/relation.jsonl" 2>/dev/null || echo 0)" \
         '{mode:$mode, key:$key, model:$model, decisions:$decisions}'
    else
      printf 'mode:   %s\n' "$(jev_mode)"
      printf 'model:  %s\n' "$SUPERVISOR_JEV_MODEL"
      [ "$has" = true ] && printf 'key:    stored in the Keychain («%s»)\n' "${JEV_KEYCHAIN_SERVICE}" || printf 'key:    none\n'
    fi
    ;;
  key)
    case "${2:-}" in
      set)
        case "${3:-}" in
          --clipboard) k="$(pbpaste 2>/dev/null | tr -d '[:space:]')" ;;
          --env)       k="$(printf '%s' "$HANDED_KEY" | tr -d '[:space:]')" ;;
          "")
            [ -t 0 ] || { echo "❌ no terminal to type into — copy the key and run: jev.sh key set --clipboard" >&2; exit 2; }
            printf 'TypeSafe API key (not shown): ' >&2; IFS= read -rs k; echo >&2
            k="$(printf '%s' "$k" | tr -d '[:space:]')" ;;
          *) usage; exit 2 ;;
        esac
        jev_key_valid "$k" || { echo "❌ that does not look like an API key — nothing stored" >&2; exit 2; }
        store_key "$k" || { echo "❌ the Keychain refused the key" >&2; exit 1; }
        [ "${3:-}" = --clipboard ] && printf '' | pbcopy 2>/dev/null
        JEV_KEY=""
        jev_key >/dev/null && echo "✅ key stored in the Keychain («${JEV_KEYCHAIN_SERVICE}»)" \
          || { echo "❌ stored, but it cannot be read back" >&2; exit 1; }
        ;;
      remove)
        security delete-generic-password -s "$JEV_KEYCHAIN_SERVICE" -a "$JEV_KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
          && echo "✅ key removed" || echo "no key was stored"
        ;;
      *) usage; exit 2 ;;
    esac
    ;;
  mode)
    case "${2:-}" in
      off|shadow|on)
        printf '%s\n' "$2" > "$SUP_STATE/jev-mode"; echo "jev: $2"
        # Without a key nothing will be asked — worth hearing now, not from a log.
        [ "$2" = off ] || jev_key >/dev/null || echo "⚠️  no key stored, so nothing will be asked yet: jev.sh key set" >&2
        ;;
      "") jev_mode; echo ;;
      *) usage; exit 2 ;;
    esac
    ;;
  test)
    if ! jev_key >/dev/null; then
      [ "${2:-}" = --json ] && jq -nc '{ok:false, error:"no-key"}' || echo "❌ no key — jev.sh key set" >&2
      exit 2
    fi
    jev_relation "Add a status filter to the Reports tab" \
                 "The filter is in place; the tests pass." "The ticket was updated again, check whether our filter still matches it" \
                 "$SUPERVISOR_JEV_TIMEOUT"
    verdict="$JEV_VERDICT"
    if [ -n "$JEV_P" ]; then
      if [ "${2:-}" = --json ]; then
        jq -nc --arg model "$JEV_MODEL" --arg s "$JEV_SECONDS" --argjson tok "${JEV_TOKENS:-0}" --arg v "$verdict" --arg p "$JEV_P" \
           '{ok:true, model:$model, seconds:($s|tonumber? // null), input_tokens:$tok, verdict:$v, p:($p|tonumber? // null)}'
      else
        echo "✅ $JEV_MODEL answered in ${JEV_SECONDS}s, ${JEV_TOKENS} input tokens — «ticket updated, check» reads as: $verdict ($JEV_P)"
      fi
    else
      [ "${2:-}" = --json ] && jq -nc --arg e "${JEV_ERR:-unknown}" '{ok:false, error:$e}' \
        || echo "❌ the call failed: ${JEV_ERR:-?}" >&2
      exit 1
    fi
    ;;
  log)
    n="${2:-20}"; case "$n" in ''|*[!0-9]*) n=20 ;; esac
    tail -n "$n" "$SUP_STATE/jev/relation.jsonl" 2>/dev/null \
      | jq -r '"\(.ts)  \(.case)  \(.mode)  jev=\(.verdict) (\(.p // "-"))  → \(.applied)  \(.seconds // "-")s  \(.input_tokens) tok"'
    ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
