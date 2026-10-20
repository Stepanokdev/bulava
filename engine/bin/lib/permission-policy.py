#!/usr/bin/env python3
"""Keep organization-managed Bash approvals in the human permission flow.

PermissionRequest does not include the matching permission rule or tool metadata.
Unlike PreToolUse, its allow result can answer an explicit ask rule. Do not try to
reimplement Claude Code's shell parser or execute an organization's policyHelper:
if any installed managed source asks about Bash, leave Bash prompts to the person.
This deliberately also covers an inactive source (remote eligibility and policy
composition are private to the running Claude process). It can preserve more
prompts than necessary, but cannot silently approve an organization's ask rule.

Source locations follow https://code.claude.com/docs/en/managed-settings and
https://code.claude.com/docs/en/server-managed-settings. No policy content is
printed: stdout is either "ask" or empty; unreadable/malformed policies fail with
a nonzero status so the caller can also leave the prompt to the person.
"""

import fnmatch
import json
import os
from pathlib import Path
import plistlib
import pwd
import sys
from xml.parsers.expat import ExpatError


MAX_POLICY_BYTES = 8 * 1024 * 1024


def read_policy(path, *, plist=False):
    """Return a policy object, or None for an absent source; never hide errors."""
    path = Path(path)
    try:
        with path.open("rb") as source:
            content = source.read(MAX_POLICY_BYTES + 1)
    except FileNotFoundError:
        if path.is_symlink():
            raise ValueError("managed policy is a broken symlink")
        return None
    if len(content) > MAX_POLICY_BYTES:
        raise ValueError("managed policy exceeds the read limit")
    if plist:
        policy = plistlib.loads(content)
    else:
        # An empty managed settings file counts as {} in Claude Code.
        policy = json.loads(content) if content.strip() else {}
    if not isinstance(policy, dict):
        raise ValueError("managed policy must be an object")
    return policy


def policy_requires_human(policy, tool="Bash"):
    """Conservatively recognize every managed ask rule naming this tool."""
    # A helper's output replaces the policy and is unavailable to a command hook.
    if policy.get("policyHelper") is not None or policy.get("policyHelpers") is not None:
        return True
    permissions = policy.get("permissions", {})
    if permissions is None:
        return False
    if not isinstance(permissions, dict):
        raise ValueError("managed permissions must be an object")
    rules = permissions.get("ask", [])
    if rules is None:
        return False
    if not isinstance(rules, list):
        raise ValueError("managed ask rules must be an array")
    for rule in rules:
        if not isinstance(rule, str):
            raise ValueError("managed ask rule must be text")
        # Ask rules allow globs in tool names, including * and B*. Parentheses
        # scope tool arguments; any Bash scope is enough to preserve the prompt.
        name = rule.split("(", 1)[0].strip()
        if not name:
            raise ValueError("managed ask rule must name a tool")
        if fnmatch.fnmatchcase(tool, name):
            return True
    return False


def managed_policies(config_dir=None, managed_dir=None, mdm_paths=None):
    """Yield available managed sources; optional paths support isolated tests."""
    config_dir = Path(config_dir or os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    if managed_dir is None:
        managed_dir = ("/Library/Application Support/ClaudeCode" if sys.platform == "darwin"
                       else "/etc/claude-code")
    managed_dir = Path(managed_dir)
    remote = read_policy(config_dir / "remote-settings.json")
    if remote is not None:
        # Claude's cache carries internal metadata with $-prefixed keys.
        yield {key: value for key, value in remote.items() if not key.startswith("$")}
    if mdm_paths is None:
        mdm_paths = []
        if sys.platform == "darwin":
            username = pwd.getpwuid(os.getuid()).pw_name
            base = Path("/Library/Managed Preferences")
            mdm_paths = [base / username / "com.anthropic.claudecode.plist",
                         base / "com.anthropic.claudecode.plist"]
    for path in mdm_paths:
        policy = read_policy(path, plist=True)
        if policy is not None:
            yield policy
    policy = read_policy(managed_dir / "managed-settings.json")
    if policy is not None:
        yield policy
    drop_ins = managed_dir / "managed-settings.d"
    try:
        entries = sorted(drop_ins.iterdir())
    except FileNotFoundError:
        entries = []
    for path in entries:
        if path.name.startswith(".") or not path.name.endswith(".json"):
            continue
        # Claude accepts files and symlinks, and ignores subdirectories.
        if path.is_dir():
            continue
        policy = read_policy(path)
        if policy is not None:
            yield policy


def inspect_policies(policies, tool="Bash"):
    """Inspect an iterable of admin policy objects, including isolated fixtures."""
    preserve = False
    # Read all sources even after an ask is found: corrupt policy input must not
    # be mistaken for a complete successful policy inspection.
    for policy in policies:
        preserve = policy_requires_human(policy, tool) or preserve
    return preserve


def main():
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict) or request.get("tool_name") != "Bash":
            return 0
        if inspect_policies(managed_policies()):
            print("ask")
        return 0
    except (OSError, ValueError, TypeError, LookupError, ExpatError, plistlib.InvalidFileException):
        return 1


if __name__ == "__main__":
    sys.exit(main())
