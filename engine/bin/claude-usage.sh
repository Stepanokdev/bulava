#!/bin/bash
set -u
STATE_DIR="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
OUT="$STATE_DIR/usage.json"
mkdir -p "$STATE_DIR"

command -v security >/dev/null 2>&1 || exit 0

python3 - "$OUT" <<'PY'
import json, subprocess, sys, time, urllib.request, urllib.error

out = sys.argv[1]

def keychain_token():
    r = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, None
    try:
        blob = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None, None
    oauth = blob.get("claudeAiOauth") or {}
    return oauth.get("accessToken"), oauth.get("subscriptionType")

token, plan = keychain_token()
if not token:
    sys.exit(0)

req = urllib.request.Request(
    "https://api.anthropic.com/api/oauth/usage",
    headers={"Authorization": f"Bearer {token}",
             "anthropic-beta": "oauth-2025-04-20",
             "User-Agent": "night-shift/1"})
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
    # Offline, or the token expired and only the CLI can refresh it. Leave what is there.
    sys.exit(0)

def epoch(iso):
    """The API answers in ISO8601; everything downstream reads epoch seconds."""
    if not iso:
        return 0
    text = iso.replace("Z", "+00:00")
    # Python's fromisoformat wants at most 6 fractional digits.
    if "." in text:
        head, _, tail = text.partition(".")
        frac = "".join(ch for ch in tail if ch.isdigit())[:6]
        rest = tail[len(frac):] if len(tail) > len(frac) else ""
        offset = ""
        for marker in ("+", "-"):
            if marker in rest:
                offset = rest[rest.index(marker):]
                break
        text = f"{head}.{frac}{offset}"
    try:
        from datetime import datetime
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return 0

def window(node):
    if not isinstance(node, dict) or node.get("utilization") is None:
        return None
    return {"used_percentage": float(node["utilization"]),
            "resets_at": epoch(node.get("resets_at"))}

payload = {"ts": int(time.time()), "source": "oauth", "plan": plan,
           "five_hour": window(data.get("five_hour")),
           "seven_day": window(data.get("seven_day"))}
if payload["five_hour"] is None and payload["seven_day"] is None:
    sys.exit(0)

tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
import os
os.replace(tmp, out)
print(json.dumps(payload, ensure_ascii=False))
PY
