#!/usr/bin/env bash
# gameplay.sh — record the three benchmark results being played, for the landing page.
#
# The page claims three games came out of three arrangements of the same night. A screenshot shows
# they exist; only moving pictures show they PLAY. So each clip is a real session against the live
# address: Chrome loads the game and clicks its way through the menus and the board with its own
# input pipeline, the same trusted events a hand at the trackpad sends. Nothing is staged, nothing
# is sped up, and no frame is composed by us — every pixel is the game rendering itself.
#
# Which move to make is decided by the game, not by us: each director (play-*.js) asks the game for
# the move it would hint to an idle player. That is why the clips look like someone who knows the
# rules rather than someone mashing a board.
#
#     bash site/demo/gameplay.sh            # all three into site/assets/
#     bash site/demo/gameplay.sh peer       # just one
#
# The viewport is 880×760 because that is where all three layouts fit whole: at the landing page's
# 1100×760 the second game's board is cut off at the top by its own centring, and a recording of a
# clipped board is worse than none.
#
# Each director disowns its warm-up frames (see --director in web-video.py), so the clips open on
# the board rather than on a splash screen — which is why the recording runs longer than the clip
# it produces. The poster is taken a third of the way in, from the clip itself: the still the page
# shows before anything plays is a frame of the same session.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/site/assets"
W=880
H=760
# Per run, because they do not spend the same time in their menus: the third game takes a level
# straight from the query string, the second has a home screen, a map, a card and an instruction
# sheet to get through, and only the frames after all that survive. These numbers put every clip
# near fifteen seconds of actual play.
runs=(
  "pure|https://claude-benchmark.stepanok.com/?debug=1|22"
  "review|https://benchmark.stepanok.com/|38"
  "peer|https://adaptive-peer.stepanok.com/?level=1|30"
)

want="${1:-all}"
made=0

for run in "${runs[@]}"; do
  IFS='|' read -r key url secs <<<"$run"
  [[ "$want" == "all" || "$want" == "$key" ]] || continue

  echo "── $key — playing $url"
  python3 "$ROOT/engine/bin/web-video.py" "$url" "$OUT/play-$key.mp4" \
    "${SECONDS_EACH:-$secs}" "$W" "$H" --director "$HERE/play-$key.js" >/dev/null

  # The poster: a frame a third of the way through, so nothing about the still is invented either.
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/play-$key.mp4")"
  ffmpeg -v error -y -ss "$(python3 -c "print(max(0.0, $dur / 3))")" \
    -i "$OUT/play-$key.mp4" -frames:v 1 -q:v 3 "$OUT/play-$key-poster.jpg"

  printf '   %s  %s KB video, %s KB poster\n' "$key" \
    "$(( $(wc -c < "$OUT/play-$key.mp4") / 1024 ))" \
    "$(( $(wc -c < "$OUT/play-$key-poster.jpg") / 1024 ))"
  made=$((made + 1))
done

[[ $made -gt 0 ]] || { echo "gameplay.sh: no run called '$want'" >&2; exit 2; }
echo "✅ $made clip(s) in site/assets — re-render the page to publish them"
