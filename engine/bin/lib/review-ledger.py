#!/usr/bin/env python3
"""The list of open defects a review team handed back, kept with stable ids across fix rounds.

  review-ledger.py init  <ledger> <review-file> [<snapshot-json>]  the team's blocking findings → T1..Tn
  review-ledger.py apply <ledger> <review-file> [<snapshot-json>]  one fix-check answer; prints JSON
  review-ledger.py open  <ledger>                                   the open items, one per line
  review-ledger.py count <ledger>                                   how many are open
  review-ledger.py merge <ledger> <answer-file>                     "T3: SAME AS T1" lines → merged
Exit 3 when the ledger cannot be read or written: the caller must not pass on it.

Why a ledger and not the last round's list. Progress used to be "fewer [repeat]s than the last
round's numbered lines", and the last round's lines were whatever the reviewer printed: the team's
three lists one under another, so one defect described by two members counted twice, and a single
[repeat] for it read as progress. A defect the next reviewer did not mention fell off the list.

Here every blocking defect has an id from the moment it is found. A fix-check answer reports each
open id as FIXED or OPEN; an id it does not mention stays open. Progress is an id closed — two ids
for one defect close together or not at all, so duplicates cannot fake it. New blocking defects the
answer lists (numbered, as before) join as N1, N2, ...

One defect the team described twice gets two ids at first. Right after the team a short duplicate
check names them ("T2: SAME AS T1"), and a fix check may too; from then on T2 follows T1: it is not
counted on its own, and the defect closes once. Statuses that disagree for one id (FIXED and OPEN
both), or an OPEN said of any description of a defect, read as OPEN. [scope_violation]
is never a ledger item: the gate quarantines it on its own path.

The ledger file is JSON: {"items":[{"id","text","open","same_as"?}], "stall":n, "rounds":n,
"repos":[{"path","reviewed_sha"}]} — the commits of the last review, for the next one's diff.
"""
import json
import os
import re
import sys

NUMBERED = re.compile(r"^\s*[0-9]+[.)]\s*(.*)$")
BLOCKING_TAG = re.compile(r"\[(acceptance_failure|regression_from_patch)\]")
ADVISORY = re.compile(r"\[(related_improvement|pre_existing|harness_failure|scope_violation)\]")
# "T1: FIXED" and nothing after it but a full stop; "T1: OPEN — why"; "T2: SAME AS T1". Anything
# else ("FIXED?", "FIXED or OPEN", "fixed, probably") is no status, and the id stays as it was.
STATUS = re.compile(r"^\s*[-*•]?\s*\**([TN][0-9]+)\**\s*[:—–-]\s*\**"
                    r"(?:(FIXED)\**\s*\.?\s*$|(OPEN)\**(?=\s*$|\s*[—–:-]|\s+[^?\s])|SAME AS\s+([TN][0-9]+)\**\s*\.?\s*$)")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


class Unreadable(Exception):
    pass


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError) as e:
        raise Unreadable(str(e))
    if not (isinstance(d, dict) and isinstance(d.get("items"), list)):
        raise Unreadable("not a ledger")
    return d


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
    """id → FIXED | OPEN | ("SAME", other id). Disagreeing lines for one id read as OPEN."""
    st = {}
    for ln in text.splitlines():
        m = STATUS.match(ln)
        if not m:
            continue
        i = m.group(1).upper()
        v = ("SAME", m.group(4).upper()) if m.group(4) else ("FIXED" if m.group(2) else "OPEN")
        if i in st and st[i] != v:
            v = "OPEN"
        st[i] = v
    return st


def by_id(items, i):
    return next(it for it in items if it["id"] == i)


def canonical(items, i):
    seen = set()
    by = {it["id"]: it for it in items}
    while i in by and by[i].get("same_as") and i not in seen:
        seen.add(i)
        i = by[i]["same_as"]
    return i


def snapshot(arg):
    try:
        v = json.loads(arg) if arg else []
        return v if isinstance(v, list) else []
    except ValueError:
        return []


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    try:
        return run(cmd, path)
    except (Unreadable, OSError) as e:
        sys.stderr.write("ledger %s: %s\n" % (path, e))
        return 3


def run(cmd, path):
    if cmd == "init":
        text = read(sys.argv[3])
        items = [{"id": "T%d" % (i + 1), "text": t, "open": True} for i, t in enumerate(blocking(text))]
        save(path, {"items": items, "stall": 0, "rounds": 0,
                    "repos": snapshot(sys.argv[4] if len(sys.argv) > 4 else "")})
        print(len(items))
        return 0
    d = load(path)
    counted = [it for it in d["items"] if not it.get("same_as")]
    if cmd == "open":
        for it in counted:
            if it["open"]:
                print("%s: %s" % (it["id"], it["text"]))
        return 0
    if cmd == "count":
        print(sum(1 for it in counted if it["open"]))
        return 0
    if cmd == "repos":
        print(json.dumps(d.get("repos") or []))
        return 0
    if cmd == "merge":
        # The duplicate check right after the team: "T3: SAME AS T1" lines only, nothing else moves.
        st = statuses(read(sys.argv[3]))
        ids = {it["id"] for it in d["items"]}
        merged = []
        for it in d["items"]:
            v = st.get(it["id"])
            if isinstance(v, tuple) and v[1] in ids and canonical(d["items"], v[1]) != it["id"] \
               and (by_id(d["items"], canonical(d["items"], v[1]))["open"] or not it["open"]):
                it["same_as"] = canonical(d["items"], v[1])
                it["open"] = False
                merged.append("%s=%s" % (it["id"], it["same_as"]))
        save(path, d)
        print(" ".join(merged))
        return 0
    if cmd == "apply":
        text = read(sys.argv[3])
        st = statuses(text)
        ids = {it["id"] for it in d["items"]}
        # Duplicates first: T2 SAME AS T1 makes T2 follow T1 from now on.
        for it in d["items"]:
            v = st.get(it["id"])
            # Only onto a defect still open: "SAME AS" a closed one would close this one unfixed.
            if isinstance(v, tuple) and v[1] in ids and canonical(d["items"], v[1]) != it["id"] \
               and (by_id(d["items"], canonical(d["items"], v[1]))["open"] or not it["open"]):
                it["same_as"] = canonical(d["items"], v[1])
                it["open"] = False
        counted = [it for it in d["items"] if not it.get("same_as")]
        was_open = [it for it in counted if it["open"]]
        # A defect is FIXED only when its own id says so and no description of it says OPEN.
        said_open = {canonical(d["items"], i) for i, v in st.items() if v == "OPEN"}
        closed = []
        for it in was_open:
            if st.get(it["id"]) == "FIXED" and it["id"] not in said_open:
                it["open"] = False
                closed.append(it["id"])
        n = sum(1 for it in d["items"] if it["id"].startswith("N"))
        added = []
        for t in blocking(text):
            # A fix check adds a defect only when it says it is one: "1. Ran the project tests." is
            # a sentence, not a blocker.
            if re.match(r"^\**[TN][0-9]+\**\s*[:—–-]", t) or not BLOCKING_TAG.search(t):
                continue
            n += 1
            d["items"].append({"id": "N%d" % n, "text": t, "open": True})
            added.append("N%d" % n)
        if was_open:
            d["stall"] = 0 if closed else int(d.get("stall", 0)) + 1
        d["rounds"] = int(d.get("rounds", 0)) + 1
        snap = snapshot(sys.argv[4] if len(sys.argv) > 4 else "")
        if snap:
            d["repos"] = snap
        save(path, d)
        print(json.dumps({"was_open": len(was_open), "closed": closed, "added": added,
                          "open": [it["id"] for it in d["items"] if it["open"] and not it.get("same_as")],
                          "stall": d["stall"]}))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
