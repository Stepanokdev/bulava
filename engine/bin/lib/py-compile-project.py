#!/usr/bin/env python3
"""Compile the project's own Python files, and only those.

    py-compile-project.py <project dir>            compile; exit 1 when any file fails
    py-compile-project.py <project dir> --count    print how many files would be compiled

The verifier used to run `python3 -m compileall -q .`, which walks every directory, the project's
own `.venv` included. A dependency in there written for Python 2 (olefile's `olefile2.py`) failed to
compile, the step failed, and a review Codex had passed was turned into FAIL for a file nobody wrote.
compileall can be given an exclusion regex, but the real question is which files are the project's,
and git already answers it: what is tracked, plus what is new and not ignored. Outside git there is
no such list, so the tree is walked with the dependency folders left out.

Dependency folders are left out even when git lists them. A `.venv` nobody put in .gitignore is
untracked and not ignored, so `ls-files --others --exclude-standard` returns all of it.
"""
import os
import importlib.util
import subprocess
import sys

# Folders that hold someone else's code or the tools' own caches. Not `build`, `dist` or `env`: a
# project may keep its own package under any of those names.
SKIP_DIRS = {
    ".venv", "venv", "virtualenv", ".tox", ".nox", "site-packages", "node_modules", ".git",
    "__pycache__", ".eggs", ".mypy_cache", ".pytest_cache", ".ruff_cache",
}


def skipped(rel):
    parts = rel.replace(os.sep, "/").split("/")[:-1]
    return any(p in SKIP_DIRS or p.endswith(".egg-info") for p in parts)


def from_git(root):
    try:
        out = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
             "--", "*.py"],
            check=True, capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return sorted({p for p in out.decode("utf-8", "surrogateescape").split("\0") if p})


def from_walk(root):
    found = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not x.endswith(".egg-info")]
        for f in files:
            if f.endswith(".py"):
                found.append(os.path.relpath(os.path.join(d, f), root))
    return sorted(found)


def project_files(root):
    listed = from_git(root)
    if listed is None:
        listed = from_walk(root)
    # A tracked file deleted in the working tree is still in the index; there is nothing to compile.
    return [p for p in listed if not skipped(p) and os.path.isfile(os.path.join(root, p))]


def main(argv):
    if len(argv) < 2:
        print("usage: py-compile-project.py <project dir> [--count]", file=sys.stderr)
        return 2
    root = argv[1]
    files = project_files(root)
    if "--count" in argv[2:]:
        print(len(files))
        return 0
    bad = 0
    for rel in files:
        # Compiled in memory: checking syntax must not leave __pycache__ folders in the worker's
        # tree for the next diff to pick up. decode_source honours a PEP 263 coding line.
        try:
            with open(os.path.join(root, rel), "rb") as fh:
                compile(importlib.util.decode_source(fh.read()), rel, "exec", dont_inherit=True)
        except SyntaxError as e:
            bad += 1
            print(f"{rel}:{e.lineno}: {e.msg}")
        except (OSError, ValueError, UnicodeDecodeError) as e:
            bad += 1
            print(f"{rel}: {e}")
    print(f"{len(files) - bad} of {len(files)} project Python files compile")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
