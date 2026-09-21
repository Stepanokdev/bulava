#!/usr/bin/env python3
"""What MCP servers this machine has, what each one is for, and which ones get used.

Three sources, each the honest one for its question.

WHICH SERVERS EXIST — `claude mcp list`. Not a config file: the account's own connectors
(claude.ai Atlassian, Gmail, and so on) appear in none of them, and a list assembled from
`~/.claude.json` alone would quietly omit half of what is connected. The CLI also reports live
health, which is the difference between "configured" and "working".

WHAT EACH IS FOR — the transcripts. Claude Code records a server's own instructions as a
structured `mcp_instructions_delta` attachment when it connects, so the description a server
declares about itself is already on disk. Nothing has to be started to read it, which matters:
starting a server means running third-party code to fill in a caption.

WHICH GET USED — the transcripts again, the same way skill usage is counted: every call is a
tool_use named `mcp__<server>__<tool>`.

WHAT IS NEVER EMITTED — environment variables and headers. `claude mcp get` prints
`Authorization: Basic …` and a server's env holds API keys; a window that displayed them would
put a credential on screen and into every screenshot of it. Only the transport and the endpoint
or command are reported.
"""
import json, os, re, subprocess, sys, collections

def transcript_roots():
    home = os.path.expanduser("~")
    override = os.environ.get("SUPERVISOR_TRANSCRIPT_ROOT")
    if override:
        return [p for p in override.split(":") if p and os.path.isdir(p)]
    return [p for p in [os.path.join(home, ".claude", "projects")] if os.path.isdir(p)]

def tool_key(name):
    """The shape a server's name takes inside a tool name.

    A tool is called `mcp__<server>__<tool>`, and the server part has every character that is not
    a letter or a digit replaced with an underscore: "claude.ai Atlassian" becomes
    "claude_ai_Atlassian". Comparing the display name directly meant no account connector ever
    matched its own calls, and all seven of them reported zero uses while being used daily.
    """
    return re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")

def scan_transcripts():
    """Descriptions and per-server usage, in one pass.

    Cheap pre-filters first: the overwhelming majority of lines mention neither, and opening a
    thousand files is only affordable if most lines are rejected on a substring test.
    """
    uses, last, described, files = collections.Counter(), {}, {}, 0
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
                        has_tool = "mcp__" in line
                        has_desc = "mcp_instructions_delta" in line
                        if not has_tool and not has_desc:
                            continue
                        try:
                            record = json.loads(line)
                        except ValueError:
                            continue
                        stamp = record.get("timestamp") or ""
                        if has_desc:
                            _collect_descriptions(record, described, stamp)
                        if has_tool:
                            _collect_uses(record, uses, last, stamp)
    return uses, last, described, files

def _collect_descriptions(record, described, stamp):
    attachment = record.get("attachment") or {}
    if attachment.get("type") != "mcp_instructions_delta":
        return
    names = attachment.get("addedNames") or []
    blocks = attachment.get("addedBlocks") or []
    for i, server in enumerate(names):
        if i >= len(blocks):
            break
        text = (blocks[i] or "").strip()
        # Each block opens with its own "## <name>" heading; the caption is what follows.
        if text.startswith("##"):
            text = text.split("\n", 1)[1].strip() if "\n" in text else ""
        if not text:
            continue
        # The newest wins: a server that was reworded should read as it reads today.
        previous = described.get(server)
        if previous is None or stamp >= previous[1]:
            described[server] = (text, stamp)

def _collect_uses(record, uses, last, stamp):
    stack = [record]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            name = node.get("name")
            if isinstance(name, str) and name.startswith("mcp__"):
                parts = name.split("__")
                if len(parts) >= 3:
                    server = tool_key(parts[1])
                    uses[server] += 1
                    if stamp and (server not in last or stamp > last[server]):
                        last[server] = stamp
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)

STATUS = [("✔", "connected"), ("✘", "failed"), ("!", "needs_auth")]

def list_servers(timeout):
    """`claude mcp list`, parsed. Bounded: one unreachable server should not hold the window."""
    binary = os.environ.get("SUPERVISOR_CLAUDE_BIN", "claude")
    try:
        out = subprocess.run([binary, "mcp", "list"], capture_output=True, text=True,
                             timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    servers = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.endswith("…") or ":" not in line:
            continue
        name, _, rest = line.partition(":")
        name, rest = name.strip(), rest.strip()
        if not name or name.lower().startswith("checking"):
            continue
        status, detail = "unknown", rest
        if " - " in rest:
            detail, _, tail = rest.rpartition(" - ")
            for glyph, value in STATUS:
                if tail.startswith(glyph):
                    status = value
                    break
            else:
                detail = rest
        servers.append({"name": name, "target": detail.strip(), "status": status})
    return servers

def transport(target):
    if target.startswith(("http://", "https://")):
        return "http"
    return "stdio"

def scope_of(name, config):
    """Where the server is configured, derived from files rather than asked of the CLI.

    `claude mcp get` would answer this exactly, but it re-runs a health check per server, and
    nineteen of those is a minute of waiting for a word.
    """
    if name.startswith("claude.ai "):
        return "account"
    if name in (config.get("user") or set()):
        return "user"
    projects = config.get("projects") or {}
    for project, names in projects.items():
        if name in names:
            return "project:" + project
    return "unknown"

def read_config():
    path = os.path.expanduser("~/.claude.json")
    try:
        data = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    user = set((data.get("mcpServers") or {}).keys())
    projects = {}
    for project, entry in (data.get("projects") or {}).items():
        names = set(((entry or {}).get("mcpServers") or {}).keys())
        if names:
            projects[project] = names
    return {"user": user, "projects": projects}

def main():
    as_json = "--json" in sys.argv
    fast = "--fast" in sys.argv          # the list and health only; no transcript scan
    timeout = 90
    for arg in sys.argv[1:]:
        if arg.startswith("--timeout="):
            try:
                timeout = max(5, int(arg.split("=", 1)[1]))
            except ValueError:
                pass

    servers = list_servers(timeout)
    config = read_config()
    uses, last, described, files = ({}, {}, {}, 0) if fast else scan_transcripts()

    rows = []
    for server in servers:
        name = server["name"]
        description, _ = described.get(name, ("", ""))
        rows.append({
            "name": name,
            "target": server["target"],
            "status": server["status"],
            "transport": transport(server["target"]),
            "scope": scope_of(name, config),
            "description": description,
            "uses": uses.get(tool_key(name), 0),
            "last": (last.get(tool_key(name)) or "")[:10],
        })
    rows.sort(key=lambda r: (-r["uses"], r["name"].lower()))

    if as_json:
        print(json.dumps({"servers": rows, "transcripts": files, "counted": not fast},
                         ensure_ascii=False, indent=2))
        return

    print(f"серверів: {len(rows)}")
    for r in rows:
        mark = {"connected": "✔", "failed": "✘", "needs_auth": "!"}.get(r["status"], "?")
        print(f"  {mark} {r['name']:<28}{r['scope']:<12}{r['uses']:>5} викликів")
        if r["description"]:
            print(f"      {r['description'][:100]}")

main()
