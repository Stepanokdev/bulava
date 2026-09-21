#!/usr/bin/env python3
"""check-video.py — prove the gameplay clips actually play, on both languages.

    check-video.py <rendered-dir>

A `<video>` tag on a page proves nothing: the file can be missing, the wrong type, zero bytes, or
correct and never started because the script that starts it is broken. So this serves the rendered
directory over HTTP, opens each page in Chrome, scrolls the clips into view the way a reader would
and then asks the page itself: does this element have picture, has its clock moved, is it running.

It also insists on the poster and on the still inside the tag — the two things a reader sees when
autoplay is refused or video is unsupported — and on the clips being small enough to hand over a
connection somebody is paying for.

Prints what it proved and exits 0, or says what is wrong and exits 1. Needs Chrome; nothing about
the screen, so it runs headless, unattended, with no capture permission anywhere near it.
"""
import http.server
import importlib.util
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CLIPS = ("play-pure", "play-review", "play-peer")
MAX_MB = 2.5                     # per clip; three of these is already a few seconds of someone's data
ROUTES = ("index.html", "uk/index.html")


def load_recorder():
    """The CDP client lives in the recorder that made the clips; there is no second copy."""
    path = os.path.join(ROOT, "engine", "bin", "web-video.py")
    spec = importlib.util.spec_from_file_location("web_video", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def serve(directory):
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=directory, **kw)

        def log_message(self, *a):                             # not a web server's log, ours
            pass

    class Quiet(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

        def handle_error(self, request, client_address):       # a closed video stream is normal
            pass

    httpd = Quiet(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


# Measured one clip at a time, each while it is the one on the screen. The page starts a clip when
# it scrolls into view and pauses it when it leaves — which is the behaviour we want — so asking
# all three at the end would find two of them correctly stopped and call that a failure.
PROBE = """
(async () => {
  const wait = (ms) => new Promise(r => setTimeout(r, ms));
  const clips = [...document.querySelectorAll('video.clip')];
  if (!clips.length) return JSON.stringify({ error: 'no video.clip on the page' });
  const seen = [];
  for (const clip of clips) {
    clip.scrollIntoView({ block: 'center' });
    await wait(2600);
    seen.push({
      src: (clip.currentSrc || '').split('/').pop(),
      poster: (clip.poster || '').split('/').pop(),
      label: clip.getAttribute('aria-label') || '',
      still: !!clip.querySelector('img'),
      width: clip.videoWidth,
      height: clip.videoHeight,
      duration: Math.round((clip.duration || 0) * 10) / 10,
      time: clip.currentTime,
      playing: !clip.paused && !clip.ended,
      ready: clip.readyState,
      net: clip.networkState,
      failed: clip.error ? clip.error.code : 0,
    });
  }
  return JSON.stringify(seen);
})()
"""


def main():
    if len(sys.argv) < 2:
        print("usage: check-video.py <rendered-dir>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    problems = []

    # --- the files themselves ------------------------------------------------------------------
    #
    # The renderer writes the pages and, beside each one, the list of what it names: published
    # path, the file on disk it came from, its digest. The copying into assets/ is the publisher's
    # job, so the files are read from where the manifest says they live.
    manifest = {}
    for sidecar in ("index.html.assets", "uk/index.html.assets"):
        path = os.path.join(root, sidecar)
        if not os.path.exists(path):
            continue
        for line in open(path, encoding="utf-8"):
            published, source, digest = line.rstrip("\n").split("\t")
            manifest[published] = source
    if not manifest:
        print(f"{root} has no asset manifest beside its pages — it was not rendered by site/render.py")
        return 1
    by_name = {os.path.basename(source): (pub, source) for pub, source in manifest.items()}
    for name in CLIPS:
        for wanted in (name + ".mp4", name + "-poster.jpg"):
            if wanted not in by_name:
                problems.append(f"{wanted} is not among the assets the page names")
                continue
            source = by_name[wanted][1]
            size = os.path.getsize(source) if os.path.exists(source) else 0
            if not size:
                problems.append(f"{wanted} is missing or empty at {source}")
            elif wanted.endswith(".mp4") and size > MAX_MB * 1024 * 1024:
                problems.append(f"{wanted} is {size / 1048576:.1f} MB — over the {MAX_MB} MB a clip may weigh")
    if problems:
        print("\n".join(problems))
        return 1

    # --- the site as a browser would be given it ------------------------------------------------
    served = tempfile.mkdtemp(prefix="check-video-")
    for route in ROUTES:
        dest = os.path.join(served, route)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(os.path.join(root, route), dest)
    for published, source in manifest.items():
        dest = os.path.join(served, published)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(source, dest)
    root = served

    wv = load_recorder()
    chrome = wv.find_chrome()
    if not chrome:
        print("no Chrome or Chromium found — playback cannot be proven, and an unproven clip is"
              " the thing this check exists to refuse")
        return 1

    httpd, port = serve(root)
    port_url = f"http://127.0.0.1:{port}/"
    proved = []
    profile = tempfile.mkdtemp(prefix="check-video-profile-")
    port_cdp = wv.free_port()
    proc = subprocess.Popen(
        [chrome, "--headless=new", "--disable-gpu", "--mute-audio", "--no-first-run",
         "--no-default-browser-check", "--autoplay-policy=no-user-gesture-required",
         f"--remote-debugging-port={port_cdp}", f"--user-data-dir={profile}",
         "--window-size=1280,900", "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ws = None
    try:
        target = wv.page_socket(port_cdp, time.time() + 20)
        if not target:
            print("Chrome never exposed a page — playback could not be checked")
            return 1
        ws = wv.WS(target)
        state = {"id": 0}

        def call(method, params=None, timeout=25):
            state["id"] += 1
            want = state["id"]
            ws.send({"id": want, "method": method, "params": params or {}})
            deadline = time.time() + timeout
            while time.time() < deadline:
                try:
                    msg = ws.recv()
                except Exception:
                    continue
                if msg.get("id") == want:
                    if "error" in msg:
                        raise IOError(msg["error"].get("message", "call failed"))
                    return msg.get("result", {})
            raise IOError(f"no reply to {method}")

        call("Page.enable")
        call("Runtime.enable")
        for route in ROUTES:
            url = port_url + route
            nav = call("Page.navigate", {"url": url})
            if nav.get("errorText"):
                problems.append(f"{route}: the page did not load ({nav['errorText']})")
                continue
            time.sleep(1.5)
            got = call("Runtime.evaluate",
                       {"expression": PROBE, "awaitPromise": True, "returnByValue": True},
                       timeout=60)
            if got.get("exceptionDetails"):
                problems.append(f"{route}: the page threw while playing"
                                f" ({got['exceptionDetails'].get('text')})")
                continue
            report = json.loads(got.get("result", {}).get("value") or "null") or {}
            if isinstance(report, dict) and report.get("error"):
                problems.append(f"{route}: {report['error']}")
                continue
            if len(report) != len(CLIPS):
                problems.append(f"{route}: {len(report)} clip(s) on the page, expected {len(CLIPS)}")
            for clip in report:
                name = clip["src"] or "(no source)"
                if not clip["width"] or not clip["height"]:
                    # The two ways a clip shows nothing are worth telling apart: a file the
                    # browser refused, and a file the browser was never asked for because
                    # whatever was supposed to start it no longer does.
                    if clip["failed"]:
                        problems.append(f"{route}: {name} produced no picture — the browser"
                                        f" refused the file (media error {clip['failed']})")
                    elif clip["ready"] == 0 and clip["net"] in (0, 1):
                        problems.append(f"{route}: {name} was never even asked for — nothing on"
                                        " the page starts the clips any more")
                    else:
                        problems.append(f"{route}: {name} produced no picture"
                                        f" (readyState {clip['ready']}, network {clip['net']})")
                    continue
                if clip["ready"] < 2:
                    problems.append(f"{route}: {name} never got as far as having data")
                if not clip["time"]:
                    problems.append(f"{route}: {name} has picture but its clock never moved —"
                                    " nothing is playing")
                if not clip["playing"]:
                    problems.append(f"{route}: {name} is not running")
                if clip["duration"] < 5:
                    problems.append(f"{route}: {name} is {clip['duration']}s long — too short to"
                                    " show a game being played")
                if not clip["poster"]:
                    problems.append(f"{route}: {name} has no poster, so it is a black box until"
                                    " it starts")
                if not clip["still"]:
                    problems.append(f"{route}: {name} carries no still inside the tag for a"
                                    " browser that cannot play video")
                if not clip["label"]:
                    problems.append(f"{route}: {name} has no label — nothing to read aloud")
                if not problems:
                    proved.append(f"{route}: {name} {clip['width']}×{clip['height']},"
                                  f" {clip['duration']}s, running at {clip['time']:.1f}s")
    except IOError as exc:
        problems.append(f"Chrome stopped answering: {exc}")
    finally:
        if ws:
            ws.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        httpd.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
        shutil.rmtree(served, ignore_errors=True)

    if problems:
        print("\n".join(problems))
        return 1
    names = []
    for line in proved:
        short = re.sub(r"^[a-z/.]*index\.html: ", "", line)
        if short not in names:
            names.append(short)
    print(f"{len(proved)} clip(s) played in a real browser, {len(ROUTES)} languages: "
          + "; ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
