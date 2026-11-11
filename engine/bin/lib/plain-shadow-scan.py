#!/usr/bin/env python3
"""What lib/plain-shadow.sh copies out of a folder with no git, and what it only names.

  plain-shadow-scan.py copy <folder> <max bytes>      the files to copy, NUL-separated, relative
  plain-shadow-scan.py uncopied <folder> <max bytes>  the files NOT copied — too large, or secrets —
                                                       one per line: size<TAB>mtime<TAB>kind<TAB>path
  plain-shadow-scan.py compare <base manifest> <now manifest>
                                                       what of those appeared, changed or went:
                                                       status<TAB>kind<TAB>path

Never copied: dependency and build folders, repositories nested in the folder (reviewed as
repositories), and files that look like secrets — a .env, a private key, a keystore, credentials.
Those must never reach a patch or a reviewer's brief; a change to one is named, its content is not
read. Files over the size limit are named too: a review cannot read them anyway.
"""
import os
import re
import sys

PRUNE = {".git", "node_modules", ".venv", "venv", "__pycache__", "DerivedData", ".build", "build",
         "dist", "Pods", ".gradle", ".next", "target", ".cache", ".pytest_cache", ".mypy_cache"}

SECRET = re.compile(
    r"^(\.env(\..*)?|.*\.env|\.envrc|.*\.(pem|key|p12|pfx|p8|jks|keystore|mobileprovision|kdbx|ppk|asc|gpg)"
    r"|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|.*\.secrets?|\.netrc|\.npmrc|\.pypirc|\.htpasswd|\.git-credentials"
    # Data files named for what they hold. A source file called secret_santa.js stays code.
    r"|.*(credential|secret|token|password|passwd|apikey|api_key|private).*\.(json|ya?ml|txt|ini|cfg|conf|toml|properties|plist|xml)"
    r"|service[-_]?account.*\.json|auth\.json)$",
    re.IGNORECASE)


def secret(name):
    return bool(SECRET.match(name))


def walk(root):
    """(relative path, absolute path) of every regular file a review could be about."""
    for here, dirs, files in os.walk(root):
        keep = []
        for d in dirs:
            if d in PRUNE:
                continue
            full = os.path.join(here, d)
            if os.path.islink(full) or os.path.exists(os.path.join(full, ".git")):
                continue
            keep.append(d)
        dirs[:] = sorted(keep)
        for f in sorted(files):
            full = os.path.join(here, f)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            yield os.path.relpath(full, root), full


def main():
    mode = sys.argv[1]
    if mode == "compare":
        def load(path):
            out = {}
            try:
                with open(path, encoding="utf-8", errors="surrogateescape") as fh:
                    for line in fh:
                        parts = line.rstrip("\n").split("\t", 3)
                        if len(parts) == 4:
                            out[parts[3]] = (parts[0], parts[1], parts[2])
            except FileNotFoundError:
                pass
            return out
        base, now = load(sys.argv[2]), load(sys.argv[3])
        for path in sorted(set(base) | set(now)):
            if path not in base:
                print(f"new\t{now[path][2]}\t{path}")
            elif path not in now:
                print(f"deleted\t{base[path][2]}\t{path}")
            elif base[path][:2] != now[path][:2]:
                print(f"changed\t{now[path][2]}\t{path}")
        return 0

    root, limit = sys.argv[2], int(sys.argv[3])
    out = sys.stdout.buffer
    for rel, full in walk(root):
        try:
            st = os.stat(full)
        except OSError:
            continue
        name = os.path.basename(rel)
        kind = "secret" if secret(name) else ("large" if st.st_size >= limit else "")
        if mode == "copy" and not kind:
            out.write(os.fsencode(rel) + b"\0")
        elif mode == "uncopied" and kind and "\t" not in rel and "\n" not in rel:
            out.write(f"{st.st_size}\t{int(st.st_mtime_ns)}\t{kind}\t".encode() + os.fsencode(rel) + b"\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
