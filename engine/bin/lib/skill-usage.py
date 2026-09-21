#!/usr/bin/env python3
"""Which skills actually get used, and which have only ever cost context.

A skill invocation is recorded in Claude Code's own transcript as a tool_use named `Skill`
carrying `{"skill": "<name>"}` and a timestamp. Nothing else has to be instrumented: the
evidence is already on disk, the same way `ccusage` reads token counts from the same files.

The honest limit, printed with the numbers: transcripts hold what was kept. A skill used in a
session that has since been deleted leaves no trace, so "no uses" means "no evidence of use",
never "never useful". That distinction is the difference between a report and an accusation.
"""
import json, os, sys, collections

def transcript_roots():
    home = os.path.expanduser("~")
    override = os.environ.get("SUPERVISOR_TRANSCRIPT_ROOT")
    if override:
        return [p for p in override.split(":") if p and os.path.isdir(p)]
    return [p for p in [os.path.join(home, ".claude", "projects")] if os.path.isdir(p)]

def scan_uses():
    uses, last, files = collections.Counter(), {}, 0
    for root in transcript_roots():
        for dirpath, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                files += 1
                try:
                    fh = open(os.path.join(dirpath, name), encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                with fh:
                    for line in fh:
                        # Cheap pre-filter: the overwhelming majority of lines are not skill calls.
                        if '"Skill"' not in line:
                            continue
                        try:
                            record = json.loads(line)
                        except ValueError:
                            continue
                        stamp = record.get("timestamp")
                        stack = [record]
                        while stack:
                            node = stack.pop()
                            if isinstance(node, dict):
                                if node.get("name") == "Skill":
                                    skill = (node.get("input") or {}).get("skill")
                                    if skill:
                                        uses[skill] += 1
                                        if stamp and (skill not in last or stamp > last[skill]):
                                            last[skill] = stamp
                                stack.extend(node.values())
                            elif isinstance(node, list):
                                stack.extend(node)
    return uses, last, files

def frontmatter(skill_dir):
    """The skill's own front matter: how big it is, and what it says it does.

    The description is the sentence Claude reads when deciding whether a skill applies, so it is
    also the sentence the director needs when deciding whether to keep it. Block scalars (`|`,
    `>`) are common in real skills and a naive `split(":")` mangles them, so they are folded here
    rather than shown as a stray pipe.
    """
    path = os.path.join(skill_dir, "SKILL.md")
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return 0, ""
    if not text.startswith("---"):
        return 0, ""
    end = text.find("\n---", 3)
    if end <= 0:
        return 0, ""
    head = text[3:end]
    return len(head), _yaml_description(head)

def _yaml_description(head):
    lines = head.splitlines()
    for i, line in enumerate(lines):
        if not line.startswith("description:"):
            continue
        value = line[len("description:"):].strip()
        if value not in ("|", "|-", ">", ">-", ""):
            return value.strip("'\"").strip()
        # A block scalar: take the indented lines that follow, as one paragraph.
        out = []
        for cont in lines[i + 1:]:
            if cont.strip() and not cont.startswith((" ", "\t")):
                break
            if cont.strip():
                out.append(cont.strip())
        return " ".join(out).strip()
    return ""

def frontmatter_size(skill_dir):
    """How much of every session's prompt this skill occupies: its name and description."""
    path = os.path.join(skill_dir, "SKILL.md")
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return 0
    if not text.startswith("---"):
        return 0
    end = text.find("\n---", 3)
    return len(text[3:end]) if end > 0 else 0

def plugin_roots():
    """Where INSTALLED plugins keep their skills.

    Left out entirely before, so a skill that came with a plugin was invisible: it could be
    invoked all day and still read as "used but not installed".

    Read from `installed_plugins.json`, not by walking `~/.claude/plugins`. That directory also
    holds the marketplace caches — every skill of every catalogue ever browsed — and listing those
    as installed would turn a housekeeping window into a catalogue of things the machine does not
    have. Each entry names its own `installPath`, so nothing is guessed.
    """
    home = os.path.expanduser("~")
    manifest = os.path.join(home, ".claude", "plugins", "installed_plugins.json")
    try:
        data = json.load(open(manifest, encoding="utf-8"))
    except (OSError, ValueError):
        return []
    out = []
    for _, entries in (data.get("plugins") or {}).items():
        for entry in entries if isinstance(entries, list) else [entries]:
            path = (entry or {}).get("installPath")
            if not path or not os.path.isdir(path):
                continue
            nested = os.path.join(path, "skills")
            out.append(nested if os.path.isdir(nested) else path)
    return out

def installed(projects):
    """Every place a skill can be installed, across every project asked about.

    Three things were wrong here and each one made a skill vanish from the app.

    `.agents/skills` is a PROJECT-local directory and was reported under its own scope name,
    `repo`; the app knew three scopes and folded anything else into `global`, so a genuinely
    project-local skill showed up as "loaded everywhere" and was filtered out of the panel that
    should have been the only place it appears.

    Only ONE project could be asked about, so a window claiming to hold the machine's inventory
    held one project's — and plugins were not scanned at all.

    A name is not unique across roots either: two projects may each have `design`. Rows are keyed
    by (scope, path) and carry the directory they live in, so the app can act on the right one.
    """
    home = os.path.expanduser("~")
    roots = [("global", os.path.join(home, ".claude", "skills"), "")]
    for project in projects:
        # Both are project-local. The distinction between them is a layout detail, not a scope.
        roots.append(("project", os.path.join(project, ".claude", "skills"), project))
        roots.append(("project", os.path.join(project, ".agents", "skills"), project))
    for root in plugin_roots():
        roots.append(("plugin", root, ""))

    found = {}
    for scope, root, project in roots:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            d = os.path.join(root, name)
            if not os.path.isdir(d) or not os.path.isfile(os.path.join(d, "SKILL.md")):
                continue
            key = (scope, project, name)
            if key in found:
                continue
            size, description = frontmatter(d)
            found[key] = {"name": name, "scope": scope, "path": d, "project": project,
                          "frontmatter": size, "description": description}
    return found

def main():
    # Every argument that is not a flag is a project to look in. One project was the old shape and
    # is still valid; the app now passes all of them, because "the machine's skills" is a question
    # about the machine and not about whichever product happens to be selected.
    projects = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv
    # Listing what is installed is a directory read and takes no time. Counting how often each one
    # was used means opening every transcript on the machine — thousands of files. `--fast` does
    # the first without the second, so a window can show the shelf immediately and fill in the
    # numbers when they arrive, instead of holding an empty screen until they do.
    fast = "--fast" in sys.argv
    uses, last, files = (collections.Counter(), {}, 0) if fast else scan_uses()
    have = installed(projects)

    rows = []
    for row in sorted(have.values(), key=lambda r: (-uses[r["name"]], r["name"], r["scope"])):
        rows.append({**row, "uses": uses[row["name"]], "last": (last.get(row["name"]) or "")[:10]})
    names = {r["name"] for r in rows}
    unknown = sorted(set(uses) - names)

    if as_json:
        print(json.dumps({"transcripts": files, "counted": not fast, "installed": rows,
                          "used_but_not_installed": [{"name": n, "uses": uses[n],
                                                      "last": (last.get(n) or "")[:10]}
                                                     for n in unknown]},
                         ensure_ascii=False, indent=2))
        return

    print(f"переглянуто транскриптів: {files}")
    print(f"встановлено скілів: {len(rows)}   використовувались: {sum(1 for r in rows if r['uses'])}")
    print()
    print(f"{'скіл':<34}{'де':<9}{'разів':>6}   {'востаннє':<12}")
    for r in rows:
        seen = r["last"] or "—"
        print(f"{r['name']:<34}{r['scope']:<9}{r['uses']:>6}   {seen:<12}")

    idle = [r for r in rows if not r["uses"]]
    if idle:
        cost = sum(r["frontmatter"] for r in idle)
        print()
        print(f"без слідів використання: {len(idle)} — приблизно {cost} символів "
              f"(~{cost // 4} токенів) у КОЖНІЙ сесії")
        print("транскрипти зберігають лише те, що збереглося: «без слідів» — не те саме, що «непотрібен».")
    if unknown:
        print()
        print("використовувались, але зараз не встановлені (плагіни або видалені):")
        for n in unknown:
            print(f"  {n} — {uses[n]}, востаннє {(last.get(n) or '')[:10]}")

main()
