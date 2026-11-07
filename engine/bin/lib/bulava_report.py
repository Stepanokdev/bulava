"""Bulava Report: engine problems that chats in any project noticed, kept for the weekly pass.

A chat in some client project sees the engine misbehave — a gate that blocks for no reason, a review
that loops, a verifier that fails on a file nobody wrote — and has nowhere to put it. The director
then has to remember it, or it is lost. This is that place: a report is one JSON file in a private
store on the machine where it was seen, and a weekly pass reads the store, pulls the stores of the
factory servers over ssh, writes its review and only then marks the reports it read as done.

It is NOT the anonymous error inbox (server/report-inbox). That one leaves the machine and by
contract carries no project names, paths or chat text; these reports exist precisely to carry them,
so they never leave the machine they were written on except through the director's own ssh pull.

The store, under the engine's state folder (SUPERVISOR_STATE_DIR, else ~/.claude/supervisor):

    bulava-reports/new/<id>.json    written, not yet read by a weekly pass
    bulava-reports/done/<id>.json   read; the review that read it is named inside

One file per report and no shared log: many chats write at once. A report's id is derived from what
identifies it — the host and the caller's idempotency key, or failing that its content — so a retry
after a lost answer returns the same id instead of a second report, and the file is published with a
hard link, which refuses to overwrite: two writers racing on one id end with one file.

Everything written is scrubbed of what looks like a secret first. The text comes from other agents:
whoever reads it reads data, not instructions.
"""
import datetime
import hashlib
import json
import os
import re
import socket
import subprocess

SEVERITIES = ("low", "medium", "high", "critical")
LIMITS = {"title": 200, "observed": 8000, "expected": 4000, "component": 120, "session_id": 120,
          "idempotency_key": 200, "project": 200}
MAX_EVIDENCE = 20
MAX_EVIDENCE_ITEM = 500
ID_RE = re.compile(r"^br-[0-9a-f]{16}$")

# The verifier's redaction (verify.sh, redact) and a few more shapes a pasted log carries.
_SECRETS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[REDACTED-PRIVATE-KEY]"),
    (re.compile(r"(AKIA|ASIA)[A-Z0-9]{8,}"), "[REDACTED-AWS]"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "[REDACTED-GH]"),
    (re.compile(r"glpat-[A-Za-z0-9_-]{16,}"), "[REDACTED-GITLAB]"),
    (re.compile(r"xox[abposr]-[A-Za-z0-9-]{10,}"), "[REDACTED-SLACK]"),
    (re.compile(r"AIza[0-9A-Za-z_-]{30,}"), "[REDACTED-GOOGLE]"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{12,}"), "[REDACTED-KEY]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "[REDACTED-JWT]"),
    (re.compile(r"(Bearer\s+)\S{12,}", re.I), r"\1[REDACTED]"),
    (re.compile(r"\b(Basic|Digest|Negotiate)\s+[A-Za-z0-9+/=._~-]{8,}", re.I), r"\1 [REDACTED]"),
    (re.compile(r"(://[^/\s:@]+:)[^@\s/]+@"), r"\1[REDACTED]@"),
]

# A value under a name that says it is secret: `PASSWORD=x`, `api_key: x`, `"password":"x"`,
# `token='a b c'`, `-H "X-Api-Key: x"`. The whole value goes, quoted ones with their spaces — the
# first version kept everything after the first word of `PASSWORD="two words"` and left JSON alone.
# The name may carry a prefix or a suffix (`DB_PASSWORD`, `token_value`), but the secret word must
# stand as a part of it, so `author`, `passed` and `bypass` are not secrets.
_SECRET_WORD = (r"(?:password|passwd|passphrase|pwd|pass|secret|token|api[_-]?key|apikey|access[_-]?key"
                r"|private[_-]?key|client[_-]?secret|credentials?|auth|authorization|cookie|session[_-]?id)")
_SECRET_FIELD = re.compile(
    r"""(?P<key>["']?(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_.-])*""" + _SECRET_WORD + r"s?" +
    r"""(?:[_.-][A-Za-z0-9]+)*["']?\s*[=:]\s*)"""
    # A flat list goes whole ("tokens": ["a", "b"]). Unquoted: up to a separator or a closing quote,
    # and never an object — under `"auth": {"token": …}` it is the inner field that holds the secret.
    r"""(?P<val>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\[\]]*\]|[^\s,;&}\]"'{\[][^\s,;&}\]"']*)""",
    re.I,
)


def _hide_value(m):
    v = m.group("val")
    if v[:1] in "\"'":
        return m.group("key") + v[0] + "[REDACTED]" + v[0]
    return m.group("key") + "[REDACTED]"


class ReportError(ValueError):
    """What the caller did wrong, in words it can act on."""


def scrub(text):
    for pat, rep in _SECRETS:
        text = pat.sub(rep, text)
    return _SECRET_FIELD.sub(_hide_value, text)


def state_dir():
    return os.environ.get("SUPERVISOR_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "supervisor")


def store_dir():
    return os.path.join(state_dir(), "bulava-reports")


def _ensure_store():
    root = store_dir()
    for sub in ("", "new", "done"):
        p = os.path.join(root, sub)
        os.makedirs(p, mode=0o700, exist_ok=True)
        try:
            os.chmod(p, 0o700)
        except OSError:
            pass
    return root


def engine_dir():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def engine_version():
    """The installed build stamp, else the commit of the checkout the engine runs from."""
    eng = engine_dir()
    try:
        with open(os.path.join(eng, ".engine-version")) as fh:
            v = fh.read().strip()
            if v:
                return v
    except OSError:
        pass
    try:
        out = subprocess.run(["git", "-C", eng, "describe", "--always", "--dirty", "--abbrev=12"],
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return "git-" + out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "unknown"


def project_of(cwd):
    try:
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return os.path.basename(out.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.basename(os.path.abspath(cwd)) or cwd


def _clip(name, value):
    if value is None:
        return ""
    if not isinstance(value, str):
        raise ReportError(f"{name} must be text")
    value = value.strip()
    limit = LIMITS.get(name)
    if limit and len(value) > limit:
        value = value[:limit - 1] + "…"
    return value


def _now():
    return datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds")


def submit(fields, cwd=None, env=None):
    """Store one report. Returns (report, created) — created is False when it was already stored."""
    env = os.environ if env is None else env
    cwd = cwd or os.getcwd()
    title = _clip("title", fields.get("title"))
    observed = _clip("observed", fields.get("observed"))
    if not title:
        raise ReportError("title is required: one line naming the problem")
    if not observed:
        raise ReportError("observed is required: what happened, with the exact message if there was one")
    severity = (fields.get("severity") or "medium").strip().lower()
    if severity not in SEVERITIES:
        raise ReportError("severity must be one of: " + ", ".join(SEVERITIES))
    evidence = fields.get("evidence") or []
    if isinstance(evidence, str):
        evidence = [evidence]
    if not isinstance(evidence, list) or not all(isinstance(e, str) for e in evidence):
        raise ReportError("evidence must be a list of paths, ids or short quotes")
    evidence = [scrub(e.strip())[:MAX_EVIDENCE_ITEM] for e in evidence if e.strip()][:MAX_EVIDENCE]

    host = socket.gethostname()
    user = env.get("USER") or env.get("LOGNAME") or ""
    key = _clip("idempotency_key", fields.get("idempotency_key"))
    session = _clip("session_id", fields.get("session_id") or env.get("CLAUDE_SESSION_ID") or "")
    report = {
        "schema": 1,
        "title": scrub(title),
        "observed": scrub(observed),
        "expected": scrub(_clip("expected", fields.get("expected"))),
        "severity": severity,
        "component": scrub(_clip("component", fields.get("component"))),
        "evidence": evidence,
        "project": _clip("project", fields.get("project")) or project_of(cwd),
        "cwd": os.path.abspath(cwd),
        "host": host,
        "user": user,
        "session_id": session,
        "run_id": env.get("ORCHESTRATOR_RUN_ID", ""),
        "profile": env.get("SUPERVISOR_PROFILE", "") or "mac",
        "engine_version": engine_version(),
        "reporter": _clip("component", fields.get("reporter")) or "mcp",
        "created_at": _now(),
        "status": "new",
    }
    # What identifies the report. Without a key, a retry carries the same words from the same chat.
    basis = ["v1", host, user]
    if key:
        basis += ["key", key]
    else:
        basis += ["content", report["cwd"], session, report["title"], report["observed"]]
    rid = "br-" + hashlib.sha256("\0".join(basis).encode("utf-8")).hexdigest()[:16]
    report["id"] = rid
    if key:
        report["idempotency_key"] = key

    root = _ensure_store()
    existing = find(rid)
    if existing:
        return load(existing), False
    final = os.path.join(root, "new", rid + ".json")
    tmp = os.path.join(root, "new", ".tmp-%s-%d" % (rid, os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, final)            # refuses to replace: the first writer of an id wins
            created = True
        except FileExistsError:
            created = False
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if not created:
        return load(final), False
    return report, True


def find(rid):
    if not ID_RE.match(rid or ""):
        return None
    for sub in ("new", "done"):
        p = os.path.join(store_dir(), sub, rid + ".json")
        if os.path.exists(p):
            return p
    return None


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def listing(status="new"):
    subs = ("new", "done") if status == "all" else (status,)
    out = []
    for sub in subs:
        d = os.path.join(store_dir(), sub)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".json") and ID_RE.match(name[:-5]):
                try:
                    out.append(load(os.path.join(d, name)))
                except (OSError, ValueError):
                    continue
    return sorted(out, key=lambda r: r.get("created_at", ""))


def ack(ids, review):
    """Mark reports read by the review at `review`. Only once that review exists on disk."""
    if not review or not os.path.isfile(review) or os.path.getsize(review) == 0:
        raise ReportError("ack needs the review that read these reports, written and not empty")
    review = os.path.abspath(review)
    root = _ensure_store()
    done = []
    for rid in ids:
        src = os.path.join(root, "new", rid + ".json")
        if not ID_RE.match(rid) or not os.path.exists(src):
            continue
        rep = load(src)
        rep.update(status="done", acked_at=_now(), review=review)
        dst = os.path.join(root, "done", rid + ".json")
        tmp = dst + ".tmp-%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rep, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, dst)
        os.unlink(src)
        done.append(rid)
    return done


def adopt(path, source):
    """Take in a report pulled from another machine. Returns its id when it is new here."""
    try:
        rep = load(path)
    except (OSError, ValueError):
        return None
    rid = rep.get("id", "")
    if not ID_RE.match(rid) or find(rid):
        return None
    rep["pulled_from"] = source
    rep["pulled_at"] = _now()
    rep["status"] = "new"
    # Re-scrubbed: the other machine may run an older engine.
    for k in ("title", "observed", "expected", "component"):
        if isinstance(rep.get(k), str):
            rep[k] = scrub(rep[k])
    if isinstance(rep.get("evidence"), list):
        rep["evidence"] = [scrub(str(e)) for e in rep["evidence"]][:MAX_EVIDENCE]
    root = _ensure_store()
    final = os.path.join(root, "new", rid + ".json")
    tmp = final + ".tmp-%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rep, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    try:
        os.link(tmp, final)
    except FileExistsError:
        return None
    finally:
        os.unlink(tmp)
    return rid
