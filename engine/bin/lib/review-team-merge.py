#!/usr/bin/env python3
"""Join the answers of a review team (lib/review-team.sh) into one review, as the gate reads one.

  review-team-merge.py <dir> <role> [<role>…]

<dir> holds, per role, <role>.out (what the reviewer printed) and <role>.rc (its exit code). Prints
the joined review on stdout and writes <dir>/summary.json. Exit 3 when no member answered.

The join is a union, as on the bench: no vote, no model in between. Only usable answers count — a
state, and for COMPLETE a verdict; any other answer is named with the members that did not answer.
  COMPLETE/FAIL  if any member read it through and failed it — whatever the others said
  BLOCKED        else, if any member is blocked
  HANDOFF        else, if any member hands off
  COMPLETE/PASS  only if every usable answer passed it
  CRITERIA       the first member that answered the criteria line.
Each member's own list follows under its name, so the worker sees who found what.
"""
import json
import os
import re
import sys

STATE_RE = re.compile(r"STATE:\s*(COMPLETE|HANDOFF|BLOCKED)")
VERDICT_RE = re.compile(r"VERDICT:\s*(PASS|FAIL)")
TITLES = {
    "contract": "Contract and business logic",
    "security": "Security and data integrity",
    "state": "State transitions and integrations",
    "general": "General review",
    "negative": "Business rules and negative paths",
    "legacy": "Old records and invalid data",
    "outcome": "What the person gets",
}


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def main():
    d, roles = sys.argv[1], sys.argv[2:]
    members = []
    for role in roles:
        out = read(os.path.join(d, role + ".out"))
        rc = read(os.path.join(d, role + ".rc")).strip() or "1"
        head = "\n".join(out.splitlines()[:8])
        st = STATE_RE.search(head)
        vd = VERDICT_RE.search(head)
        state = st.group(1) if st and rc == "0" else None
        verdict = vd.group(1) if vd and rc == "0" else None
        # A usable answer: a state, and for COMPLETE a verdict. "COMPLETE" with no verdict decides
        # nothing, and is counted with the members that did not answer.
        if state == "COMPLETE" and not verdict:
            state = None
        members.append({"role": role, "title": TITLES.get(role, role), "rc": rc, "out": out,
                        "state": state, "verdict": verdict if state else None})
    answered = [m for m in members if m["state"]]
    missing = [m for m in members if not m["state"]]
    summary = {"members": [{"role": m["role"], "rc": m["rc"], "state": m["state"], "verdict": m["verdict"]}
                           for m in members]}
    if not answered:
        with open(os.path.join(d, "summary.json"), "w") as fh:
            json.dump(summary, fh)
        return 3

    # A defect found is the strongest answer: one member that read the work through and failed it
    # sends it back, whatever another member said about being blocked or handing off — those lists go
    # back too, under their names. Without a FAIL, a member that is blocked parks the run, then one
    # that hands off; only all of them passing is a pass.
    states = [m["state"] for m in answered]
    if any(m["state"] == "COMPLETE" and m["verdict"] == "FAIL" for m in answered):
        state, verdict = "COMPLETE", "FAIL"
    elif "BLOCKED" in states:
        state, verdict = "BLOCKED", "N/A"
    elif "HANDOFF" in states:
        state, verdict = "HANDOFF", "N/A"
    else:
        state, verdict = "COMPLETE", "PASS"
    criteria = ""
    for m in answered:
        found = re.search(r"^CRITERIA:.*$", "\n".join(m["out"].splitlines()[:8]), re.M)
        if found:
            criteria = found.group(0)
            break

    lines = ["STATE: " + state]
    if verdict:
        lines.append("VERDICT: " + verdict)
    if criteria:
        lines.append(criteria)
    who = ", ".join(m["title"] for m in answered)
    lines.append("REVIEW TEAM: %d of %d reviewers answered (%s)%s." % (
        len(answered), len(members), who,
        ("; did not answer: " + ", ".join(m["title"] for m in missing)) if missing else ""))
    lines.append("")
    for m in answered:
        body = [ln for ln in m["out"].splitlines()
                if not re.match(r"^\s*(STATE|VERDICT|CRITERIA)\s*:", ln)]
        while body and not body[0].strip():
            body.pop(0)
        if m["state"] == "COMPLETE" and m["verdict"] == "PASS" and verdict == "FAIL":
            lines.append("— %s: PASS —" % m["title"])
            continue
        mark = m["verdict"] or m["state"]
        lines.append("— %s: %s —" % (m["title"], mark))
        lines.extend(body[:60])
        lines.append("")
    summary.update({"state": state, "verdict": verdict, "answered": len(answered), "of": len(members)})
    with open(os.path.join(d, "summary.json"), "w") as fh:
        json.dump(summary, fh)
    sys.stdout.write("\n".join(lines).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
