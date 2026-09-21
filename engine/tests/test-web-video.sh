#!/bin/bash
# A web report can have a real video, and it needs no permission for it.
#
# Chrome renders the page, so Chrome can hand over its frames through the DevTools protocol. Nothing
# captures the screen, so none of the TCC trouble around native capture applies: it works headless, in
# the background, on a locked machine. The older trick — one tall render panned by ffmpeg — is still
# there as a fallback, and is labelled as what it is rather than as a recording.
set -u
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

fails=0
ok()  { printf '  \xe2\x9c\x85 %s\n' "$1"; }
bad() { printf '  \xe2\x9d\x8c %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
SRV_PID=""
trap 'rm -rf "$TMP"; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT

command -v ffmpeg >/dev/null 2>&1 || { echo "SKIP: ffmpeg not installed"; exit 0; }
CHROME=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  [ -x "$c" ] && CHROME="$c"
done
[ -n "$CHROME" ] || { echo "SKIP: no Chrome installed"; exit 0; }

echo "===== usage and preconditions are stated, not guessed ====="

out="$(python3 "$BIN_DIR/web-video.py" 2>&1 || true)"
case "$out" in *usage*) ok "no arguments prints usage" ;; *) bad "unhelpful with no arguments: $out" ;; esac

echo "===== a real page becomes a real video ====="

mkdir -p "$TMP/site"
cat > "$TMP/site/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Demo</title>
<style>body{margin:0;font:16px system-ui;background:#101018;color:#eee}
.row{padding:26px 32px;border-bottom:1px solid #2a2a38}</style>
<h1 style="padding:32px">Demo</h1>
<script>document.body.insertAdjacentHTML('beforeend',
  Array.from({length:40},(_,i)=>`<div class="row">Рядок ${i+1}</div>`).join(''));</script>
HTML

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
( cd "$TMP/site" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) & SRV_PID=$!
sleep 1.5

if python3 "$BIN_DIR/web-video.py" "http://127.0.0.1:$PORT/" "$TMP/v.mp4" 3 800 600 >/dev/null 2>&1; then
  ok "the recorder finished"
else
  bad "the recorder failed on a live page"
fi
[ -s "$TMP/v.mp4" ] && ok "an mp4 exists" || bad "no mp4"

if command -v ffprobe >/dev/null 2>&1 && [ -s "$TMP/v.mp4" ]; then
  frames="$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$TMP/v.mp4" 2>/dev/null | tr -d ',')"
  codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$TMP/v.mp4" 2>/dev/null | tr -d ',[:space:]')"
  [ "${frames:-0}" -ge 8 ] && ok "it has real frames (${frames})" || bad "only ${frames:-0} frame(s) — a still, not a video"
  [ "$codec" = "h264" ] && ok "encoded as h264" || bad "unexpected codec: $codec"

  # The frames must DIFFER: a video of a static viewport would be honest but useless, and the whole
  # point of stepping the scroll is that each frame is a real change.
  ffmpeg -v error -y -i "$TMP/v.mp4" -vf "select=eq(n\,1)" -vframes 1 "$TMP/f1.png" 2>/dev/null
  ffmpeg -v error -y -i "$TMP/v.mp4" -vf "select=eq(n\,6)" -vframes 1 "$TMP/f2.png" 2>/dev/null
  if [ -s "$TMP/f1.png" ] && [ -s "$TMP/f2.png" ]; then
    if cmp -s "$TMP/f1.png" "$TMP/f2.png"; then
      bad "every frame is identical — nothing was actually happening"
    else
      ok "the page moves between frames"
    fi
  fi
fi

echo "===== it leaves nothing behind ====="

[ -d "$TMP/v.mp4.frames" ] && bad "the frame directory was left behind" || ok "no frame directory"
[ -d "$TMP/v.mp4.profile" ] && bad "the Chrome profile was left behind" || ok "no Chrome profile"
pgrep -f "user-data-dir=$TMP/v.mp4.profile" >/dev/null 2>&1 && bad "a Chrome process is still running" \
                                                            || ok "no Chrome left running"

echo "===== a director clicks with the real mouse, and only the frames it owns are kept ====="

# The page under test reacts to trusted input only: a click made in page script has
# `isTrusted === false`, and this button ignores those. So if the counter moves at all, the clicks
# came from the browser's own input pipeline — which is the whole claim `--director` makes.
cat > "$TMP/site/game.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>0</title>
<style>body{margin:0;background:#111;color:#eee;font:16px system-ui}
button{position:absolute;left:120px;top:160px;width:180px;height:70px;font-size:20px}
#n{position:absolute;left:120px;top:60px;font-size:64px}</style>
<div id="n">0</div><button id="go">Click me</button>
<script>
  let n = 0;
  document.getElementById('go').addEventListener('click', (e) => {
    if (!e.isTrusted) return;                 // script-made events do not count
    n += 1;
    document.getElementById('n').textContent = n;
    document.title = String(n);
  });
</script>
HTML

cat > "$TMP/director.js" <<'JS'
(() => {
  let done = 0;
  window.__director = {
    step() {
      const b = document.getElementById('go');
      const r = b.getBoundingClientRect();
      // The first four frames are disowned, so a clip shorter than the session proves the
      // warm-up frames were really dropped rather than merely counted.
      const record = done >= 4;
      if (done >= 30) return { record };
      done += 1;
      return { acts: [{ t: 'click', x: r.left + r.width / 2, y: r.top + r.height / 2 }], record };
    },
  };
})()
JS

if python3 "$BIN_DIR/web-video.py" "http://127.0.0.1:$PORT/game.html" "$TMP/g.mp4" 4 500 400 \
     --director "$TMP/director.js" >/dev/null 2>&1; then
  ok "the recorder finished with a director"
else
  bad "the recorder failed with a director"
fi
[ -s "$TMP/g.mp4" ] && ok "an mp4 exists" || bad "no mp4 from the director run"

if command -v ffprobe >/dev/null 2>&1 && [ -s "$TMP/g.mp4" ]; then
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/g.mp4" | cut -d. -f1)"
  [ "${dur:-9}" -lt 4 ] && ok "the disowned warm-up frames are not in the clip (${dur}s of 4)"                         || bad "the clip is ${dur}s — the frames the director disowned were kept"
  # The counter is drawn large in the corner: if the clicks landed, the last frame differs from
  # the first, and both are of the same still page.
  ffmpeg -v error -y -i "$TMP/g.mp4" -vf "select=eq(n\,0)" -vframes 1 "$TMP/g1.png" 2>/dev/null
  ffmpeg -v error -y -sseof -0.4 -i "$TMP/g.mp4" -vframes 1 "$TMP/g2.png" 2>/dev/null
  if [ -s "$TMP/g1.png" ] && [ -s "$TMP/g2.png" ] && ! cmp -s "$TMP/g1.png" "$TMP/g2.png"; then
    ok "the page counted trusted clicks — the mouse was Chrome's, not a script's"
  else
    bad "nothing on the page changed: the clicks were not trusted input"
  fi
fi

rm -f "$TMP/idle.mp4"
cat > "$TMP/idle.js" <<'JS'
(() => { window.__director = { step() { return null; } }; })()
JS
python3 "$BIN_DIR/web-video.py" "http://127.0.0.1:$PORT/game.html" "$TMP/idle.mp4" 2 400 300 \
  --director "$TMP/idle.js" >/dev/null 2>&1
[ -e "$TMP/idle.mp4" ] && bad "wrote a clip for a director that never clicked" \
                       || ok "a director that never clicks produces no clip"

out="$(python3 "$BIN_DIR/web-video.py" "http://127.0.0.1:$PORT/" "$TMP/x.mp4" 2 400 300 \
        --drive "1" --director "$TMP/idle.js" 2>&1 || true)"
case "$out" in *"pick one"*) ok "--drive and --director together are refused" ;;
               *) bad "both ways of driving were accepted: $out" ;; esac

out="$(python3 "$BIN_DIR/web-video.py" "http://127.0.0.1:$PORT/" "$TMP/y.mp4" 2 400 300 \
        --director "$TMP/nothing-here.js" 2>&1 || true)"
case "$out" in *"no director script"*) ok "a missing director script is named" ;;
               *) bad "a missing director script was not reported: $out" ;; esac

echo "===== a page that cannot be reached fails honestly ====="

rm -f "$TMP/nope.mp4"
python3 "$BIN_DIR/web-video.py" "http://127.0.0.1:1/" "$TMP/nope.mp4" 2 400 300 >/dev/null 2>&1
[ -e "$TMP/nope.mp4" ] && bad "wrote a file for a page it could not load" \
                       || ok "no file when the page cannot be reached"

echo "===== the engine prefers the recording, and labels the fallback honestly ====="

grep -q 'web-video.py' "$BIN_DIR/capture.sh" \
  && ok "capture.sh tries the real recording first" || bad "capture.sh does not use the recorder"
grep -q 'панорама по одному рендеру сторінки — не запис' "$BIN_DIR/capture.sh" \
  && ok "and the pan is not called a recording" || bad "the fallback still claims to be a recording"

echo
if [ "$fails" -eq 0 ]; then echo "RESULT: all passed, 0 failed"; else echo "RESULT: $fails failed"; fi
exit "$fails"
