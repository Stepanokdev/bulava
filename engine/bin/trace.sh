#!/bin/bash
set -u

SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do d="$(cd -P "$(dirname "$SELF")" && pwd)"; SELF="$(readlink "$SELF")"; case "$SELF" in /*) ;; *) SELF="$d/$SELF";; esac; done
BIN_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh"

SINCE="12h"
PROJ=""
LIMIT=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since)   SINCE="${2:?}"; shift 2 ;;
    --project) PROJ="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    --limit)   LIMIT="${2:-0}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$SELF"; exit 0 ;;
    *) echo "trace.sh: не знаю аргумент «$1»" >&2; exit 2 ;;
  esac
done

APP_STATE="${BULAVA_STATE_DIR:-$HOME/Library/Application Support/NightShift}"

num="${SINCE%[a-zA-Z]}"; unit="${SINCE##*[0-9]}"
case "$unit" in
  h|H) CUT="$(date -v-"${num}"H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" ;;
  m|M) CUT="$(date -v-"${num}"M '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" ;;
  d|D) CUT="$(date -v-"${num}"d '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" ;;
  *)   echo "trace.sh: --since хоче 30m / 12h / 2d, не «${SINCE}»" >&2; exit 2 ;;
esac
[ -n "$CUT" ] || { echo "trace.sh: не порахував вікно" >&2; exit 2; }

tz="$(date +%z)"                     # +0300
tz_sign="${tz:0:1}"; tz_h="${tz:1:2}"; tz_m="${tz:3:2}"
OFF=$(( 10#$tz_h * 3600 + 10#$tz_m * 60 ))
[ "$tz_sign" = "-" ] && OFF=$(( -OFF ))

want() { [ -z "$ONLY" ] || case ",$ONLY," in *,"$1",*) return 0 ;; *) return 1 ;; esac; }

SLUG=""; BASE=""; STEM=""; PROJ_RAW="$PROJ"
if [ -n "$PROJ" ]; then
  PROJ="$(canon_path "$PROJ")"
  SLUG="$(slug_for "$PROJ")"
  BASE="$(basename "$PROJ")"
  STEM="${SLUG%-*}"
fi

TMP="$(mktemp -t bulava-trace)" || exit 1
trap 'rm -f "$TMP" "$TMP.tasks" "$TMP.chats"' EXIT

: > "$TMP.tasks"; : > "$TMP.chats"
APP_SCOPED=0
if [ -n "$PROJ" ] && [ -f "$APP_STATE/backlog.json" ]; then
  APP_SCOPED=1
  jq -r --arg p "$PROJ" --arg praw "$PROJ_RAW" '
     [.[] | select([(.projectPath // ""), (.worktree // "")] | any(. == $p or . == $praw)) | .id] | .[]' \
     "$APP_STATE/backlog.json" 2>/dev/null > "$TMP.tasks" || true
  if [ -s "$TMP.tasks" ] && [ -f "$APP_STATE/conversations.json" ]; then
    jq -r --slurpfile ids <(jq -R . "$TMP.tasks" | jq -s .) \
       '[.[] | select((.taskID // "") as $t | ($ids[0] | index($t)) != null) | .chatID // empty] | unique | .[]' \
       "$APP_STATE/conversations.json" 2>/dev/null > "$TMP.chats" || true
  fi
fi

plain_log() {
  local src="$1" path="$2"
  [ -f "$path" ] || return 0
  LC_ALL=C awk -v src="$src" -v cut="$CUT" -v slug="$SLUG" -v stem="$STEM" -v base="$BASE" '
    # Is this run one of THIS project?
    #
    # Its own slug, or the slug of a worktree of it: an isolated run is "atlas-mobile-52F3B57A-<hash>"
    # against "atlas-mobile-<hash>" for the project itself, and it is the same work. Excluding it
    # hid the one line that explained a whole evening — inject rc=1 — whenever a project was named.
    #
    # The worktree segment must LOOK like a task id (eight hex, upper case, the way the app names
    # them). A plain prefix test was too generous in a way that matters here: asking about "atlas"
    # would have swept in every "atlas-mobile" run, which is a different product in the same sidebar.
    # (No apostrophes in here: the whole awk program is one single-quoted shell string.)
    function mine(named,   s) {
      if (named == slug) return 1
      s = named; sub(/-[0-9a-f]{12}$/, "", s)
      return (s ~ ("^" quote(stem) "-[0-9A-Fa-f]{8}$"))
    }
    # A project name can hold any of `. * + ? ( ) [ ] { } | ^ $ \` — none of which may act as a
    # pattern here.
    function quote(t,   out, i, c) {
      out = ""
      for (i = 1; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c ~ /[][(){}.*+?^$|\\\/]/) out = out "\\" c; else out = out c
      }
      return out
    }
    # WHO does this line belong to: "mine", "other", or nothing at all.
    #
    # Every slug-shaped token is examined, wherever it sits — in brackets, in parentheses, inside an
    # instances/ path, behind a night- session name. Chasing each of those shapes with its own
    # regular expression is how two lines about a different product still reached a timeline asked
    # for by project: the handshake line writes its slug in parentheses, which none of the shapes
    # matched. A line with a path but no slug is attributed by that path.
    #
    # Lines with NO attribution at all are kept: that is where the review gate says most of what
    # matters, and dropping them would hide the reasoning.
    function owner(text,   t, tok, seen_mine, seen_other, p, b) {
      t = text
      while (match(t, /[A-Za-z0-9._-]+-[0-9a-f]{12}/)) {
        tok = substr(t, RSTART, RLENGTH)
        sub(/^night-/, "", tok)
        if (mine(tok)) seen_mine = 1; else seen_other = 1
        t = substr(t, RSTART + RLENGTH)
      }
      if (seen_mine) return "mine"
      if (seen_other) return "other"
      # A path instead: the engine writes scope=/full/path for its own bookkeeping lines.
      if (match(text, /scope=[^ ]+/)) {
        p = substr(text, RSTART + 6, RLENGTH - 6)
        # The engine writes it inside parentheses, and a greedy run of non-spaces swallows the
        # closing one: "atlas-mobile)" is not "atlas-mobile", so the line was attributed to nobody
        # it belonged to. Trailing punctuation is never part of a path.
        sub(/[)\]}>",;:.]+$/, "", p)
        b = p; sub(/.*\//, "", b)
        if (b == "") return ""
        if (b == base) return "mine"
        if (b ~ ("^" quote(base) "-[0-9A-Fa-f]{8}$")) return "mine"
        return "other"
      }
      return ""
    }
    /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} / {
      key = substr($0, 1, 19)
      if (key < cut) next
      rest = substr($0, 21)
      if (slug != "" && owner(rest) == "other") next
      print key "\t" src "\t" rest
    }' "$path" >> "$TMP"
}
want engine   && plain_log engine   "$SUP_STATE/supervisor.log"
want watchdog && plain_log watchdog "$SUP_STATE/watchdog.log"

if want app && [ -f "$SUP_STATE/app-trace.jsonl" ]; then
  jq -r --arg cut "$CUT" --arg base "$BASE" '
    select(.ts >= $cut)
    # An isolated run records the name of its worktree ("atlas-mobile-940C06C0") and is still work
    # done for that project, so asking for the project must not hide half of the night. The suffix
    # has to look like a task id, or asking about "atlas" would drag in "atlas-mobile".
    # (No apostrophes in here: the whole jq program is one single-quoted shell string.)
    | select($base == "" or ((.project // $base) | . == $base
             or test("^" + ($base | gsub("(?<c>[.*+?^${}()|\\[\\]\\\\])"; "\\(.c)")) + "-[0-9A-Fa-f]{8}$")))
    | [.ts, "app",
       ([.kind,
         (if .task     then "task=" + .task         else empty end),
         (if .dispatch then "dispatch=" + .dispatch else empty end),
         (if .report   then "report=" + .report     else empty end),
         (if .chat     then "chat=" + .chat         else empty end),
         (if .project  then .project                else empty end),
         (if .file     then .file                   else empty end),
         (if .detail   then .detail                 else empty end)] | join(" "))]
    | @tsv' "$SUP_STATE/app-trace.jsonl" 2>/dev/null >> "$TMP" || true
fi

if want decision && [ -f "$SUP_STATE/decisions.jsonl" ]; then
  jq -r --arg cut "$CUT" --arg slug "$SLUG" --argjson off "$OFF" '
    (.ts | fromdateiso8601 + $off | strftime("%Y-%m-%d %H:%M:%S")) as $local
    | select($local >= $cut)
    | select($slug == "" or (.slug // "") == "" or .slug == $slug)
    | [$local, "decision",
       ([.kind, (.summary // "")] + [(if .dispatch_id != "" then "dispatch=" + (.dispatch_id | .[0:8] | ascii_upcase) else empty end)] | join(" "))]
    | @tsv' "$SUP_STATE/decisions.jsonl" 2>/dev/null >> "$TMP" || true
fi

if want chat && [ -f "$APP_STATE/conversations.json" ] \
   && { [ "$APP_SCOPED" = 0 ] || [ -s "$TMP.chats" ]; }; then
  jq -r --arg cut "$CUT" --argjson off "$OFF" \
        --slurpfile chats <(jq -R . "$TMP.chats" | jq -s .) '
    .[]
    | (.at | fromdateiso8601 + $off | strftime("%Y-%m-%d %H:%M:%S")) as $local
    | select($local >= $cut)
    # Bound to a name first: inside index(f) the filter f sees the ARRAY as its input, not the
    # object, so `index(.chatID)` asks the list for its own chatID and jq stops on the whole file.
    | (.chatID // "") as $chat
    | select(($chats[0] | length) == 0 or ($chats[0] | index($chat)) != null)
    | [$local, "chat",
       ([.kind,
         "chat=" + ((.chatID // "-") | .[0:8]),
         (if .taskID then "task=" + (.taskID | .[0:8]) else empty end),
         (if (.blocks | length) > 0 then "blocks=" + ((.blocks | length) | tostring) else empty end),
         "«" + ((.text // "") | gsub("\n"; " ") | .[0:100]) + "»"] | join(" "))]
    | @tsv' "$APP_STATE/conversations.json" 2>/dev/null >> "$TMP" || true
fi

if want note && [ -f "$APP_STATE/events.json" ] \
   && { [ "$APP_SCOPED" = 0 ] || [ -s "$TMP.tasks" ]; }; then
  jq -r --arg cut "$CUT" --argjson off "$OFF" \
        --slurpfile ids <(jq -R . "$TMP.tasks" | jq -s .) '
    .[]
    | (.at | fromdateiso8601 + $off | strftime("%Y-%m-%d %H:%M:%S")) as $local
    | select($local >= $cut)
    | (.taskID // "") as $task
    | select(($ids[0] | length) == 0 or $task == "" or ($ids[0] | index($task)) != null)
    | [$local, "note",
       ([.kind, (.severity // ""),
         (if .taskID then "task=" + (.taskID | .[0:8]) else empty end),
         ((.title // "") | gsub("\n"; " ") | .[0:110])] | join(" "))]
    | @tsv' "$APP_STATE/events.json" 2>/dev/null >> "$TMP" || true
fi

lines="$(wc -l < "$TMP" | tr -d ' ')"
printf '── %s → зараз' "$CUT"
[ -n "$PROJ" ] && printf '  ·  %s (%s)' "$BASE" "$SLUG"
printf '  ·  %s подій\n' "$lines"
if [ "$lines" = "0" ]; then
  echo "   (нічого — або вікно завузьке, або ця версія застосунку ще не пише app-trace.jsonl)"
  exit 0
fi
LC_ALL=C sort -t "$(printf '\t')" -k1,1 -s "$TMP" \
  | { [ "$LIMIT" -gt 0 ] && tail -n "$LIMIT" || cat; } \
  | awk -F "$(printf '\t')" '
      # The line shows the time; the date announces itself when it changes, so a window that
      # crosses midnight — which every night run does — still says which day is which.
      { day = substr($1, 1, 10)
        if (day != last) { printf "\n%s\n", day; last = day }
        printf "%s  %-8s %s\n", substr($1, 12), $2, $3 }'
