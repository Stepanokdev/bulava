#!/usr/bin/env python3
"""The list of open defects a review team handed back, kept with stable ids across fix rounds.

  review-ledger.py init  <ledger> <review-file> [<snapshot-json>] [one]
                                                    the blocking findings → T1..Tn; "one" = they come
                                                    from one reviewer's list, already distinct
  review-ledger.py apply <ledger> <review-file> [<snapshot-json>]  one fix-check answer; prints JSON
  review-ledger.py open  <ledger>                                   the open items, one per line
  review-ledger.py count <ledger>                                   how many are open
  review-ledger.py grouped <ledger>                                 1 once duplicates were checked, else 0
  review-ledger.py attempt <ledger> <run id>                        a new attempt of the task: its no-progress
                                                                    count starts again, the open items stay
  review-ledger.py reach <review-file>                              the answer with every blocking item whose
                                                                    REACH is rare re-tagged [related_improvement]
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

REACH. Every blocking item is asked for one: ordinary (a person meets it on the ordinary path of this
task, or a written criterion is plainly unmet), data-loss, or rare. A rare one is advisory whatever its
tag. The proportion rule used to be a sentence in the prompt, and on a server (Nov 2026) the
reviewer kept tagging rare combinations [regression_from_patch]: "a caller that catches AccessError and
continues", "a recordset of another model". Each blocked, the worker wrote one more guard, and the
next round found a rare hole in that. A line the gate can read is something the gate can enforce; an
item with no REACH still blocks, as before.

Progress is the open count going down. It used to be "an id closed", and the same server task closed
one id and gained one [regression_from_patch] round after round (6 → 4 → 2 → 2 open, stall 0 every
time): the fixes were breeding the blockers. Now a round that does not leave fewer open items than it
found is no progress, and "churn" counts the rounds in a row where new blockers came in and the open
count did not fall, so the gate can say why it stopped. Grouping duplicates is not progress: the
count before a round is taken after its SAME AS lines are applied.

[spec_conflict] is not a ledger item either: the reviewer disputes something the task decided in so
many words, and that goes to the task's author as a question (review-gate.sh), never to the worker.

The ledger file is JSON: {"items":[{"id","text","open","same_as"?}], "stall":n, "churn":n, "rounds":n, "grouped":bool,
"repos":[{"path","reviewed_sha"}]} — the commits of the last review, for the next one's diff.
"""
import json
import os
import re
import sys

NUMBERED = re.compile(r"^\s*[0-9]+[.)]\s*(.*)$")
BLOCKING_TAG = re.compile(r"\[(acceptance_failure|regression_from_patch)\]")
ADVISORY = re.compile(r"\[(related_improvement|pre_existing|harness_failure|scope_violation|spec_conflict)\]")
# "REACH: rare", "**REACH:** rare", "REACH — rare"; the value decides, the spelling around it does not.
REACH = re.compile(r"\bREACH\**\s*[:—–-]\s*\**\s*(ordinary|data[-_ ]?loss|rare)\b", re.I)
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


def rare(line):
    m = REACH.search(line)
    return bool(m) and m.group(1).lower() == "rare"


def demote(text):
    """The answer with each blocking item marked REACH: rare re-tagged [related_improvement]."""
    out = []
    for ln in text.splitlines():
        if NUMBERED.match(ln) and BLOCKING_TAG.search(ln) and rare(ln):
            ln = BLOCKING_TAG.sub("[related_improvement]", ln, count=1) + " (rare: advisory, does not block)"
        out.append(ln)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def blocking(text):
    out = []
    for ln in text.splitlines():
        m = NUMBERED.match(ln)
        if m and not ADVISORY.search(ln) and not (BLOCKING_TAG.search(ln) and rare(ln)):
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
    if cmd == "reach":
        sys.stdout.write(demote(read(path)))
        return 0
    if cmd == "init":
        text = read(sys.argv[3])
        items = [{"id": "T%d" % (i + 1), "text": t, "open": True} for i, t in enumerate(blocking(text))]
        one = len(sys.argv) > 5 and sys.argv[5] == "one"
        save(path, {"items": items, "stall": 0, "churn": 0, "rounds": 0, "run": os.environ.get("LEDGER_RUN", ""), "grouped": one or len(items) <= 1,
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
    if cmd == "attempt":
        # The person who answered a parked task has spent the no-progress budget for it: the
        # attempt that follows gets its own, and the open items are still there to check.
        rid = sys.argv[3] if len(sys.argv) > 3 else ""
        if rid and d.get("run") != rid:
            d["run"], d["stall"], d["churn"] = rid, 0, 0
            save(path, d)
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
        open_now = sum(1 for it in d["items"] if it["open"] and not it.get("same_as"))
        if was_open:
            # Fewer open than this round found is progress; a closing paid for with a new blocker is not.
            d["stall"] = 0 if open_now < len(was_open) else int(d.get("stall", 0)) + 1
            d["churn"] = int(d.get("churn", 0)) + 1 if (added and open_now >= len(was_open)) else 0
        d["grouped"] = grouped_now
        d["rounds"] = int(d.get("rounds", 0)) + 1
        snap = snapshot(sys.argv[4] if len(sys.argv) > 4 else "")
        if snap:
            d["repos"] = snap
        save(path, d)
        print(json.dumps({"was_open": len(was_open), "closed": closed, "added": added,
                          "open": [it["id"] for it in d["items"] if it["open"] and not it.get("same_as")],
                          "stall": d["stall"], "churn": int(d.get("churn", 0)), "grouped": grouped_now}))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
