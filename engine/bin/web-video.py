#!/usr/bin/env python3
"""web-video.py — record a short video of a web page, with no screen-recording permission at all.

Chrome renders the page, so Chrome can hand us its frames: `Page.startScreencast` streams JPEGs over
the DevTools protocol. Nothing captures the screen, so none of the TCC trouble that surrounds native
capture applies here — this works headless, in the background, on a locked machine.

    web-video.py <url> <out.mp4> [seconds] [width] [height] [--drive <js>] [--director <file.js>]

By default each frame is preceded by a scroll step, which is how a static page demonstrates
itself. `--drive` replaces that with an expression of your own, evaluated in the page before every
frame — which is how a page that is not a document demonstrates itself: a canvas game has nothing
to scroll, and without this the recording is eight seconds of a board sitting still.

`--director` is the same idea for something that is not a document AND does not respond to script.
A canvas game reads the mouse, and events made in page script are untrusted and easy to ignore
(several of ours do), so the file it names installs `window.__director` in the page and its
`step()` returns WHERE to click — the clicking itself is then done by Chrome, through
`Input.dispatchMouseEvent`, which is the same trusted event a hand at the trackpad produces. The
page decides what a good move is, because it is the only thing that knows; the browser plays it.

Writes the mp4 and prints its path. On failure it says why on stderr and writes nothing: a report
that admits it has no recording is honest, a placeholder is not.

The websocket client is hand-rolled because the alternative is a dependency for ~70 lines of RFC 6455
that we fully control: a client handshake, masked text frames out, unmasked frames in. No extensions,
no fragmentation beyond what CDP actually sends.
"""
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
from hashlib import sha1
from secrets import token_bytes


def die(msg, code=1):
    print(f"web-video: {msg}", file=sys.stderr)
    sys.exit(code)


# --- a minimal websocket client ------------------------------------------------

class WS:
    def __init__(self, url, timeout=20):
        if not url.startswith("ws://"):
            raise ValueError("only ws:// is needed here")
        rest = url[len("ws://"):]
        hostport, _, path = rest.partition("/")
        host, _, port = hostport.partition(":")
        self.sock = socket.create_connection((host, int(port or 80)), timeout=timeout)
        key = base64.b64encode(token_bytes(16)).decode()
        req = (f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               f"Sec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        head = self._read_until(b"\r\n\r\n")
        # Pulled out of the f-string on purpose: an expression inside one may not contain a
        # backslash before Python 3.12, and stock macOS ships 3.9 — so this line was a syntax error
        # on every Mac without a newer python3 installed, and the recorder never started there.
        status = head.split(b"\r\n")[0]
        if b"101" not in status:
            raise IOError("handshake refused: %r" % (status,))
        expect = base64.b64encode(
            sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if expect.lower().encode() not in head.lower():
            raise IOError("handshake accept mismatch")
        self.buf = b""

    def _read_until(self, marker):
        data = b""
        while marker not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("closed during handshake")
            data += chunk
        return data

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, obj):
        payload = json.dumps(obj).encode()
        header = b"\x81"
        n = len(payload)
        if n < 126:
            header += struct.pack("B", 0x80 | n)
        elif n < 1 << 16:
            header += struct.pack("!BH", 0x80 | 126, n)
        else:
            header += struct.pack("!BQ", 0x80 | 127, n)
        mask = token_bytes(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def recv(self):
        """One message, as a decoded object. Continuation frames are joined."""
        chunks = []
        while True:
            b1, b2 = self._recv_exact(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            length = b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8))[0]
            data = self._recv_exact(length) if length else b""
            if opcode == 0x8:            # close
                raise IOError("peer closed")
            if opcode == 0x9:            # ping → pong
                self.sock.sendall(b"\x8a\x80" + token_bytes(4))
                continue
            if opcode == 0xA:            # pong
                continue
            chunks.append(data)
            if fin:
                break
        return json.loads(b"".join(chunks).decode())

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# --- Chrome --------------------------------------------------------------------

def find_chrome():
    for candidate in (os.environ.get("NS_CHROME"),
                      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                      "/Applications/Chromium.app/Contents/MacOS/Chromium",
                      shutil.which("chromium"), shutil.which("google-chrome")):
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def page_socket(port, deadline):
    """The page target's websocket URL, once Chrome is listening and has a page."""
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=2) as r:
                for t in json.load(r):
                    if t.get("type") == "page" and t.get("webSocketDebuggerUrl"):
                        return t["webSocketDebuggerUrl"]
        except Exception:
            pass
        time.sleep(0.3)
    return None


def main():
    if len(sys.argv) < 3:
        die("usage: web-video.py <url> <out.mp4> [seconds] [width] [height]"
            " [--drive <js>] [--director <file.js>]", 2)
    args = sys.argv[1:]
    drive = None
    if "--drive" in args:
        i = args.index("--drive")
        if i + 1 >= len(args):
            die("--drive needs an expression", 2)
        drive = args[i + 1]
        args = args[:i] + args[i + 2:]
    director = None
    if "--director" in args:
        i = args.index("--director")
        if i + 1 >= len(args):
            die("--director needs a file", 2)
        path = args[i + 1]
        if not os.path.isfile(path):
            die(f"no director script at {path}", 2)
        director = open(path, encoding="utf-8").read()
        args = args[:i] + args[i + 2:]
    if drive and director:
        die("--drive and --director both decide what happens before a frame; pick one", 2)
    url, out = args[0], args[1]
    seconds = float(args[2]) if len(args) > 2 else 6.0
    width = int(args[3]) if len(args) > 3 else 1440
    height = int(args[4]) if len(args) > 4 else 900

    chrome = find_chrome()
    if not chrome:
        die("no Chrome or Chromium found", 3)
    if not shutil.which("ffmpeg"):
        die("ffmpeg not found — cannot assemble the frames", 3)

    frames_dir = out + ".frames"
    wrote = False
    os.makedirs(frames_dir, exist_ok=True)
    for stale in os.listdir(frames_dir):
        os.remove(os.path.join(frames_dir, stale))

    port = free_port()
    # Chrome's profile goes to a temporary directory, not next to the output: it is scratch, it is
    # still being written to for a moment after Chrome is asked to quit, and a caller that tried
    # to tidy it up itself got "Directory not empty" and lost the recording it had just made.
    profile = tempfile.mkdtemp(prefix="web-video-profile-")
    proc = subprocess.Popen(
        [chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
         "--no-first-run", "--no-default-browser-check", "--mute-audio",
         f"--remote-debugging-port={port}", f"--user-data-dir={profile}",
         f"--window-size={width},{height}", url],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    ws = None
    try:
        target = page_socket(port, time.time() + 20)
        if not target:
            die("Chrome never exposed a page to record", 4)
        ws = WS(target)

        msg_id = 0

        def call(method, params=None):
            nonlocal msg_id
            msg_id += 1
            ws.send({"id": msg_id, "method": method, "params": params or {}})
            return msg_id

        msg_id = 0

        def call(method, params=None):
            nonlocal msg_id
            msg_id += 1
            ws.send({"id": msg_id, "method": method, "params": params or {}})
            return msg_id

        def result(want_id, timeout=8):
            """Wait for the reply to one call, ignoring the event traffic in between."""
            deadline = time.time() + timeout
            while time.time() < deadline:
                try:
                    msg = ws.recv()
                except (socket.timeout, TimeoutError):
                    continue
                if msg.get("id") == want_id:
                    if "error" in msg:
                        raise IOError(msg["error"].get("message", "call failed"))
                    return msg.get("result", {})
            raise IOError(f"no reply to call {want_id}")

        call("Page.enable")
        call("Runtime.enable")
        # Chrome will not make a window narrower or shorter than its own floor (~500px), so
        # `--window-size` alone silently records a viewport of some other size than the one asked
        # for — a game's pre-level dialog was cut off at the bottom of the frame that way. The
        # override sets the viewport itself, which is what the frames are of.
        try:
            result(call("Emulation.setDeviceMetricsOverride", {
                "width": width, "height": height, "deviceScaleFactor": 2, "mobile": False,
            }), timeout=8)
        except IOError:
            pass                                   # older Chrome: fall back to the window size
        nav = result(call("Page.navigate", {"url": url}), timeout=20)
        # A navigation that failed still "succeeds": Chrome loads its own error page and would be
        # recorded as if it were the product. `errorText` is how it says so.
        if nav.get("errorText"):
            die(f"the page did not load: {nav['errorText']}", 4)
        # Let the page settle before recording, so the first frame is not a blank document.
        time.sleep(1.2)

        mouse = {"x": 0.0, "y": 0.0}

        def act(one):
            """Perform one instruction from the director, as a real browser input event."""
            kind = one.get("t")
            if kind == "wait":
                time.sleep(min(2.0, max(0.0, float(one.get("ms", 0)) / 1000.0)))
                return
            x = float(one.get("x", mouse["x"]))
            y = float(one.get("y", mouse["y"]))
            mouse["x"], mouse["y"] = x, y
            steps = {"move": ["mouseMoved"], "down": ["mousePressed"], "up": ["mouseReleased"],
                     "click": ["mouseMoved", "mousePressed", "mouseReleased"]}.get(kind)
            if not steps:
                raise IOError(f"the director asked for {kind!r}, which is not a mouse event")
            for name in steps:
                held = 1 if name == "mousePressed" else 0
                result(call("Input.dispatchMouseEvent", {
                    "type": name, "x": x, "y": y,
                    "button": "none" if name == "mouseMoved" else "left",
                    "buttons": held, "clickCount": 0 if name == "mouseMoved" else 1,
                }), timeout=5)
                if name == "mousePressed":
                    time.sleep(0.05)

        if director:
            try:
                got = result(call("Runtime.evaluate", {
                    "expression": director, "awaitPromise": True, "returnByValue": True,
                }), timeout=20)
            except IOError as exc:
                die(f"the director script would not run: {exc}", 4)
            if got.get("exceptionDetails"):
                die("the director script threw: "
                    + str(got["exceptionDetails"].get("text", "")), 4)
            ready = result(call("Runtime.evaluate", {
                "expression": "typeof (window.__director || {}).step === 'function'",
                "returnByValue": True,
            }), timeout=5)
            if not ready.get("result", {}).get("value"):
                die("the director script ran but installed no window.__director.step()", 4)

        # Frames are REQUESTED, one at a time, not streamed.
        #
        # `Page.startScreencast` is the obvious way and it does not work in `--headless=new`: there is
        # no compositor ticking, so a scroll or an in-page animation produced exactly one frame. Asking
        # for each frame is a request/response — deterministic, no compositor involved — and at a dozen
        # frames a second for a few seconds it is fast enough. The scroll is stepped from here for the
        # same reason: it is the page demonstrating itself, and every step is a real change.
        n = 0
        moves = 0
        skipped = 0
        ticks = max(8, int(seconds * 12))
        step_delay = seconds / ticks
        ws.sock.settimeout(10)
        for i in range(ticks):
            t = i / max(1, ticks - 1)
            eased = t * 2 if t < 0.5 else (2 - t * 2)      # down the page, then back up
            if director:
                expression = "JSON.stringify(window.__director.step() || null)"
            elif drive:
                expression = drive
            else:
                expression = ("(() => { const e = document.scrollingElement || document.body;"
                              " const max = Math.max(0, e.scrollHeight - window.innerHeight);"
                              f" e.scrollTop = max * {eased:.4f}; return e.scrollTop; }})()")
            try:
                got = result(call("Runtime.evaluate", {
                    "expression": expression, "awaitPromise": True, "returnByValue": True,
                }), timeout=8)
                if director:
                    if got.get("exceptionDetails"):
                        die("the director threw while playing: "
                            + str(got["exceptionDetails"].get("text", "")), 5)
                    plan = json.loads(got.get("result", {}).get("value") or "null")
                    for one in (plan or {}).get("acts", []):
                        act(one)
                        moves += 1
                    # A director may disown a frame: `record: false` means this one is still
                    # warm-up — a splash screen, a menu, a card being dismissed — and keeping it
                    # would put five seconds of navigation at the front of every clip. The frame
                    # is dropped, the clock is not: the tick still costs its share of `seconds`.
                    if (plan or {}).get("record") is False:
                        skipped += 1
                        time.sleep(step_delay)
                        continue
                shot = result(call("Page.captureScreenshot",
                                   {"format": "jpeg", "quality": 80}), timeout=10)
            except IOError as exc:
                die(f"Chrome stopped answering after {n} frame(s): {exc}", 5)
            data = shot.get("data")
            if not data:
                continue
            with open(os.path.join(frames_dir, f"{n:05d}.jpg"), "wb") as fh:
                fh.write(base64.b64decode(data))
            n += 1
            time.sleep(step_delay)
        if n < 2:
            die(f"only {n} frame(s) arrived — nothing to assemble", 5)
        if director and moves == 0:
            die("the director never clicked anything — this would be a recording of a still"
                " page, so nothing was written", 5)

        # The frames that were kept, over the time they were kept across: a director that
        # disowned its first five seconds leaves a shorter clip, not a slower one.
        kept_seconds = max(0.5, seconds * n / max(1, n + skipped))
        fps = max(4, min(30, round(n / kept_seconds)))
        r = subprocess.run(
            ["ffmpeg", "-y", "-framerate", str(fps), "-i", os.path.join(frames_dir, "%05d.jpg"),
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
             # A page carries these over somebody's connection, so the encoder is told to work
             # for its size rather than to finish quickly.
             "-crf", "30", "-preset", "slow",
             # Frames arrive at twice this size, because the viewport is captured at a device
             # scale factor of 2 — text stays sharp when it is scaled back down here. h264 needs
             # even dimensions, hence the rounding.
             "-vf", f"scale={width - width % 2}:{height - height % 2}:flags=lanczos", out],
            capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out) or os.path.getsize(out) == 0:
            die(f"ffmpeg failed: {(r.stderr or '')[-300:]}", 6)
        print(out)
        wrote = True
    finally:
        if ws:
            ws.close()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)
        # The frames are an implementation detail on the way to the mp4. They are kept when the
        # recording failed, because then they are the only evidence of what Chrome was showing.
        if wrote:
            shutil.rmtree(frames_dir, ignore_errors=True)
        shutil.rmtree(frames_dir, ignore_errors=True)
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
