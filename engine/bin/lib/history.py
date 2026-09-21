#!/usr/bin/env python3
"""Search the machine's own history: what was asked, what was answered, and when.

«Індекс транскриптів і пошук — щоб система шукала у власній історії, а не директор.»

The roadmap called for an index. The corpus said otherwise: 1.3 GB of transcripts, and ripgrep
crosses all of it in three tenths of a second. An index would be a second copy of the truth that
can go stale, maintained to save a wait nobody experiences. So this searches the files directly,
and spends its effort where the difficulty actually is — turning a matched JSON line into
something a person can read.

What comes back is the sentence, not the record: who said it, in which project, on which day, and
the session it belongs to, so the thread can be reopened. Tool calls and their results are skipped
by default; they are the bulk of the corpus and almost never the thing being looked for.
"""
import json, os, re, sys, time, mmap

def roots():
    override = os.environ.get("SUPERVISOR_TRANSCRIPT_ROOT")
    if override:
        return [p for p in override.split(":") if p and os.path.isdir(p)]
    home = os.path.expanduser("~")
    return [p for p in [os.path.join(home, ".claude", "projects")] if os.path.isdir(p)]

def project_name(record, path):
    """Which project this was, taken from the record rather than guessed from the folder name.

    The folder is the project path with every separator flattened to a dash, and both the path and
    the project's own name may already contain dashes and spaces — "Night Shift" comes back as
    "Shift" from any reasonable guess. Each record carries its own `cwd`, so there is nothing to
    reconstruct.
    """
    cwd = record.get("cwd")
    if isinstance(cwd, str) and cwd:
        return os.path.basename(cwd.rstrip("/")) or cwd
    return os.path.basename(os.path.dirname(path))

def text_of(message):
    """The words, out of whatever shape the content took."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for block in content:
        if isinstance(block, str):
            out.append(block)
        elif isinstance(block, dict) and block.get("type") == "text":
            out.append(block.get("text") or "")
    return "\n".join(t for t in out if t).strip()

def snippet(text, pattern, width):
    """The match in its sentence, not the whole turn."""
    flat = re.sub(r"\s+", " ", text).strip()
    m = pattern.search(flat)
    if not m:
        return flat[:width]
    start = max(0, m.start() - width // 3)
    end = min(len(flat), m.end() + width - (m.start() - start))
    return ("…" if start > 0 else "") + flat[start:end] + ("…" if end < len(flat) else "")

def transcripts(scope, days):
    """The files to look in, newest first, optionally only recent ones.

    The window is not a performance trick hidden from the caller — it is printed with the result.
    "Have we hit this before" is nearly always a question about recent months, and scanning four
    years of history to answer it is a cost with no reader.
    """
    cutoff = 0.0
    if days > 0:
        cutoff = time.time() - days * 86400
    found = []
    for root in scope:
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue
                if stat.st_size == 0 or (cutoff and stat.st_mtime < cutoff):
                    continue
                found.append((stat.st_mtime, path))
    found.sort(reverse=True)
    return [path for _, path in found]

def matching_lines(query, scope, days, want):
    """Every line containing the query, newest transcript first.

    Searched here rather than shelled out, and the reason is worth writing down. `rg` is not a
    binary inside Claude Code — it is a shell function, so a subprocess never finds it. And the
    `grep` that answers in a tenth of a second at an interactive prompt is also a function; the
    real `/usr/bin/grep` takes ELEVEN SECONDS over this corpus. A tool that is fast only when its
    author happens to run it is not fast.

    So: mmap and a byte search, which crosses 1.3 GB in about four seconds and depends on nothing.
    Matching is case-sensitive on the exact bytes plus the lowercase form — full Unicode case
    folding over a gigabyte would cost more than it is worth, and a query is nearly always typed
    the way it was written.
    """
    needles = {query.encode("utf-8")}
    needles.add(query.lower().encode("utf-8"))
    seen = 0
    for path in transcripts(scope, days):
        try:
            with open(path, "rb") as fh:
                with mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                    position = 0
                    while seen < want:
                        # Where does the next occurrence of ANY spelling begin?
                        at = -1
                        for needle in needles:
                            found = mm.find(needle, position)
                            if found != -1 and (at == -1 or found < at):
                                at = found
                        if at == -1:
                            break
                        start = mm.rfind(b"\n", 0, at) + 1
                        end = mm.find(b"\n", at)
                        if end == -1:
                            end = len(mm)
                        # A single transcript line can be megabytes of tool output; the ones that
                        # carry a sentence never are, so an absurd line is skipped rather than
                        # decoded.
                        if end - start <= 4 * 1024 * 1024:
                            yield mm[start:end].decode("utf-8", "ignore")
                            seen += 1
                        position = end + 1
        except (OSError, ValueError):
            continue
        if seen >= want:
            return

def main():
    argv = sys.argv[1:]
    # The leading dashes are stripped: `--who=user` is the flag `who`, and reading it back as
    # `--who` is why the first version silently ignored every option it was given.
    flags = {a.lstrip("-").split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True)
             for a in argv if a.startswith("--")}
    terms = [a for a in argv if not a.startswith("--")]
    if not terms:
        print("usage: history.py <query> [--project=DIR] [--who=user|assistant|any] "
              "[--days=N | --all] [--limit=N] [--json]", file=sys.stderr)
        return 2
    query = " ".join(terms)
    who = flags.get("who", "any")
    limit = int(flags.get("limit", 20) or 20)
    # A window by default, printed with the answer so it is never a silent limit. `--all` (or
    # --days=0) searches everything, which costs about four seconds.
    days = 0 if "all" in flags else int(flags.get("days", 120) or 120)
    as_json = "json" in flags

    scope = roots()
    project = flags.get("project")
    if project and isinstance(project, str):
        # A project's transcripts live under its path with the separators flattened.
        encoded = os.path.abspath(os.path.expanduser(project)).replace("/", "-")
        scope = [os.path.join(r, encoded) for r in roots()
                 if os.path.isdir(os.path.join(r, encoded))] or scope

    pattern = re.compile(re.escape(query), re.IGNORECASE)
    cutoff = ""
    if days > 0:
        import datetime
        cutoff = (datetime.datetime.now(datetime.timezone.utc)
                  - datetime.timedelta(days=days)).strftime("%Y-%m-%d")
    window = f"за останні {days} днів" if days > 0 else "за всю історію"

    hits = []
    # Ten times the asked-for number: most matching lines are tool calls and tool results, which
    # are discarded below, so the stream has to be wider than the answer.
    for line in matching_lines(query, scope, days, want=max(limit * 10, 200)):
        # No cheap substring pre-filter on the record type. It saved nothing measurable — the
        # lines reaching here already matched the query, so there are few — and it depended on
        # the JSON being written without spaces, which is true of Claude Code's transcripts and
        # false of anything else that writes one. A micro-optimisation that is wrong on a file
        # someone hands you is not an optimisation.
        if not pattern.search(line):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        kind = record.get("type")
        if kind not in ("user", "assistant"):
            continue
        if who != "any" and kind != who:
            continue
        message = record.get("message") or {}
        text = text_of(message)
        if not text or not pattern.search(text):
            # The match was in a tool call or a tool result, not in anything that was said.
            continue
        stamp = (record.get("timestamp") or "")[:10]
        if cutoff and stamp and stamp < cutoff:
            continue
        hits.append({
            "project": project_name(record, ""),
            "date": stamp,
            "who": kind,
            "session": record.get("sessionId") or "",
            "text": snippet(text, pattern, 260),
        })
        if len(hits) >= limit * 3:
            break

    hits.sort(key=lambda h: h["date"], reverse=True)
    hits = hits[:limit]

    if as_json:
        print(json.dumps({"query": query, "window_days": days, "hits": hits},
                         ensure_ascii=False, indent=2))
        return 0

    if not hits:
        print(f"нічого не знайдено {window}: «{query}»"
              + ("\n(спробуй --all, щоб пройти всю історію)" if days > 0 else ""))
        return 1
    print(f"знайдено {len(hits)} {window} (найновіші перші): «{query}»")
    for h in hits:
        speaker = "директор" if h["who"] == "user" else "Claude"
        print()
        print(f"  {h['date']}  {h['project']}  — {speaker}")
        print(f"    {h['text']}")
        print(f"    сесія: {h['session']}")
    return 0

sys.exit(main())
