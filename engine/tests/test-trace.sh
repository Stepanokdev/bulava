#!/bin/bash
# The timeline itself, on a seeded night.
#
# This tool exists to be trusted at 3am: if it silently drops a lane, or misdates the two sources
# that timestamp in UTC, it will confidently show a night in which the report was announced before
# the run started — and the next hour goes into chasing a bug that is in the instrument.
#
# So: a fixture with one event in each lane, at known times, and assertions that all of them appear,
# in the right order, with the UTC ones converted to local.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d -t bulava-trace-test)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export SUPERVISOR_STATE_DIR="$TMP/supervisor"
export BULAVA_STATE_DIR="$TMP/app"
mkdir -p "$SUPERVISOR_STATE_DIR" "$BULAVA_STATE_DIR" "$TMP/proj"

# Times: local wall clock for the plain logs, UTC for the two JSON sources. Ten minutes ago, so any
# --since window in the test covers it, and the ordering between lanes is fixed and checkable.
local_at() { date -v-"$1"M '+%Y-%m-%d %H:%M:%S'; }
utc_at()   { date -u -v-"$1"M '+%Y-%m-%dT%H:%M:%SZ'; }

# engine: the run starts (10 minutes ago)
printf '%s [dispatch] inject rc=0 → night-fixture\n' "$(local_at 10)" > "$SUPERVISOR_STATE_DIR/supervisor.log"
# watchdog: it stalls (8)
printf '%s [fixture-000000000000] STALL 923s — parked\n' "$(local_at 8)" > "$SUPERVISOR_STATE_DIR/watchdog.log"
# app: what the app decided (9)
printf '{"ts":"%s","kind":"dispatch","task":"11111111","dispatch":"22222222","report":"33333333"}\n' \
  "$(local_at 9)" > "$SUPERVISOR_STATE_DIR/app-trace.jsonl"
# decision journal, UTC (7)
printf '{"ts":"%s","kind":"terminal","slug":"fixture-000000000000","run_id":"R","dispatch_id":"22222222-x","summary":"needs-user"}\n' \
  "$(utc_at 7)" > "$SUPERVISOR_STATE_DIR/decisions.jsonl"
# what landed in his thread, UTC (6)
cat > "$BULAVA_STATE_DIR/conversations.json" <<EOF
[{"id":"E1","productID":"P","kind":"report","at":"$(utc_at 6)","text":"Звіт по роботі","blocks":[],
  "tone":"neutral","chatID":"CHAT0001","taskID":"11111111-1111-4111-8111-111111111111","attachments":[]}]
EOF
# and what he was told, UTC (5)
cat > "$BULAVA_STATE_DIR/events.json" <<EOF
[{"id":"N1","at":"$(utc_at 5)","kind":"reportReady","severity":"good","title":"Звіт готовий"}]
EOF

out="$("$BIN_DIR/trace.sh" --since 30m 2>&1)"

echo "===== every lane arrives ====="
for lane in engine watchdog app decision chat note; do
  case "$out" in
    *"$lane"*) ok "$lane" ;;
    *) bad "the $lane lane is missing from the timeline" ;;
  esac
done

echo
echo "===== and in the order it happened ====="
# The two UTC lanes must land AFTER the local ones — if the conversion is wrong they land three
# hours out and this is the assertion that says so.
order="$(printf '%s\n' "$out" | awk '/  (engine|watchdog|app|decision|chat|note) / { print $2 }' | tr '\n' ' ')"
case "$order" in
  "engine app watchdog decision chat note "*) ok "sorted by time across all six sources" ;;
  *) bad "out of order: [$order]" ;;
esac

echo
echo "===== a narrower window drops what is outside it ====="
printf '%s [dispatch] ancient history\n' "$(date -v-3H '+%Y-%m-%d %H:%M:%S')" >> "$SUPERVISOR_STATE_DIR/supervisor.log"
near="$("$BIN_DIR/trace.sh" --since 30m 2>&1)"
case "$near" in
  *"ancient history"*) bad "--since kept an event from outside the window" ;;
  *) ok "--since 30m excludes an event from three hours ago" ;;
esac
far="$("$BIN_DIR/trace.sh" --since 6h 2>&1)"
case "$far" in
  *"ancient history"*) ok "--since 6h includes it" ;;
  *) bad "--since 6h lost an event inside the window" ;;
esac

echo
echo "===== --only narrows to the lanes asked for ====="
only="$("$BIN_DIR/trace.sh" --since 30m --only chat 2>&1)"
case "$only" in
  *"Звіт по роботі"*) ok "the lane asked for is there" ;;
  *) bad "--only dropped the lane it was given" ;;
esac
case "$only" in
  *"inject rc=0"*) bad "--only chat still printed the engine lane" ;;
  *) ok "and nothing else is" ;;
esac

echo
echo "===== a project filter keeps that project's own cards ====="
# The join goes through the backlog: this task belongs to the fixture project, so its conversation
# entry survives the filter. A task in another project must not.
cat > "$BULAVA_STATE_DIR/backlog.json" <<EOF
[{"id":"11111111-1111-4111-8111-111111111111","title":"Fixture","detail":"","type":"feature",
  "priority":2,"state":"blocked","createdAt":"$(utc_at 20)","updatedAt":"$(utc_at 6)",
  "projectPath":"$TMP/proj"}]
EOF
scoped="$("$BIN_DIR/trace.sh" --since 30m --project "$TMP/proj" --only chat 2>&1)"
case "$scoped" in
  *"Звіт по роботі"*) ok "the project's own card is kept" ;;
  *) bad "the project filter dropped that project's own conversation" ;;
esac
sed -i '' "s|$TMP/proj|$TMP/elsewhere|" "$BULAVA_STATE_DIR/backlog.json"
other="$("$BIN_DIR/trace.sh" --since 30m --project "$TMP/proj" --only chat 2>&1)"
case "$other" in
  *"Звіт по роботі"*) bad "another project's conversation showed under this project" ;;
  *) ok "another project's conversation does not" ;;
esac

echo
echo "===== a worktree run counts as its project's own work ====="
# An isolated run records the worktree's name; asking for the project must still show it.
printf '{"ts":"%s","kind":"dispatch","task":"11111111","project":"proj-DEADBEEF","detail":"isolated=true"}\n' \
  "$(local_at 4)" >> "$SUPERVISOR_STATE_DIR/app-trace.jsonl"
wt="$("$BIN_DIR/trace.sh" --since 30m --project "$TMP/proj" --only app 2>&1)"
case "$wt" in
  *"proj-DEADBEEF"*) ok "the worktree's own dispatch is kept under the project" ;;
  *) bad "asking for the project hid the half of the night that ran in a worktree" ;;
esac

echo
echo "===== a project whose name is a PREFIX of another is not mixed with it ====="
# The complaint that produced this test: a prefix match is a match that is almost right. "atlas" and
# "atlas-mobile" are two products in the same sidebar; a worktree of the second must never answer for
# the first, while a worktree of the first still must.
mkdir -p "$TMP/atlas" "$TMP/atlas-mobile"
own_slug="$(cd "$TMP/atlas" && "$BIN_DIR/night-shift.sh" --print-slug 2>/dev/null || true)"
sib="atlas-mobile-52F3B57A-a9f66bd35fee"          # a worktree run of the OTHER product
mine_wt=""
{
  printf '%s [night-shift] run-id handshake confirmed (%s)\n' "$(local_at 3)" "$sib"
  # A line attributed only by its path. `scope=` is the shape an older engine wrote, and the log it
  # wrote into outlives the version that produced it — a timeline asked for today still has to
  # attribute yesterday's lines to the right product rather than to the one whose name is a prefix.
  printf '%s [learn] routed 2 new lesson(s) (scope=%s)\n' "$(local_at 3)" "$TMP/atlas-mobile"
} >> "$SUPERVISOR_STATE_DIR/supervisor.log"
pref="$("$BIN_DIR/trace.sh" --since 30m --project "$TMP/atlas" --only engine 2>&1)"
case "$pref" in
  *atlas-mobile*) bad "a run of «atlas-mobile» showed up under «atlas»" ;;
  *) ok "«atlas» does not answer for «atlas-mobile»" ;;
esac
# And the same slug, asked for by its real owner, is kept.
own="$("$BIN_DIR/trace.sh" --since 30m --project "$TMP/atlas-mobile" --only engine 2>&1)"
case "$own" in
  *"$sib"*) ok "and «atlas-mobile» still sees its own worktree run" ;;
  *) bad "the owner lost its own worktree run" ;;
esac
case "$own" in
  *"scope=$TMP/atlas-mobile"*) ok "a line attributed only by path lands on the right project" ;;
  *) bad "the path-attributed line was dropped from its own project" ;;
esac

echo
[ "$fails" = 0 ] && echo "✅ trace: one timeline, correctly dated" || echo "❌ $fails problem(s)"
exit "$fails"
