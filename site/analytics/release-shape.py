#!/usr/bin/env python3
"""Assert the shape release.sh must keep, by reading its functions rather than its line numbers.

Two contracts live here.

The first is the prepare/publish split: preparing a release must not be able to upload anything,
or a rehearsal goes live and nobody finds out. This used to be checked as "no upload appears
before do_publish", which broke the day the upload helper was lifted out to be shared with the
page-only mode — the helper is DEFINED above do_publish and CALLED from inside it, and a check
reading line numbers cannot tell those two apart. So this reads do_stage's own body.

The second is the order of an upload. The page now ships pictures, and a page uploaded before the
files it points at is a live page of broken images — with every existing check still green,
because none of them ever asked for a picture.
"""

import re
import sys

SRC = "scripts/release.sh"


def body(lines, name):
    start = next((i for i, l in enumerate(lines) if l.startswith(name + "() {")), None)
    if start is None:
        return None
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > start:
            return lines[start:i + 1]
    return lines[start:]


def main():
    lines = open(SRC, encoding="utf-8").read().splitlines()
    problems = []

    for fn in ("do_stage", "do_publish", "do_site"):
        if body(lines, fn) is None:
            problems.append(f"release.sh has no {fn}()")
    if problems:
        print("\n".join(problems))
        return 1

    publishing = re.compile(r'\$\{SCP\[@\]\}|upload_atomic |upload_page_assets |do_publish|do_site')
    for n, line in enumerate(body(lines, "do_stage"), 1):
        if publishing.search(line):
            problems.append(f"do_stage line {n} can publish: {line.strip()[:70]}")

    for fn in ("do_publish", "do_site"):
        b = body(lines, fn)
        assets = next((i for i, l in enumerate(b) if "upload_page_assets " in l), None)
        page = next((i for i, l in enumerate(b)
                     if re.search(r'upload_atomic .*"index\.html"', l)), None)
        if assets is None:
            problems.append(f"{fn} never uploads the page's pictures")
        elif page is None:
            problems.append(f"{fn} never uploads the page")
        elif assets > page:
            problems.append(f"{fn} uploads the page before its pictures")

    print("\n".join(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
