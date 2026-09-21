#!/usr/bin/env python3
"""Both languages are complete, and each one can get to the other.

    check-languages.py <en.html> <uk.html>

A language switch is easy to ship half-working: the navigation translates and the diagram labels
do not, or the switch on one page points at a route nobody published. The interesting failures are
all of the "looks fine in the language you happen to read" kind, so this asks the questions that
do not depend on knowing either language.

Exit code is the number of problems.
"""

import html.parser
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STRINGS = os.path.join(ROOT, "site", "strings.json")


class Head(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.lang = None
        self.links = []
        self.alternates = {}
        self.canonical = None
        self.ids = set()
        self.fragments = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        href = a.get("href") or ""
        if tag == "a" and href.startswith("#") and len(href) > 1:
            self.fragments.append(href[1:])
        if tag == "html":
            self.lang = a.get("lang")
        if tag == "link" and a.get("rel") == "canonical":
            self.canonical = a.get("href")
        if tag == "link" and a.get("rel") == "alternate" and a.get("hreflang"):
            self.alternates[a["hreflang"]] = a.get("href")
        if tag == "a" and "lang" in (a.get("class") or "").split():
            self.links.append(a)


def text_of(page):
    body = re.sub(r"<(script|style)\b.*?</\1>", " ", page, flags=re.S | re.I)
    return html.unescape(re.sub(r"<[^>]+>", " ", body))


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: check-languages.py <en.html> <uk.html> [route]", file=sys.stderr)
        return 2
    paths = {"en": sys.argv[1], "uk": sys.argv[2]}
    # Which pair is being checked: "" for the landing pages, "pipeline/" for the history ones.
    # The alternates and the switch point at the SAME page in the other language, not at the
    # front page — a switch that silently sends you to the top of the site is the failure the
    # design precedent names.
    route = sys.argv[3].strip("/") + "/" if len(sys.argv) == 4 and sys.argv[3].strip("/") else ""
    strings = json.load(open(STRINGS, encoding="utf-8"))
    problems = []
    pages, texts = {}, {}

    for code, path in paths.items():
        page = open(path, encoding="utf-8").read()
        head = Head()
        head.feed(page)
        pages[code] = head
        texts[code] = text_of(page)

        if head.lang != code:
            problems.append(f"{code}: <html lang> is {head.lang!r}")
        want_en = f"https://bulava.app/{route}"
        want_uk = f"https://bulava.app/uk/{route}"
        if head.alternates.get("en") != want_en:
            problems.append(f"{code}: the English alternate is {head.alternates.get('en')!r}, not {want_en!r}")
        if head.alternates.get("uk") != want_uk:
            problems.append(f"{code}: the Ukrainian alternate is {head.alternates.get('uk')!r}, not {want_uk!r}")
        if head.alternates.get("x-default") != want_en:
            problems.append(f"{code}: x-default does not point at the English version of this page")
        if len(head.links) != 1:
            problems.append(f"{code}: found {len(head.links)} language switches, expected exactly one")
        else:
            link = head.links[0]
            other = "uk" if code == "en" else "en"
            want = f"/uk/{route}" if other == "uk" else f"/{route}"
            if link.get("href") != want:
                problems.append(f"{code}: the switch points at {link.get('href')!r}, not {want!r}")
            if link.get("hreflang") != other or link.get("lang") != other:
                problems.append(f"{code}: the switch does not declare the language it leads to")

    # Only the strings this pair of pages actually shows. The history page carries a third of the
    # table, and demanding all of it here would report the landing page's prose as untranslated.
    # The substance, not just the chrome. Every sentence in the other language's table should be
    # absent from this page — if a key was left untranslated, the same string appears on both.
    # The switch's whole job is to say "English" on the Ukrainian page, so it is not a leak.
    EXPECTED_ON_BOTH = {"site.language.name"}
    shared = []
    for key, english in strings["en"].items():
        ukrainian = strings["uk"][key]
        if english == ukrainian or key in EXPECTED_ON_BOTH:
            continue                       # legitimately identical: night-shift, Telegram, tmux…
        # A one- or two-letter string is a substring of half the page. "h" for hours matched the
        # h in "Claude"; checking it proves nothing and fails everything.
        if len(english) < 5:
            continue
        if english not in texts["en"]:
            continue                       # not on this page at all
        if english in texts["uk"]:
            shared.append(key)
    if shared:
        problems.append("these are still in English on the Ukrainian page: " + ", ".join(sorted(shared)))

    # Every in-page link lands somewhere. The evidence links under each benchmark run point at
    # the methodology for that run, and a link into a section that does not exist is the quietest
    # way to publish a claim with nothing behind it.
    for code, head in pages.items():
        for fragment in sorted(set(head.fragments)):
            if fragment not in head.ids:
                problems.append(f"{code}: #{fragment} is linked and there is nothing with that id")

    # Asset URLs must be root-relative. A relative one works perfectly at / and asks the server
    # for /uk/assets/… on the other page — and every asset check we have prepends the origin
    # itself, so all of them would pass while the Ukrainian page showed broken images.
    for code, path in paths.items():
        page = open(path, encoding="utf-8").read()
        for bad in re.findall(r'(?:src|href)="(assets/[^"]+)"', page):
            problems.append(f"{code}: {bad} is relative; on /uk/ it resolves to /uk/{bad}")
        for bad in re.findall(r'url\("(assets/[^"]+)"\)', page):
            problems.append(f"{code}: url({bad}) is relative; on /uk/ it resolves to /uk/{bad}")

    # And the diagrams, whose labels live outside the template and are the thing most often left
    # behind when a page is translated. Sampled per route, because each page carries its own.
    samples = {"": ("dg.t.msg.t", "dg.t.context.t", "dg.t.loop"),
               "pipeline/": ("dg.c.task.t", "dg.1.plan.t", "dg.2.align.t")}
    for key in samples.get(route, ()):
        for code in ("en", "uk"):
            if strings[code][key] not in texts[code]:
                problems.append(f"the {code} diagram on this page is missing {key}")

    for p in problems:
        print(p)
    if not problems:
        print("two complete pages, each declaring and reaching the other")
    return len(problems)


if __name__ == "__main__":
    sys.exit(main())
