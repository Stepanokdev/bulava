#!/usr/bin/env python3
"""Prove no screenshot on the website carries somebody's real work.

    check-screenshots.py [--verbose]

The captures on bulava.app are of a real application, and the real application on the machine that
builds this site is full of the author's clients. The answer is not to blur them afterwards —
a blur is a promise that the blur was thorough — but to photograph a SECOND, isolated Bulava with
invented products in it (`site/demo/`). This is what turns that arrangement into a check:

  1. The invented cast really is invented. The names in the fixture are compared against the
     folders this engine has actually worked in, read out of the live run state, so the check
     adapts to whoever runs it instead of hard-coding one person's client list into a public
     repository. This is the same self-adapting source `engine/bin/publish-engine.sh` uses.

  2. Every shipped capture is read with Vision and its text is searched for those real names, for
     home paths, and for the author's employer. A frame taken from the wrong window fails here.

Exit code is the number of problems.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSETS = os.path.join(ROOT, "site", "assets")
OCR = os.path.join(ROOT, "site", "analytics", "ocr.swift")
FIXTURE = os.path.join(ROOT, "site", "demo", "fixture.py")

# Our own names are expected everywhere and are not a leak.
OURS = {"bulava", "night-shift", "nightshift", "night shift"}


def normalise(text):
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def real_project_names():
    """The folders this machine's engine has actually run in."""
    state = os.environ.get("SUPERVISOR_STATE_DIR") or os.path.expanduser("~/.claude/supervisor")
    names = set()
    for sub in ("instances", "runs"):
        base = os.path.join(state, sub)
        if not os.path.isdir(base):
            continue
        for entry in os.listdir(base):
            marker = os.path.join(base, entry, "project")
            if not os.path.isfile(marker):
                continue
            try:
                path = open(marker, encoding="utf-8").read().strip()
            except OSError:
                continue
            name = normalise(os.path.basename(path))
            if len(name) >= 5 and name not in OURS:
                names.add(name)
    return names


def fixture_names():
    """The invented products, read out of the fixture rather than typed here twice."""
    source = open(FIXTURE, encoding="utf-8").read()
    names = set()
    for m in re.finditer(r'"name":\s*"([^"]+)"', source):
        names.add(normalise(m.group(1)))
    for m in re.finditer(r'os\.path\.join\(work,\s*"([^"]+)"\)', source):
        names.add(normalise(m.group(1)))
    return {n for n in names if n}


def ocr(paths):
    result = subprocess.run(["swift", OCR] + paths, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        return None
    return result.stdout


def main():
    verbose = "--verbose" in sys.argv
    problems = []

    real = real_project_names()
    invented = fixture_names()

    # 1. the cast is invented
    if not invented:
        problems.append("the fixture names no products — check-screenshots is checking nothing")
    for name in sorted(invented & real):
        problems.append(f"the demo product {name!r} is also a real project on this machine — "
                        "rename it in site/demo/fixture.py")

    # 2. what the pictures actually say
    shots = sorted(os.path.join(ASSETS, f) for f in os.listdir(ASSETS)
                   if f.startswith("shot-") and f.endswith(".png")) if os.path.isdir(ASSETS) else []
    if not shots:
        problems.append("there are no captures in site/assets — the page cannot ship")
    else:
        text = ocr(shots)
        if text is None:
            problems.append("could not read the captures — nothing is proved about them")
        else:
            flat = normalise(text)
            if verbose:
                print(text)
            for name in sorted(real):
                if re.search(r"\b" + re.escape(name) + r"\b", flat):
                    problems.append(f"a capture shows the real project {name!r}")
            for needle, why in (("raccoongang", "the author's employer"),
                                ("users ivanstepanok", "a home directory"),
                                ("presale copilot", "a client project"),
                                ("hr helper", "a client project")):
                if needle in flat:
                    problems.append(f"a capture shows {why} ({needle!r})")

    for p in problems:
        print(p)
    if not problems:
        print(f"{len(shots)} capture(s) read; none of the {len(real)} real project name(s) "
              "on this machine appears in any of them")
    return len(problems)


if __name__ == "__main__":
    sys.exit(main())
