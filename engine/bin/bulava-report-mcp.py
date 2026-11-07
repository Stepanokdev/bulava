#!/usr/bin/env python3
"""Bulava Report as an MCP server (stdio): any Claude chat can file an engine problem it noticed.

    claude mcp add --scope user bulava-report -- python3 "<engine>/bin/bulava-report-mcp.py"

One tool, `submit_report`. It writes to this machine's private store (lib/bulava_report.py says what
that is and why it is not the anonymous inbox) and answers with the report's id. A reporter cannot
read other reports or change anything else: there is no tool for it.

The protocol is spoken directly — newline-delimited JSON-RPC 2.0 on stdin/stdout, the stdio transport
of the MCP specification — so the server needs nothing but python3, which every machine the engine
runs on already has. The factory servers have no pip packages of ours and should not need any.
Nothing but protocol messages is ever written to stdout; diagnostics go to stderr.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import bulava_report as br  # noqa: E402

SERVER_INFO = {"name": "bulava-report", "title": "Bulava Report", "version": "1.0.0"}
# Newest first. A client asking for one of these gets it back; any other gets the newest.
PROTOCOL_VERSIONS = ("2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

INSTRUCTIONS = (
    "Bulava Report files problems of the Bulava engine itself — the app, its review gate, verifier, "
    "hooks, pieces, automations, the factory runner — so they reach the weekly engine review. "
    "Use submit_report when the engine got in the way of the work: a gate that blocked or parked "
    "wrongly, a review loop that would not end, a verifier failing on something nobody changed, a "
    "hook error, a run stuck or silent, a message lost, a status that lied. Do not use it for bugs "
    "of the project you are working on. One report per distinct problem; say what you saw, "
    "exactly, and where the evidence is."
)

SUBMIT_TOOL = {
    "name": "submit_report",
    "title": "Report a Bulava engine problem",
    "description": (
        "File one problem of the Bulava engine (not of this project) for the weekly engine review. "
        "Stored privately on this machine; returns the report id. Retrying with the same "
        "idempotency_key, or with the same words from the same session, returns the same id."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "maxLength": 200,
                      "description": "One line naming the problem, e.g. 'Gate parked the run after Codex PASS'."},
            "observed": {"type": "string", "maxLength": 8000,
                         "description": "What happened, step by step, with exact messages and times."},
            "expected": {"type": "string", "maxLength": 4000, "description": "What should have happened."},
            "severity": {"type": "string", "enum": list(br.SEVERITIES),
                         "description": "high: work lost or stuck, or the director had to step in. Default medium."},
            "component": {"type": "string", "maxLength": 120,
                          "description": "Engine part if known: review-gate, verifier, pieces, write-gate, app, phone, factory runner…"},
            "evidence": {"type": "array", "maxItems": br.MAX_EVIDENCE, "items": {"type": "string", "maxLength": 500},
                         "description": "Paths to logs or files, run/task/session ids, short exact quotes."},
            "session_id": {"type": "string", "maxLength": 120,
                           "description": "Your Claude Code session id, if you know it."},
            "idempotency_key": {"type": "string", "maxLength": 200,
                                "description": "Any stable string for this report; a retry with it never makes a second one."},
        },
        "required": ["title", "observed"],
        "additionalProperties": False,
    },
    "outputSchema": {
        "type": "object",
        "properties": {
            "id": {"type": "string"},
            "status": {"type": "string", "enum": ["stored", "already_stored"]},
            "host": {"type": "string"},
            "project": {"type": "string"},
        },
        "required": ["id", "status"],
    },
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
}


def log(msg):
    print(f"bulava-report: {msg}", file=sys.stderr, flush=True)


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result(rid, value):
    send({"jsonrpc": "2.0", "id": rid, "result": value})


def error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})


def call_tool(params):
    name = params.get("name")
    if name != "submit_report":
        return None
    args = params.get("arguments") or {}
    if not isinstance(args, dict):
        args = {}
    try:
        rep, created = br.submit(args, cwd=os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    except br.ReportError as e:
        return {"content": [{"type": "text", "text": f"Not stored: {e}"}], "isError": True}
    except OSError as e:
        log(f"store failed: {e}")
        return {"content": [{"type": "text", "text": f"Not stored: the report store could not be written ({e.strerror})."}],
                "isError": True}
    status = "stored" if created else "already_stored"
    text = (f"Report {rep['id']} {'stored' if created else 'was already stored'} on {rep['host']} "
            f"(project {rep['project']}). It will be read in the weekly engine review.")
    return {"content": [{"type": "text", "text": text}],
            "structuredContent": {"id": rep["id"], "status": status, "host": rep["host"], "project": rep["project"]},
            "isError": False}


def handle(msg):
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
        if isinstance(msg, dict) and "id" in msg:
            error(msg["id"], -32600, "Invalid Request")
        return
    method = msg.get("method")
    rid = msg.get("id")
    params = msg.get("params") or {}
    if method is None:
        return                              # a response to something we never asked: ignore
    if rid is None:
        return                              # notifications (initialized, cancelled): nothing to answer
    if method == "initialize":
        asked = params.get("protocolVersion")
        version = asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
        result(rid, {"protocolVersion": version,
                     "capabilities": {"tools": {"listChanged": False}},
                     "serverInfo": SERVER_INFO,
                     "instructions": INSTRUCTIONS})
    elif method == "ping":
        result(rid, {})
    elif method == "tools/list":
        result(rid, {"tools": [SUBMIT_TOOL]})
    elif method == "tools/call":
        out = call_tool(params if isinstance(params, dict) else {})
        if out is None:
            error(rid, -32602, f"Unknown tool: {params.get('name')}")
        else:
            result(rid, out)
    else:
        error(rid, -32601, f"Method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            error(None, -32700, "Parse error")
            continue
        try:
            if isinstance(msg, list):       # batches left the protocol in 2025-06-18; none is sent
                error(None, -32600, "Batches are not supported")
            else:
                handle(msg)
        except Exception as e:             # one bad message must not take the server down
            log(f"internal error: {e!r}")
            if isinstance(msg, dict) and msg.get("id") is not None:
                error(msg["id"], -32603, "Internal error")


if __name__ == "__main__":
    main()
