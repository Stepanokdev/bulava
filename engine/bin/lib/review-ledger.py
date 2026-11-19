#!/usr/bin/env python3
"""The list of open defects a review team handed back, kept with stable ids across fix rounds.

  review-ledger.py init  <ledger> <review-file> [<snapshot-json>]  the team's blocking findings → T1..Tn
  review-ledger.py apply <ledger> <review-file> [<snapshot-json>]  one fix-check answer; prints JSON
  review-ledger.py open  <ledger>                                   the open items, one per line
  review-ledger.py count <ledger>                                   how many are open
  review-ledger.py grouped <ledger>                                 1 once duplicates were checked, else 0
Exit 3 when the ledger cannot be read or written: the caller must not pass on it.

Why a ledger and not the last round's list. Progress used to be "fewer [repeat]s than the last
round's numbered lines", and the last round's lines were whatever the reviewer printed: the team's
three lists one under another, so one defect described by two members counted twice, and a single
[repeat] for it read as progress. A defect the next reviewer did not mention fell off the list.

Here every blocking defect has an id from the moment it is found. A fix-check answer reports each
open id as FIXED or OPEN; an id it does not mention stays open. Progress is an id closed — two ids
for one defect close together or not at all, so duplicates cannot fake it. New blocking defects the
answer lists (numbered, as before) join as N1, N2, ...

One defect the team described twice gets two ids at first. The first fix check is asked to name
them ("T2: SAME AS T1" lines and "DUPLICATES: NAMED", or "DUPLICATES: NONE"); from then on T2
follows T1: it is not counted on its own, and the defect closes once. Until an answer has done that
("grouped") nothing closes and the stall counts on: "T1: FIXED" with "T2: OPEN" may be one defect
still open, and the next fix check sees both descriptions again. A SAME AS onto an unknown or a
closed id groups nothing. Statuses that disagree for one id (FIXED and OPEN
both), or an OPEN said of any description of a defect, read as OPEN. [scope_violation]
is never a ledger item: the gate quarantines it on its own path.

The ledger file is JSON: {"items":[{"id","text","open","same_as"?}], "stall":n, "rounds":n, "grouped":bool,
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
# The answer's own statement that it grouped the list: NONE (every id a different defect) or NAMED
# (the pairs are the SAME AS lines it gave).
DUPLICATES = re.compile(r"^\s*\**DUPLICATES:\**\s*\**(NONE|NAMED)\**\s*\.?\s*$", re.M | re.I)
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
        save(path, {"items": items, "stall": 0, "rounds": 0, "grouped": len(items) <= 1,
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
    if cmd == "grouped":
        print(1 if d.get("grouped", True) else 0)
        return 0
    if cmd == "apply":
        text = read(sys.argv[3])
        st = statuses(text)
        ids = {it["id"] for it in d["items"]}
        def merge_ok(it, v):
            # Only onto a known defect still open: "SAME AS" a closed one would close this one unfixed.
            return isinstance(v, tuple) and v[1] in ids and canonical(d["items"], v[1]) != it["id"] \
                and (by_id(d["items"], canonical(d["items"], v[1]))["open"] or not it["open"])
        # Grouping. Until one answer has said which ids are one defect, nothing on the list closes:
        # "T1: FIXED" with "T2: OPEN" may be one defect still open, and the reviewer has to see both
        # descriptions again to say so. An answer groups the list when it declares it did
        # (DUPLICATES: NONE / NAMED) and every SAME AS it gave holds; one that points at an unknown or
        # a closed id groups nothing. A ledger written before this field existed counts as grouped.
        grouped_before = bool(d.get("grouped", True))
        sames = [(it, st.get(it["id"])) for it in d["items"] if isinstance(st.get(it["id"]), tuple)]
        decl = DUPLICATES.search(text)
        grouped_now = grouped_before or (bool(decl) and all(merge_ok(it, v) for it, v in sames))
        # Duplicates first: T2 SAME AS T1 makes T2 follow T1 from now on.
        if grouped_now:
            for it, v in sames:
                if merge_ok(it, v):
                    it["same_as"] = canonical(d["items"], v[1])
                    it["open"] = False
        counted = [it for it in d["items"] if not it.get("same_as")]
        was_open = [it for it in counted if it["open"]]
        # A defect is FIXED only when its own id says so and no description of it says OPEN.
        said_open = {canonical(d["items"], i) for i, v in st.items() if v == "OPEN"}
        closed = []
        for it in was_open:
            if grouped_now and st.get(it["id"]) == "FIXED" and it["id"] not in said_open:
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
        d["grouped"] = grouped_now
        d["rounds"] = int(d.get("rounds", 0)) + 1
        snap = snapshot(sys.argv[4] if len(sys.argv) > 4 else "")
        if snap:
            d["repos"] = snap
        save(path, d)
        print(json.dumps({"was_open": len(was_open), "closed": closed, "added": added,
                          "open": [it["id"] for it in d["items"] if it["open"] and not it.get("same_as")],
                          "stall": d["stall"], "grouped": grouped_now}))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
