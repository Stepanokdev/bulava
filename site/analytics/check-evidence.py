#!/usr/bin/env python3
"""Re-do the benchmark's artefact identity check over the network, instead of asserting it.

    check-evidence.py [--offline]

The page says, beside two of the three runs, that the build being served at the linked address is
byte-for-byte the build those numbers were measured from — and beside the third, that it is not.
Three claims, and until this existed none of them was checked by anything: the previous version
of this file fetched each address, saw HTTP 200 and a response longer than 200 bytes, and reported
success. That establishes a web server is running. It establishes nothing about identity.

So this fetches every file in the published manifest, hashes it, folds the hashes together by the
procedure `site/benchmark.json` publishes, and compares the result with the digest recorded for
that address. It also reports which individual files differ, because "the digest changed" is not
a useful thing to be told about twelve files.

`--offline` verifies only what needs no network: that each manifest still folds to the digest
published beside it. A manifest that does not reproduce its own digest is a broken record whether
or not anybody is serving it.

Exit code is the number of problems.
"""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "site", "benchmark.json")


def fold(entries, procedure):
    """The published procedure, in code. Order by path, render, hash the text."""
    ordered = sorted(entries, key=lambda e: e["path"])
    text = "".join(f"{e['sha256']}  {e['path']}\n" for e in ordered)
    return hashlib.sha256(text.encode()).hexdigest()


def fetch(url, timeout=25):
    request = urllib.request.Request(url, headers={"User-Agent": "bulava-evidence-check"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, response.read()


def main():
    offline = "--offline" in sys.argv
    data = json.load(open(DATA, encoding="utf-8"))
    procedure = data["procedure"]
    problems = []
    checked = 0

    for scenario in data["scenarios"]:
        key = scenario["key"]
        manifest = scenario["measured_manifest"]

        # 1. The record is consistent with itself, network or no network.
        if len(manifest) != scenario["measured_files"]:
            problems.append(f"{key}: the manifest has {len(manifest)} files, "
                            f"the record says {scenario['measured_files']}")
        rolled = fold(manifest, procedure)
        if rolled != scenario["measured_sha256"]:
            problems.append(f"{key}: the manifest folds to {rolled[:16]}…, "
                            f"and the published digest is {scenario['measured_sha256'][:16]}…")
        if offline:
            continue

        # 2. And what that address is actually serving today.
        served, missing = [], []
        base = scenario["result_url"].rstrip("/")
        for entry in manifest:
            url = base + entry["path"][1:]          # "./index.html" → "/index.html"
            try:
                status, body = fetch(url)
            except (urllib.error.URLError, OSError, TimeoutError) as error:
                missing.append(f"{entry['path']} ({error})")
                continue
            if status != 200:
                missing.append(f"{entry['path']} ({status})")
                continue
            served.append({"path": entry["path"], "sha256": hashlib.sha256(body).hexdigest()})

        if missing:
            problems.append(f"{key}: {len(missing)} file(s) the manifest names are not served — "
                            + ", ".join(missing[:4]))
            continue

        now = fold(served, procedure)
        checked += 1
        differing = [a["path"] for a, b in zip(sorted(manifest, key=lambda e: e["path"]),
                                               sorted(served, key=lambda e: e["path"]))
                     if a["sha256"] != b["sha256"]]

        if now != scenario["served_sha256"]:
            problems.append(
                f"{key}: {base} now folds to {now[:16]}…, and the page was published saying "
                f"{scenario['served_sha256'][:16]}…. The build at that address changed; "
                f"{len(differing)} of {len(manifest)} files differ from the measured one.")
            continue

        # The record still holds — now does the CLAIM the page makes from it?
        matches = not differing
        if matches != scenario["served_matches_measured"]:
            problems.append(
                f"{key}: the page says the served build is "
                f"{'the same bytes' if scenario['served_matches_measured'] else 'a later build'}, "
                f"and {len(differing)} of {len(manifest)} files say otherwise")

    for p in problems:
        print(p)
    if not problems:
        if offline:
            print(f"{len(data['scenarios'])} manifests each fold to the digest published "
                  f"beside them (nothing fetched)")
        else:
            same = sum(1 for s in data["scenarios"] if s["served_matches_measured"])
            print(f"{checked} address(es) re-hashed file by file: {same} serve exactly the bytes "
                  f"that were measured, {checked - same} serve a later build — "
                  f"which is what the page says of each")
    return len(problems)


if __name__ == "__main__":
    sys.exit(main())
