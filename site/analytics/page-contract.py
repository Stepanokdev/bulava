#!/usr/bin/env python3
"""What must be true of the download page, asked of the page itself.

    page-contract.py <html-file> <expected-version>

The instrumentation used to be checked by counting lines: exactly two of them had to carry
`data-umami-event="download"`. That number was the design of one particular layout, so the first
redesign that added a third button broke a production check without breaking anything in
production — and a check that fails for being out of date is a check people start ignoring.

What actually matters is coverage, in both directions:

  * every link that hands someone the application is instrumented, names the release being
    offered, and says where on the page it was;
  * nothing that is NOT such a link reports a download, or the figures quietly inflate.

Exit code is the number of problems, so a caller can count them.
"""

import html.parser
import re
import sys


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.anchors = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.anchors.append(dict(attrs))


def main():
    if len(sys.argv) != 3:
        print("usage: page-contract.py <html-file> <expected-version>", file=sys.stderr)
        return 2
    path, version = sys.argv[1], sys.argv[2]
    parser = Links()
    parser.feed(open(path, encoding="utf-8").read())

    dmg = f"/Bulava-{version}.dmg"
    problems, places = [], []

    downloads = [a for a in parser.anchors if (a.get("href") or "").endswith(".dmg")]
    instrumented = [a for a in parser.anchors if a.get("data-umami-event") == "download"]

    if len(downloads) < 2:
        problems.append(f"only {len(downloads)} link(s) offer the application — "
                        "a visitor who scrolls past the hero has nothing to press")

    for a in downloads:
        href = a["href"]
        where = a.get("data-umami-event-place") or "?"
        if href != dmg:
            problems.append(f"the {where} link offers {href}, not {dmg}")
        if a.get("data-umami-event") != "download":
            problems.append(f"the {where} link is not instrumented")
        if a.get("data-umami-event-version") != version:
            problems.append(f"the {where} link reports version "
                            f"{a.get('data-umami-event-version')!r}, not {version}")
        if not a.get("data-umami-event-place"):
            problems.append(f"a download link ({href}) does not say where on the page it is")
        else:
            places.append(a["data-umami-event-place"])

    duplicates = {p for p in places if places.count(p) > 1}
    for p in sorted(duplicates):
        problems.append(f"two download links both call themselves {p!r} — "
                        "the figures cannot tell them apart")

    for a in instrumented:
        if not (a.get("href") or "").endswith(".dmg"):
            problems.append(f"something that is not a download reports one: {a.get('href')!r}")

    # The page must still be a page with scripting off. Everything that hides content for the
    # entry animation is scoped under `.js`, a class an inline script adds; if a rule ever hides
    # something unconditionally, a visitor with JavaScript disabled — or a crawler, or a browser
    # that failed to fetch the analytics script — gets a blank page where a download link was.
    source = open(path, encoding="utf-8").read()
    for m in re.finditer(r"(?m)^\s*([^{@}\n][^{\n]*)\{([^}]*)\}", source):
        selector, rules = m.group(1).strip(), m.group(2)
        if "opacity:0" not in rules.replace(" ", ""):
            continue
        if ".js" in selector or "prefers-reduced-motion" in selector:
            continue
        problems.append(f"{selector!r} hides content without JavaScript having to be present")

    for p in problems:
        print(p)
    if not problems:
        print(f"{len(downloads)} download link(s), each naming {version}, "
              f"each in its own place: {', '.join(places)}")
    return len(problems)


if __name__ == "__main__":
    sys.exit(main())
