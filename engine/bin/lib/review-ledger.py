#!/usr/bin/env python3
"""The list of open defects a review team handed back, kept with stable ids across fix rounds.

  review-ledger.py init  <ledger> <review-file> [<sha>]   the team's blocking findings → T1..Tn
  review-ledger.py apply <ledger> <review-file> [<sha>]   one fix-check answer → closes / adds; prints JSON
  review-ledger.py open  <ledger>                          the open items, one per line, for the prompt
  review-ledger.py unconfirmed <ledger> <review-file>      open ids the answer did not report FIXED

Why a ledger and not the last round's list. Progress used to be "fewer [repeat]s than the last
round's numbered lines", and the last round's lines were whatever the reviewer printed: the team's
three lists one under another, so one defect described by two members counted twice, and a single
[repeat] for it read as progress. A defect the next reviewer did not mention fell off the list.

Here every blocking defect has an id from the moment it is found. A fix-check answer reports each
open id as FIXED or OPEN; an id it does not mention stays open. Progress is an id closed — two ids
for one defect close together or not at all, so duplicates cannot fake it. New blocking defects the
answer lists (numbered, as before) join as N1, N2, ...

The ledger file is JSON: {"items":[{"id","text","open"}], "stall":n, "rounds":n, "sha":"<commit>"}.
"""
import json
import os
import re
import sys

NUMBERED = re.compile(r"^\s*[0-9]+[.)]\s*(.*)$")
ADVISORY = re.compile(r"\[(related_improvement|pre_existing|harness_failure)\]")
STATUS = re.compile(r"^\s*[-*•]?\s*\**([TN][0-9]+)\**\s*[:—–-]\s*\**(FIXED|OPEN)\b", re.I)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        if isinstance(d, dict) and isinstance(d.get("items"), list):
            return d
    except (OSError, ValueError):
        pass
    return {"items": [], "stall": 0, "rounds": 0, "sha": ""}


def save(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, ensure_ascii=False)
    os.replace(tmp, path)


def blocking(text):
    out = []
    for ln in text.splitlines():
        m = NUMBERED.match(ln)
        if m and not ADVISORY.search(ln):
            body = re.sub(r"\s*\[repeat\]", "", m.group(1)).strip()
            if body:
                out.append(body)
    return out


def statuses(text):
    st = {}
    for ln in text.splitlines():
        m = STATUS.match(ln)
        if m:
            st[m.group(1).upper()] = m.group(2).upper()
    return st


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "init":
        text = read(sys.argv[3])
        items = [{"id": "T%d" % (i + 1), "text": t, "open": True} for i, t in enumerate(blocking(text))]
        save(path, {"items": items, "stall": 0, "rounds": 0, "sha": sys.argv[4] if len(sys.argv) > 4 else ""})
        print(len(items))
        return 0
    d = load(path)
    if cmd == "open":
        for it in d["items"]:
            if it["open"]:
                print("%s: %s" % (it["id"], it["text"]))
        return 0
    text = read(sys.argv[3])
    st = statuses(text)
    if cmd == "unconfirmed":
        print(" ".join(it["id"] for it in d["items"] if it["open"] and st.get(it["id"]) != "FIXED"))
        return 0
    if cmd == "apply":
        was_open = [it for it in d["items"] if it["open"]]
        closed = []
        for it in was_open:
            if st.get(it["id"]) == "FIXED":
                it["open"] = False
                closed.append(it["id"])
        # New blocking defects: the numbered lines. An answer that numbered its status lines too
        # ("1. T2: OPEN …") is not adding a defect.
        n = sum(1 for it in d["items"] if it["id"].startswith("N"))
        added = []
        for t in blocking(text):
            if re.match(r"^\**[TN][0-9]+\**\s*[:—–-]", t):
                continue
            n += 1
            d["items"].append({"id": "N%d" % n, "text": t, "open": True})
            added.append("N%d" % n)
        # No progress: there was something open and nothing of it closed.
        if was_open:
            d["stall"] = 0 if closed else int(d.get("stall", 0)) + 1
        d["rounds"] = int(d.get("rounds", 0)) + 1
        if len(sys.argv) > 4 and sys.argv[4]:
            d["sha"] = sys.argv[4]
        save(path, d)
        print(json.dumps({"was_open": len(was_open), "closed": closed, "added": added,
                          "open": [it["id"] for it in d["items"] if it["open"]], "stall": d["stall"]}))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
