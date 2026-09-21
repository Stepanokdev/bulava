#!/usr/bin/env python3
"""Extract AskUserQuestion question/answer pairs from Claude Code transcripts.

Scans ~/.claude/projects/**/*.jsonl, finds every AskUserQuestion tool_use and
the matching tool_result (the user's actual choice), and writes pairs to
~/.claude/supervisor/qa-history.jsonl (state, never the repo). These pairs are the raw material for distilling
the user's decision style into SUPERVISOR.md.
"""
import json
import os
import sys
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"

# The output is a transcript of one person's real decisions — their projects, their clients, the
# questions they were asked about them. It used to be written into the engine checkout and was
# committed with the product, so it travelled to anyone who cloned it. It is state, not code.
STATE_DIR = Path(os.environ.get("SUPERVISOR_STATE_DIR") or (Path.home() / ".claude" / "supervisor"))
OUT_PATH = STATE_DIR / "qa-history.jsonl"


def iter_records(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def extract_pairs(path):
    """Yield (question_input, answer_text, project, timestamp) tuples."""
    pending = {}  # tool_use_id -> (input, timestamp)
    for rec in iter_records(path):
        msg = rec.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("name") == "AskUserQuestion":
                pending[block.get("id")] = (block.get("input", {}), rec.get("timestamp", ""))
            elif block.get("type") == "tool_result" and block.get("tool_use_id") in pending:
                q_input, ts = pending.pop(block["tool_use_id"])
                answer = block.get("content")
                if isinstance(answer, list):
                    answer = " ".join(
                        b.get("text", "") for b in answer if isinstance(b, dict)
                    )
                yield q_input, str(answer or ""), ts


def main():
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    total_files = 0
    total_pairs = 0
    with open(OUT_PATH, "w", encoding="utf-8") as out:
        for jsonl in sorted(PROJECTS_DIR.rglob("*.jsonl")):
            if "/memory/" in str(jsonl):
                continue
            total_files += 1
            project = jsonl.parent.name
            for q_input, answer, ts in extract_pairs(jsonl):
                questions = q_input.get("questions", [])
                if not questions:
                    continue
                out.write(json.dumps({
                    "project": project,
                    "timestamp": ts,
                    "questions": [
                        {
                            "question": q.get("question", ""),
                            "options": [o.get("label", "") for o in q.get("options", [])],
                        }
                        for q in questions if isinstance(q, dict)
                    ],
                    "answer": answer.strip()[:2000],
                }, ensure_ascii=False) + "\n")
                total_pairs += 1
    print(f"Scanned {total_files} transcripts, extracted {total_pairs} Q&A pairs -> {OUT_PATH}")


if __name__ == "__main__":
    sys.exit(main())
