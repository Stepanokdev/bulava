#!/usr/bin/env python3
"""artifact.py — turn a run's report manifest into a self-contained artefact the director can open.

    artifact.py <report dir> <out dir> [--title "…"]

The report manifest (`report.json`) plus the frames beside it become ONE `index.html` in `<out dir>`,
with the assets copied in next to it. No app, no server, no network: double-click and read.

Why this lives in the engine and not in the application. The document was rendered by Bulava, which
means a run from the terminal produced a manifest nobody could read without launching the app, and the
report only existed inside a product the director happened to have open. He asked for the opposite: a
folder in the project, ignored by git, that holds the work and its screenshots — the same artefact
whether the run was started from the app or by hand.

The page answers, in this order: what needs his decision, then one section per thing he asked for —
with its verdict and its own frames under it — then the rest of the account, then any loose evidence.
That order is not decoration: he read a narrative with a gallery at the end and could not find the item
he cared most about.
"""
import html
import json
import os
import re
import shutil
import sys

STATUS_WORDS = {
    "closed": ("Закрито", "closed"), "partial": ("Частково", "partial"),
    "not_closed": ("Не закрито", "notclosed"), "blocked": ("Заблоковано", "blocked"),
    "n/a": ("Не застосовується", "na"), "unknown": ("Без вердикту", "unknown"),
}


def status_of(raw):
    """Read a status the way a worker would write it, in either language, or admit it does not know.

    An unrecognised word must never render as done: a report that upgrades itself is worse than one
    that says nothing.
    """
    s = (raw or "").strip().lower()
    if s in STATUS_WORDS:
        return STATUS_WORDS[s]
    for needle, key in (("частков", "partial"), ("partial", "partial"),
                        ("заблок", "blocked"), ("block", "blocked"),
                        ("не закри", "not_closed"), ("не зробл", "not_closed"), ("not clos", "not_closed"),
                        ("не застос", "n/a"), ("n/a", "n/a"), ("not app", "n/a"),
                        ("закри", "closed"), ("зробл", "closed"), ("done", "closed"), ("clos", "closed")):
        if needle in s:
            return STATUS_WORDS[key]
    return STATUS_WORDS["unknown"]


def esc(s):
    return html.escape(str(s or ""), quote=False)


def inline(escaped):
    """**bold**, `code` and http(s) links, applied to already-escaped text.

    Pairing asks "is there a closing delimiter", not "is the index odd" — the parity version left its
    asterisks on the page, in a report whose subject was asterisks on the page.
    """
    def pairs(text, delim, open_tag, close_tag):
        parts = text.split(delim)
        if len(parts) < 3:
            return text
        out = parts[0]
        for i in range(1, len(parts)):
            if i % 2 == 1 and i < len(parts) - 1:
                out += open_tag + parts[i] + close_tag
            elif i % 2 == 1:
                out += delim + parts[i]
            else:
                out += parts[i]
        return out

    s = pairs(escaped, "`", "<code>", "</code>")
    s = pairs(s, "**", "<strong>", "</strong>")
    return re.sub(r'(https?://[^\s<)"]+)', r'<a href="\1">\1</a>', s)


def prose(text):
    """A small markdown subset: headings, lists that KEEP THEIR NUMBERS, tables, fenced code, quotes."""
    if not (text or "").strip():
        return ""
    out, para, code, table, list_kind = [], [], None, None, None

    def close_para():
        nonlocal para
        if para:
            out.append("<p>" + inline("<br>".join(esc(l) for l in para)) + "</p>")
            para = []

    def close_list():
        nonlocal list_kind
        if list_kind:
            out.append(f"</{list_kind}>")
            list_kind = None

    def close_table():
        nonlocal table
        if table:
            head, *rows = table
            cells = "".join(f"<th>{inline(esc(c))}</th>" for c in head)
            body = "".join("<tr>" + "".join(f"<td>{inline(esc(c))}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f'<table class="doc"><thead><tr>{cells}</tr></thead><tbody>{body}</tbody></table>')
        table = None

    def close_all():
        close_para(); close_list(); close_table()

    for raw in text.replace("\r\n", "\n").split("\n"):
        line = raw.strip()
        if line.startswith("```"):
            if code is not None:
                out.append("<pre><code>" + "\n".join(esc(l) for l in code) + "</code></pre>")
                code = None
            else:
                close_all(); code = []
            continue
        if code is not None:
            code.append(raw); continue
        if not line:
            close_all(); continue
        if line.startswith("|") and line.endswith("|") and len(line) > 2:
            cells = [c.strip() for c in line[1:-1].split("|")]
            if all(c and set(c) <= set("-:") for c in cells):
                continue
            close_para(); close_list()
            table = (table or []) + [cells]
            continue
        close_table()
        if line.startswith("#"):
            hashes = len(line) - len(line.lstrip("#"))
            body = line[hashes:].strip()
            if body:
                close_all()
                level = 2 if hashes <= 2 else min(4, hashes)
                out.append(f"<h{level}>{inline(esc(body))}</h{level}>")
            continue
        if line in ("---", "***", "___"):
            close_all(); out.append("<hr>"); continue
        if line.startswith("> ") or line == ">":
            close_all()
            out.append(f"<blockquote><p>{inline(esc(line[1:].strip()))}</p></blockquote>")
            continue
        if line[:2] in ("- ", "* ", "• "):
            close_para()
            if list_kind != "ul":
                close_list(); out.append("<ul>"); list_kind = "ul"
            out.append(f"<li>{inline(esc(line[2:]))}</li>")
            continue
        m = re.match(r"^(\d{1,3})\.\s(.*)$", line)
        if m:
            close_para()
            if list_kind != "ol":
                close_list(); out.append(f'<ol start="{int(m.group(1))}">'); list_kind = "ol"
            out.append(f"<li>{inline(esc(m.group(2)))}</li>")
            continue
        close_list()
        para.append(line)
    if code:
        out.append("<pre><code>" + "\n".join(esc(l) for l in code) + "</code></pre>")
    close_all()
    return '<div class="prose">' + "".join(out) + "</div>"


def frames(items, present):
    """Before/after figures. A named-but-missing file renders nothing rather than a broken image."""
    out = ""
    for item in items or []:
        before, after = item.get("before"), item.get("after")
        shots = ""
        if before in present:
            shots += ('<div class="shot"><div class="shot-head"><span class="tag">Було</span></div>'
                      f'<img src="{esc(before)}" loading="lazy"></div>')
        if after in present:
            shots += ('<div class="shot after"><div class="shot-head"><span class="tag">Стало</span></div>'
                      f'<img src="{esc(after)}" loading="lazy"></div>')
        if not shots:
            continue
        cap = item.get("caption") or ""
        pair = "pair two" if (before in present and after in present) else "pair one"
        out += (f'<figure class="item"><div class="{pair}">{shots}</div>'
                + (f"<figcaption>{inline(esc(cap))}</figcaption>" if cap else "") + "</figure>")
    return out


def build(report_dir, out_dir, title_fallback=""):
    manifest_path = os.path.join(report_dir, "report.json")
    with open(manifest_path, encoding="utf-8") as fh:
        m = json.load(fh)

    os.makedirs(out_dir, exist_ok=True)
    # Copy every asset the manifest could reference, so the folder stands alone.
    present = set()
    for name in sorted(os.listdir(report_dir)):
        # The manifest itself, anything the app rendered, and our own leftovers stay behind: the
        # artefact is what he reads, not the workshop it was made in.
        if name in ("report.json", "index.html", "report.html", "artifact-path"):
            continue
        if name.startswith(".") or name.endswith((".bak", ".tmp", ".profile")):
            continue
        src = os.path.join(report_dir, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(out_dir, name))
            present.add(name)

    title = (m.get("title") or title_fallback or "Звіт про роботу").strip()
    summary = (m.get("summary") or "").strip()

    attention = [a for a in (m.get("attention") or []) if str(a).strip()]
    attn_html = ""
    if attention:
        rows = "".join(f"<li>{inline(esc(a))}</li>" for a in attention)
        attn_html = f'<div class="attn"><p class="head">Потребує твого рішення</p><ul>{rows}</ul></div>'

    claimed = set()
    answers = ""
    for s in m.get("sections") or []:
        word, cls = status_of(s.get("status"))
        head = ". ".join(x for x in [str(s.get("ref") or "").strip(), (s.get("title") or "").strip()] if x)
        answers += f'<section class="answer {cls}">'
        answers += f'<h2><span class="num">{inline(esc(head))}</span><span class="chip">{esc(word)}</span></h2>'
        answers += prose(s.get("body") or "")
        shots = frames(s.get("items"), present)
        if shots:
            answers += f'<div class="proof">{shots}</div>'
        for item in s.get("items") or []:
            claimed.update(x for x in (item.get("before"), item.get("after")) if x)
        answers += "</section>"
    if answers:
        answers = f'<div class="answers">{answers}</div>'

    body = prose(m.get("body") or "")

    media = ""
    video = m.get("video")
    if video in present:
        poster = f' poster="{esc(m.get("poster"))}"' if m.get("poster") in present else ""
        media += ('<figure class="media"><video controls playsinline preload="metadata"'
                  f'{poster}><source src="{esc(video)}"></video></figure>')
    loose = [i for i in (m.get("items") or [])
             if not ({i.get("before"), i.get("after")} - {None}) <= claimed]
    media += frames(loose, present)

    css_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "supervisor", "artifact.css")
    with open(css_path, encoding="utf-8") as fh:
        css = fh.read()

    page = f"""<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>
{css}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <p class="eyebrow">Робота зроблена · артефакт прогону</p>
    <h1>{esc(title)}</h1>
    {f'<p class="summary">{inline(esc(summary))}</p>' if summary else ''}
  </header>
  {attn_html}
  {answers}
  {body}
  {media}
  {'' if (answers or body or media) else '<p class="empty">Цей прогін не залишив ні тексту звіту, ні кадрів.</p>'}
  <footer>Артефакт зібрано рушієм night-shift. Ця тека ігнорується git.</footer>
</div>
</body>
</html>
"""
    index = os.path.join(out_dir, "index.html")
    with open(index, "w", encoding="utf-8") as fh:
        fh.write(page)
    return index


def main():
    args = [a for a in sys.argv[1:]]
    title = ""
    if "--title" in args:
        i = args.index("--title")
        title = args[i + 1] if i + 1 < len(args) else ""
        del args[i:i + 2]
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        print(build(args[0], args[1], title))
    except FileNotFoundError as exc:
        print(f"❌ немає що збирати: {exc}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"❌ report.json не парситься: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
