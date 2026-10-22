#!/bin/bash
set -u
STATE_DIR="${SUPERVISOR_STATE_DIR:-$HOME/.claude/supervisor}"
OUT="$STATE_DIR/usage.json"
mkdir -p "$STATE_DIR"

# macOS keeps Claude Code's sign-in in the Keychain; Linux and WSL2 keep the same JSON in a file of
# the CLI's own (`~/.claude/.credentials.json`, mode 600). Neither present: nothing to ask with.
# A server signs in with `claude setup-token` instead: a long-lived token in CLAUDE_CODE_OAUTH_TOKEN
# and no credentials file at all. That token was issued for inference, so the usage endpoint may
# refuse it; then nothing is written and the reading stays "unknown", which is the honest answer.
CRED_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || command -v security >/dev/null 2>&1 || [ -r "$CRED_FILE" ] || exit 0

python3 - "$OUT" "$CRED_FILE" <<'PY'
import json, os, subprocess, sys, time, urllib.request, urllib.error

out = sys.argv[1]

def keychain_token():
    env_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "").strip()
    if env_token:
        return env_token, None
    raw = None
    try:
        r = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                           capture_output=True, text=True)
        if r.returncode == 0:
            raw = r.stdout
    except FileNotFoundError:
        pass
    if raw is None:
        try:
            with open(sys.argv[2], "r", encoding="utf-8") as fh:
                raw = fh.read()
        except (OSError, IndexError):
            return None, None
    try:
        blob = json.loads(raw)
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
