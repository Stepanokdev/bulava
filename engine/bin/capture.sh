#!/bin/bash
set -u
BIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN_DIR/supervisor-lib.sh" 2>/dev/null || true

CHECKOUT="${1:?usage: capture.sh <checkout-dir> <out-dir> <label> [stacks]}"
OUT="${2:?out-dir required}"
LABEL="${3:?label required}"
STACKS="${4:-$(detect_stacks "$CHECKOUT" 2>/dev/null || echo "")}"
mkdir -p "$OUT"
MANIFEST="$OUT/manifest.jsonl"

CAP_BUILD_TO="${NS_CAPTURE_BUILD_TIMEOUT:-360}"
CAP_SETTLE="${NS_CAPTURE_SETTLE:-4}"      # seconds to let a UI settle before the shot
CAP_VIDEO_SECS="${NS_CAPTURE_VIDEO_SECS:-6}"

note_manifest() {  # $1 kind  $2 file(rel or "")  $3 note  $4 ok(true/false)
  local f="${2:-}"
  jq -c -n --arg l "$LABEL" --arg k "$1" --arg f "$f" --arg n "${3:-}" --argjson ok "${4:-false}" \
    '{label:$l,kind:$k,file:$f,note:$n,ok:$ok}' >> "$MANIFEST" 2>/dev/null \
    || printf '{"label":"%s","kind":"%s","file":"%s","note":"%s","ok":%s}\n' "$LABEL" "$1" "$f" "${3:-}" "${4:-false}" >> "$MANIFEST"
}

with_timeout() { local to="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$to" "$@"; }

CAPTURE_CMD="$BIN_DIR/worker-capture.sh"

grab() {  # $1 = extra args ("" or "-Rx,y,w,h")  $2 = destination png
  local extra="${1:-}" dest="$2" region=""
  case "$extra" in -R*) region="${extra#-R}" ;; esac
  if [ -n "$region" ]; then
    "$CAPTURE_CMD" "$dest" "$region" >/dev/null 2>&1
  else
    "$CAPTURE_CMD" "$dest" >/dev/null 2>&1
  fi
  [ -s "$dest" ]
}

grab_window() {  # $1 = pid  $2 = destination png
  "$CAPTURE_CMD" "$2" --window "$1" >/dev/null 2>&1
  [ -s "$2" ]
}

grab_video() {  # $1 = destination mp4
  return 1
}

log() { printf '[capture:%s] %s\n' "$LABEL" "$*" >&2; }

capture_apple() {
  command -v xcodebuild >/dev/null 2>&1 || { note_manifest none "" "xcodebuild not found" false; return; }
  local scheme settings sdk dest dd
  scheme="$(cd "$CHECKOUT" && xcodebuild -list -json 2>/dev/null | jq -r '
    (.project // .workspace) as $c | (($c.schemes) // []) as $all | ($c.name // "") as $name
    | (($all | map(select(. == $name)) | first)
       // ($all | map(select(endswith("-Package") | not)) | first)
       // ($all | first) // empty)' 2>/dev/null)"
  [ -n "$scheme" ] || { note_manifest none "" "no xcodebuild scheme" false; return; }
  settings="$(cd "$CHECKOUT" && xcodebuild -scheme "$scheme" -showBuildSettings 2>/dev/null)"
  sdk="$(printf '%s\n' "$settings" | awk -F' = ' '/[[:space:]]SDKROOT[[:space:]]*=/{print $2; exit}')"
  dd="$OUT/DerivedData"
  case "$sdk" in
    *iPhoneSimulator*|*iphonesimulator*) dest='generic/platform=iOS Simulator' ;;
    *) dest='platform=macOS' ;;
  esac

  log "building $scheme for $dest"
  if ! with_timeout "$CAP_BUILD_TO" bash -c "cd '$CHECKOUT' && xcodebuild build -scheme '$scheme' -destination '$dest' -derivedDataPath '$dd' CODE_SIGNING_ALLOWED=NO >'$OUT/build-$LABEL.log' 2>&1"; then
    note_manifest none "" "build failed (see build-$LABEL.log)" false; return
  fi

  local app
  app="$(find "$dd/Build/Products" -maxdepth 2 -name '*.app' -print -quit 2>/dev/null)"
  [ -n "$app" ] || { note_manifest none "" "built but no .app product found" false; return; }

  if [ "$dest" = 'platform=macOS' ]; then
    capture_macos_app "$app"
  else
    capture_ios_sim "$app" "$scheme" "$dd"
  fi
}

capture_macos_app() {
  local app="$1" bundleid png mp4 winbounds
  bundleid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)"
  png="$OUT/$LABEL.png"; mp4="$OUT/$LABEL.mp4"

  local exe app_pid=""
  exe="$(find "$app/Contents/MacOS" -maxdepth 1 -type f -perm -u+x 2>/dev/null | head -1)"
  if [ -n "$exe" ]; then
    "$exe" >/dev/null 2>&1 &
    app_pid=$!
  else
    open -n "$app" 2>/dev/null || { note_manifest none "" "could not launch the built app" false; return; }
  fi
  sleep "$CAP_SETTLE"

  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $app_pid) to true" >/dev/null 2>&1
  elif [ -n "$bundleid" ]; then
    osascript -e "tell application id \"$bundleid\" to activate" >/dev/null 2>&1
  fi
  sleep 1.5

  winbounds="$(APP_PID="${app_pid:-0}" osascript 2>/dev/null <<OSA
try
  tell application "System Events"
    set wanted to (system attribute "APP_PID") as integer
    if wanted > 0 then
      set procs to (every process whose unix id is wanted)
    else
      set procs to {}
    end if
    if procs is {} then set procs to (every process whose bundle identifier is "$bundleid")
    if procs is {} then set procs to (every process whose frontmost is true)
    set p to item 1 of procs
    set frontmost of p to true
    delay 0.4
    set w to first window of p
    set {x, y} to position of w
    set {ww, hh} to size of w
    return (x as text) & "," & (y as text) & "," & (ww as text) & "," & (hh as text)
  end tell
end try
OSA
)"
  local shot_note="full-screen"
  if [ -n "$app_pid" ] && grab_window "$app_pid" "$png"; then
    # The window itself, not a rectangle cut out of the screen: exact, and it survives something
    # else covering part of it.
    shot_note="app window"
  elif [ -n "$winbounds" ]; then
    grab -R"$winbounds" "$png" && shot_note="app window (region)"
  else
    grab "" "$png"
  fi
  if [ -s "$png" ]; then note_manifest screenshot "$LABEL.png" "$shot_note" true
  else note_manifest none "" "не вдалось зняти екран навіть через дозволений процес" false; fi

  # A recording, when the platform can make one without a grant this process does not have.
  if grab_video "$mp4"; then
    note_manifest video "$LABEL.mp4" "${CAP_VIDEO_SECS}s screen capture" true
  else
    note_manifest none "" "запису екрана немає — знімки робить додаток, відео на macOS не пишемо" false
  fi

  # Terminate EXACTLY what we started. "quit the app with this bundle id" would close the
  # director's own running copy if one happened to be open.
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$app_pid" 2>/dev/null || true
  elif [ -n "$bundleid" ]; then
    osascript -e "tell application id \"$bundleid\" to quit" >/dev/null 2>&1
  fi
}

capture_ios_sim() {
  local app="$1" scheme="$2" dd="$3" udid bundleid png mp4 vpid
  command -v xcrun >/dev/null 2>&1 || { note_manifest none "" "xcrun not found" false; return; }
  # Pick a booted simulator, else the newest available iPhone runtime device.
  udid="$(xcrun simctl list devices booted 2>/dev/null | grep -Eo '[0-9A-F-]{36}' | head -1)"
  if [ -z "$udid" ]; then
    udid="$(xcrun simctl list devices available 2>/dev/null | grep -i iphone | grep -Eo '[0-9A-F-]{36}' | tail -1)"
    [ -n "$udid" ] && with_timeout 120 xcrun simctl boot "$udid" >/dev/null 2>&1
  fi
  [ -n "$udid" ] || { note_manifest none "" "no iOS simulator available" false; return; }
  with_timeout 90 xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
  bundleid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)"

  with_timeout 120 xcrun simctl install "$udid" "$app" >/dev/null 2>&1 || { note_manifest none "" "simctl install failed" false; return; }
  png="$OUT/$LABEL.png"; mp4="$OUT/$LABEL.mp4"

  # Record video across the launch, screenshot after settle.
  xcrun simctl io "$udid" recordVideo --codec h264 -f "$mp4" >/dev/null 2>&1 &
  vpid=$!
  [ -n "$bundleid" ] && with_timeout 60 xcrun simctl launch "$udid" "$bundleid" >/dev/null 2>&1
  sleep "$CAP_SETTLE"
  xcrun simctl io "$udid" screenshot "$png" >/dev/null 2>&1
  [ -s "$png" ] && note_manifest screenshot "$LABEL.png" "iOS simulator" true || note_manifest none "" "simctl screenshot failed" false
  sleep "$CAP_VIDEO_SECS"
  kill -INT "$vpid" >/dev/null 2>&1; wait "$vpid" 2>/dev/null
  [ -s "$mp4" ] && note_manifest video "$LABEL.mp4" "iOS simulator recording" true
  [ -n "$bundleid" ] && xcrun simctl terminate "$udid" "$bundleid" >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# Web (static or dev-served) via headless Chrome
# --------------------------------------------------------------------------
capture_web() {
  local chrome url png port root served=0 serverpid=""
  chrome="$(ns_find_chrome)"
  [ -n "$chrome" ] || { note_manifest none "" "no headless Chrome found" false; return; }
  png="$OUT/$LABEL.png"

  # Build if there's a build script and no dist yet.
  if [ -f "$CHECKOUT/package.json" ] && jq -e '.scripts.build // empty' "$CHECKOUT/package.json" >/dev/null 2>&1; then
    if [ ! -d "$CHECKOUT/dist" ] && [ ! -d "$CHECKOUT/build" ]; then
      (cd "$CHECKOUT" && with_timeout "$CAP_BUILD_TO" bash -c 'command -v npm >/dev/null && (npm ci --no-audit --no-fund >/dev/null 2>&1 || npm install >/dev/null 2>&1); npm run build >/dev/null 2>&1') || true
    fi
  fi

  root="$CHECKOUT"
  [ -d "$CHECKOUT/dist" ] && root="$CHECKOUT/dist"
  [ -d "$CHECKOUT/build" ] && root="$CHECKOUT/build"

  if [ -f "$root/index.html" ]; then
    port=$(( 8000 + RANDOM % 1000 ))
    ( cd "$root" && python3 -m http.server "$port" >/dev/null 2>&1 ) &
    serverpid=$!; served=1; sleep 1
    url="http://localhost:$port/index.html"
  else
    note_manifest none "" "no index.html to render" false; return
  fi

  with_timeout 60 "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --window-size=1440,900 --screenshot="$png" "$url" >/dev/null 2>&1
  [ -s "$png" ] && note_manifest screenshot "$LABEL.png" "headless Chrome @ 1440x900" true \
                || note_manifest none "" "headless Chrome produced no file" false

  capture_web_video "$chrome" "$url"
  [ "$served" = 1 ] && kill "$serverpid" >/dev/null 2>&1
}

# A video of the page. Two ways, and they are not the same thing.
#
# First choice is a REAL recording: Chrome renders the page, so Chrome can hand us its frames over
# the DevTools protocol (web-video.py). Nothing captures the screen, so no permission is involved at
# all — it works headless, in the background, on a locked machine. That is the one that can show a
# page actually behaving.
#
# Second choice is the older trick: one tall render, panned top to bottom by ffmpeg. It looks like a
# scroll and is nothing of the kind — a still image moving behind a window — so it is labelled as
# what it is rather than as a recording.
capture_web_video() {
  local chrome="$1" url="$2" tall h vh=900 mp4="$OUT/$LABEL.mp4"
  command -v ffmpeg >/dev/null 2>&1 || return 0

  if [ -x "$BIN_DIR/web-video.py" ] \
     && with_timeout 90 python3 "$BIN_DIR/web-video.py" "$url" "$mp4" \
          "${NS_CAPTURE_VIDEO_SECS:-6}" 1440 900 >/dev/null 2>&1 \
     && [ -s "$mp4" ]; then
    note_manifest video "$LABEL.mp4" "запис живої сторінки (Chrome DevTools, без дозволів)" true
    return 0
  fi

  command -v sips  >/dev/null 2>&1 || return 0
  tall="$OUT/.$LABEL-tall.png"
  with_timeout 60 "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --window-size=1440,2600 --screenshot="$tall" "$url" >/dev/null 2>&1
  [ -s "$tall" ] || return 0
  h="$(sips -g pixelHeight "$tall" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  if [ -n "$h" ] && [ "$h" -gt "$((vh + 120))" ]; then
    with_timeout 40 ffmpeg -y -loop 1 -i "$tall" -t 6 \
      -vf "crop=iw:${vh}:0:min(ih-${vh}\,t/6*(ih-${vh})),scale=1280:-2,format=yuv420p" \
      -r 30 "$mp4" >/dev/null 2>&1
    [ -s "$mp4" ] && note_manifest video "$LABEL.mp4" \
      "панорама по одному рендеру сторінки — не запис" true
  fi
  rm -f "$tall"
}

ns_find_chrome() {
  for c in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
    [ -x "$c" ] && { printf '%s' "$c"; return; }
  done
  command -v google-chrome 2>/dev/null || command -v chromium 2>/dev/null || true
}

# --------------------------------------------------------------------------

# Append to the manifest — report.sh calls this once per label (before/after)
# against the same output dir, and cleans the dir before the first call.
case " $STACKS " in
  *" ios-native "*|*" compose-multiplatform "*) capture_apple ;;
  *" web-frontend "*|*" web-landing "*)          capture_web ;;
  *) note_manifest none "" "no visual surface for stacks: ${STACKS:-none}" false ;;
esac

# Always exit 0 — capture is advisory. The manifest carries what happened.
exit 0
