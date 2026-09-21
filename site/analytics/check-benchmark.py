#!/usr/bin/env python3
"""The page's benchmark figures are the measured ones, in every language.

    check-benchmark.py <page.html> [<page.html> …]

The complaint that started this was short and correct: the website's benchmark disagreed with the
presentation's. Both were describing the same three runs. They disagreed because each had the
numbers typed into it, and only one of them was updated when the measurement was redone.

So now there is one file, `site/benchmark.json`, copied out of the measurement the presentation
publishes, and the renderer substitutes from it. This proves the substitution actually happened —
that every figure the pages show is present in that file, and that the three result links are the
measured ones rather than an address somebody remembered.

Exit code is the number of problems.
"""

import html.parser
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "site", "benchmark.json")


class Figures(html.parser.HTMLParser):
    """The numbers as the page actually renders them, not as substrings of the whole file.

    Searching the raw HTML for "1.5" was the first attempt and it passed a page whose figure had
    been changed to 9.9 — because a stylesheet a hundred lines up says `line-height:1.55`. A
    number is only a claim where it is displayed, so this collects the displayed ones: the big
    number beside each result, and every cell of the comparison table.

    Scoped by the containers rather than by one class name, because the class holding the figures
    has now been renamed twice and each rename made this check answer "not shown on the page"
    about a page that showed it.
    """

    FIGURE_HOLDERS = {"score", "metrics"}

    def __init__(self):
        super().__init__()
        self.figures = []
        self.links = []
        self._depth = 0
        self._grab = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        classes = (a.get("class") or "").split()
        if self.FIGURE_HOLDERS & set(classes):
            self._depth = max(self._depth, 1)
        elif self._depth:
            self._depth += 1
        if self._depth and tag in ("b", "td"):
            self._grab = []
        # Every anchor, not the ones carrying a particular class: the class that held the result
        # links was renamed during a redesign and this check went on reporting them missing.
        if tag == "a" and a.get("href"):
            self.links.append(a["href"])

    def handle_endtag(self, tag):
        if tag in ("b", "td") and self._grab is not None:
            text = " ".join("".join(self._grab).split())
            if text:
                self.figures.append(text)
            self._grab = None
        if self._depth:
            self._depth -= 1

    def handle_data(self, data):
        if self._grab is not None:
            self._grab.append(data)


def main():
    pages = sys.argv[1:]
    if not pages:
        print("usage: check-benchmark.py <page.html> [<page.html> …]", file=sys.stderr)
        return 2

    data = json.load(open(DATA, encoding="utf-8"))
    problems = []

    for path in pages:
        page = open(path, encoding="utf-8").read()
        name = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
        parser = Figures()
        parser.feed(page)
        # "3.7 h" → "3.7"; the unit is a separate span and is translated.
        # "3.7 h" → "3.7"; "xhigh" → "" (it is a word, not a figure, and the effort row is
        # checked as text). Empty results are dropped rather than reported as a stray number.
        shown = {re.sub(r"[^0-9.≈]", "", f) for f in parser.figures}
        shown.discard("")

        expected = set()
        for scenario in data["scenarios"]:
            expected |= {f"{scenario['hours']:.1f}", f"{scenario['tokens_millions']:.1f}",
                         scenario["outcome_count"].replace(" ", "")}
        for scenario in data["scenarios"]:
            key = scenario["key"]
            for label, value in (("hours", f"{scenario['hours']:.1f}"),
                                 ("tokens", f"{scenario['tokens_millions']:.1f}"),
                                 ("outcome", scenario["outcome_count"].replace(" ", ""))):
                if value not in shown:
                    problems.append(f"{name}: {key} — {label} {value!r} is not shown on the page")
            if scenario["result_url"] not in parser.links:
                problems.append(f"{name}: {key} — the result link {scenario['result_url']} is missing")
        for stray in sorted(shown - expected):
            problems.append(f"{name}: {stray!r} is displayed as a figure and is not in benchmark.json")

        # The qualifications are the other half of an honest number.
        if str(data["cache_read_share_percent"]) + "%" not in page:
            problems.append(f"{name}: the share of tokens that are cache reads is not stated")
        if f"{data['pure_idle_hours']:.1f}" not in page:
            problems.append(f"{name}: the excluded idle time is not stated")

    for p in problems:
        print(p)
    if not problems:
        print(f"{len(pages)} page(s): every figure and link matches site/benchmark.json "
              f"(measured {data['measured_at'][:10]})")
    return len(problems)


if __name__ == "__main__":
    sys.exit(main())
