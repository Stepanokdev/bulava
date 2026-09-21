#!/usr/bin/env python3
"""Serve the site locally, re-rendering whenever a source file has changed.

    preview-server.py <version> <bytes-or-dmg> <min-macos> <port> <out-dir>

`site/preview.sh` used to render once and then hand the directory to `python3 -m http.server`.
That is fine for a look and wrong for an afternoon: the server outlives the render, so every
later edit is invisible and the page in the browser keeps saying what it said hours ago. It cost
a whole revision — the director was reading a page rendered before the work he was asking about,
and the only sign was the clock on a process nobody had reason to look at.

So the render now happens on the way to the browser. Every request checks the mtimes of the
sources; when one has moved, the page and its pictures are rebuilt before the file is served. A
refresh is the whole workflow, and nothing has to be restarted to see the current work.
"""
import hashlib
import http.server
import os
import shutil
import socketserver
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# Everything the pages are made of. Missing entries are not an error — `field-dark.webp` was
# deleted once and a hard-coded list would have stopped the preview dead over a picture the page
# no longer uses.
SOURCES = [
    "index.template.html", "pipeline.template.html", "strings.json", "benchmark.json",
    "render.py", "diagram.py", "method.py", "install.sh",
]


def signature():
    """What the render depends on, as one string: a change here means a stale page."""
    parts = []
    for name in SOURCES:
        path = os.path.join(HERE, name)
        try:
            parts.append(f"{name}:{os.stat(path).st_mtime_ns}")
        except FileNotFoundError:
            parts.append(f"{name}:-")
    assets = os.path.join(HERE, "assets")
    for root, _dirs, files in os.walk(assets):
        if os.path.basename(root) == "src":          # 2.5 MB PNGs the page never serves
            continue
        for name in sorted(files):
            path = os.path.join(root, name)
            try:
                parts.append(f"{os.path.relpath(path, assets)}:{os.stat(path).st_mtime_ns}")
            except FileNotFoundError:
                continue
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()


class Preview:
    def __init__(self, version, size, minos, out_dir):
        self.version, self.size, self.minos, self.out = version, size, minos, out_dir
        self.stamp = None
        self.built_at = None

    def ensure_fresh(self):
        """Re-render if a source moved. Cheap when nothing did: thirty stat calls."""
        now = signature()
        if now == self.stamp:
            return
        started = time.time()
        env = dict(os.environ)
        run = subprocess.run(
            [sys.executable, os.path.join(HERE, "render.py"),
             self.version, self.size, self.out, self.minos],
            capture_output=True, text=True, env=env)
        if run.returncode != 0:
            # Kept serving the previous render on purpose: a broken template should show up as a
            # message here, not as a blank page with no explanation in the browser.
            sys.stderr.write("preview: рендер відмовився — сторінка лишається попередньою\n"
                             + (run.stdout or "") + (run.stderr or ""))
            self.stamp = now
            return
        manifest = os.path.join(self.out, "index.html.assets")
        published = 0
        with open(manifest, encoding="utf-8") as fh:
            for line in fh:
                pub, src, _digest = line.rstrip("\n").split("\t")
                dest = os.path.join(self.out, pub)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if not os.path.exists(dest) or os.stat(dest).st_mtime_ns < os.stat(src).st_mtime_ns:
                    shutil.copyfile(src, dest)
                published += 1
        for extra in ("install.sh", "benchmark.json"):
            shutil.copyfile(os.path.join(HERE, extra), os.path.join(self.out, extra))
        self.stamp = now
        self.built_at = time.strftime("%H:%M:%S")
        print(f"  ↻ {self.built_at} перерендерено за {time.time() - started:.1f}s "
              f"· {published} файл(ів) поруч · {(run.stdout or '').strip()}", flush=True)


def main():
    if len(sys.argv) != 6:
        sys.exit("usage: preview-server.py <version> <bytes|dmg> <min-macos> <port> <out-dir>")
    version, size, minos, port, out_dir = sys.argv[1:6]
    os.makedirs(out_dir, exist_ok=True)
    preview = Preview(version, size, minos, out_dir)
    preview.ensure_fresh()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=out_dir, **kw)

        def do_GET(self):
            preview.ensure_fresh()
            super().do_GET()

        def do_HEAD(self):
            preview.ensure_fresh()
            super().do_HEAD()

        def end_headers(self):
            # A preview that a browser is allowed to cache is the same trap one layer down.
            self.send_header("Cache-Control", "no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            super().end_headers()

        def log_message(self, fmt, *args):
            if "200" not in (args[1] if len(args) > 1 else ""):
                super().log_message(fmt, *args)

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", int(port)), Handler) as httpd:
        print(f"прев'ю: pid {os.getpid()} · {out_dir} · зібрано {preview.built_at} "
              f"· версія {version} · перерендерює себе на кожен запит", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
