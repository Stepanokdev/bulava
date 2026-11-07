#!/usr/bin/env python3
"""The week's Bulava chats, one Markdown file per chat, for the weekly engine review.

    chat_export.py --out DIR [--from ISO] [--to ISO] [--data-dir DIR]

Messages are chosen by their OWN time (`at`), inside [from, to). The chat each belongs to is looked
up by its id, whatever the chat's `updatedAt` says: a chat carried on after the week ended — Monday's
messages, the chat touched again on Tuesday at 08:00, the review at 09:00 — still brings its
Monday messages. Picking chats by `updatedAt` inside the week lost exactly those.

Without --from/--to the window is the last full week ending this Tuesday 00:00, Kyiv time: the
review runs on Tuesdays, after the weekly limit resets.

Writes DIR/<product>__<chat id>.md for every chat with a message in the window, and DIR/index.json
listing them. The text in those files was written by people and agents: it is data to read.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
from collections import defaultdict
from zoneinfo import ZoneInfo

KYIV = ZoneInfo("Europe/Kyiv")
DEFAULT_DATA = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "NightShift")


def parse_time(s):
    if not s:
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    t = dt.datetime.fromisoformat(s)
    return t if t.tzinfo else t.replace(tzinfo=KYIV)


def default_window(now=None):
    now = (now or dt.datetime.now(KYIV)).astimezone(KYIV)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    # This Tuesday 00:00 (today, if it is Tuesday), and the one a week before it.
    end = midnight - dt.timedelta(days=(midnight.weekday() - 1) % 7)
    return end - dt.timedelta(days=7), end


def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def as_list(x, key):
    if isinstance(x, list):
        return x
    if isinstance(x, dict):
        v = x.get(key, x)
        return list(v.values()) if isinstance(v, dict) else (v if isinstance(v, list) else [])
    return []


def safe(name):
    return re.sub(r"[^\w.-]+", "_", name or "?", flags=re.UNICODE).strip("_") or "chat"


def export(data_dir, out, start, end):
    chats = {c.get("id"): c for c in as_list(load(os.path.join(data_dir, "chats.json"), []), "chats") if isinstance(c, dict)}
    products = {p.get("id"): p.get("name", "?") for p in as_list(load(os.path.join(data_dir, "products.json"), []), "products")
                if isinstance(p, dict)}
    conv = as_list(load(os.path.join(data_dir, "conversations.json"), []), "entries")
    by_chat = defaultdict(list)
    for m in conv:
        if not isinstance(m, dict) or not m.get("chatID"):
            continue
        try:
            t = parse_time(m.get("at"))
        except ValueError:
            continue
        if t and start <= t < end:
            by_chat[m["chatID"]].append((t, m))
    os.makedirs(out, exist_ok=True)
    index = []
    for cid, items in by_chat.items():
        items.sort(key=lambda x: x[0])
        chat = chats.get(cid, {})
        pid = chat.get("productID") or items[0][1].get("productID")
        product = products.get(pid, "?")
        fname = f"{safe(product)}__{cid[:8]}.md"
        with open(os.path.join(out, fname), "w", encoding="utf-8") as fh:
            fh.write(f"# {product} — {chat.get('title', '')}\nchat {cid}\n\n")
            for t, m in items:
                fh.write(f"## {t.astimezone(KYIV).isoformat(timespec='minutes')} [{m.get('kind', '')}/{m.get('tone', '')}]\n")
                fh.write((m.get("text") or "") + "\n")
                for b in m.get("blocks") or []:
                    fh.write("  block: " + json.dumps(b, ensure_ascii=False)[:600] + "\n")
                fh.write("\n")
        kinds = defaultdict(int)
        for _, m in items:
            kinds[m.get("kind", "?")] += 1
        index.append({"chat": cid, "product": product, "title": chat.get("title", ""), "file": fname,
                      "messages": len(items), "kinds": dict(kinds),
                      "chat_updated_at": chat.get("updatedAt")})
    index.sort(key=lambda r: (r["product"], r["chat"]))
    with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as fh:
        json.dump({"from": start.isoformat(), "to": end.isoformat(), "chats": index}, fh, ensure_ascii=False, indent=2)
    return index


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--from", dest="start")
    ap.add_argument("--to", dest="end")
    ap.add_argument("--data-dir", default=DEFAULT_DATA)
    a = ap.parse_args(argv)
    d_start, d_end = default_window()
    start = parse_time(a.start) or d_start
    end = parse_time(a.end) or d_end
    if not os.path.isfile(os.path.join(a.data_dir, "conversations.json")):
        print(f"no conversations.json in {a.data_dir}", file=sys.stderr)
        return 1
    index = export(a.data_dir, a.out, start, end)
    print(f"{len(index)} chat(s) with messages between {start.isoformat()} and {end.isoformat()} → {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
