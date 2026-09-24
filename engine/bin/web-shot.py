#!/usr/bin/env python3
"""web-shot.py — a screenshot of a web page, with no screen-recording permission and no MCP.

    web-shot.py <url> <out.png> [width] [height] [--full] [--wait seconds]

Chrome renders the page and hands us the pixels over the DevTools protocol, exactly as web-video.py
records frames. Nothing captures the screen, so none of the TCC trouble applies: this works headless,
in the background, on a locked machine.

It exists because the director asked a run to open a browser and it said it could not. It was telling
the truth about what it had been given — the report contract pointed at "chrome-devtools MCP or a
headless browser", and there was no MCP installed and nothing named that a worker could invoke. The
capability was here all along, in this directory, with no handle on it.

Writes the PNG and prints its path. On failure it says why on stderr and writes nothing: a report that
admits it has no frame is honest, a placeholder is not.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
# The websocket client, Chrome discovery and the port dance are already written and tested; importing
# them keeps one implementation of the protocol rather than a second one that drifts.
import importlib.util as _ilu

_spec = _ilu.spec_from_file_location(
    "ns_web_video", os.path.join(os.path.dirname(os.path.realpath(__file__)), "web-video.py"))
_wv = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_wv)
WS, find_chrome, free_port, page_socket, die = _wv.WS, _wv.find_chrome, _wv.free_port, _wv.page_socket, _wv.die


def main():
    args = sys.argv[1:]
    full = "--full" in args
    if full:
        args.remove("--full")
    wait = 2.5
    if "--wait" in args:
        i = args.index("--wait")
        wait = float(args[i + 1]) if i + 1 < len(args) else wait
        del args[i:i + 2]
    if len(args) < 2:
        die("usage: web-shot.py <url> <out.png> [width] [height] [--full] [--wait s]", 2)
    url, out = args[0], args[1]
    width = int(args[2]) if len(args) > 2 else 1440
    height = int(args[3]) if len(args) > 3 else 900

    chrome = find_chrome()
    if not chrome:
        die("no Chrome or Chromium found", 3)

    port = free_port()
    profile = out + ".profile"
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
            die("Chrome never exposed a page", 4)
        ws = WS(target)
        msg_id = 0

        def call(method, params=None):
            nonlocal msg_id
            msg_id += 1
            ws.send({"id": msg_id, "method": method, "params": params or {}})
            return msg_id

        def result(want, timeout=25):
            end = time.time() + timeout
            while time.time() < end:
                msg = ws.recv()
                if msg and msg.get("id") == want:
                    return msg
            return None

        call("Page.enable")
        # The viewport, told to Chrome rather than merely asked for with a window size. On macOS
        # a Chrome window will not go narrower than about 500px, so `--window-size=390,844`
        # silently produced a 500px shot — and a page checked for phone width at 500px is a page
        # nobody checked. An explicit override has no such floor.
        call("Emulation.setDeviceMetricsOverride",
             {"width": width, "height": height, "deviceScaleFactor": 1,
              "mobile": width < 600})
        # Give the page its own moment: fonts, first paint, whatever it fetches. A screenshot taken
        # at load is a screenshot of a skeleton.
        time.sleep(max(0.2, wait))
        params = {"format": "png", "captureBeyondViewport": bool(full)}
        if full:
            metrics = result(call("Page.getLayoutMetrics"))
            size = ((metrics or {}).get("result") or {}).get("cssContentSize") or {}
            if size.get("height"):
                params["clip"] = {"x": 0, "y": 0, "width": size.get("width", width),
                                  "height": size["height"], "scale": 1}
        shot = result(call("Page.captureScreenshot", params))
        data = ((shot or {}).get("result") or {}).get("data")
        if not data:
            die("Chrome returned no image", 5)
        with open(out, "wb") as fh:
            fh.write(base64.b64decode(data))
        print(os.path.abspath(out))
    finally:
        if ws:
            try:
                ws.close()
            except Exception:
                pass
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    main()
