#!/usr/bin/env python3
"""The terminal side of night-shift that has nothing to do with running a worker.

`night-shift.sh` drives runs: tmux, git, the watchdog. Everything a person types to *configure*
those runs lives here instead — settings, the model catalogues, help, the health check and shell
completion — because it is mostly reading and validating JSON, which bash does badly and Python's
standard library does well. Nothing outside the standard library is imported: this has to run on
the python3 a fresh Mac, a Linux box or a WSL2 distribution already has (3.8 and newer).

The desktop app never reads anything written here. It keeps its own choices in UserDefaults and
hands them to every call it makes as SUPERVISOR_* variables; `night-shift.sh` only asks this file
for settings when a start does NOT come from the app (see `ns_settings_enabled`). That separation
is the whole compatibility story: a person can tune the terminal to Opus at max effort while the
app goes on running Sonnet, and neither notices the other.
"""

import argparse
import base64
import json
import os
import platform
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # pragma: no cover — native Windows python; the engine itself runs under WSL2
    fcntl = None

SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
BRANCH_NAME = re.compile(r"^[A-Za-z0-9._/-]+$")

# ───────────────────────────────────────────────────────────────── language of these messages
#
# The engine speaks Ukrainian, and so does everything here by default. `ui.language` (or
# NIGHT_SHIFT_LANG) switches this part to English for anyone who would rather read that.


def _ui_lang():
    env = os.environ.get("NIGHT_SHIFT_LANG", "").strip().lower()
    if env in ("en", "uk"):
        return env
    # Read straight from the file: `load_config` reports its own errors through `t()`, and a broken
    # file must still get its error message rather than recurse into it.
    try:
        with open(config_path(), "r", encoding="utf-8") as f:
            value = json.load(f).get("defaults", {}).get("ui.language", "uk")
    except Exception:
        value = "uk"
    return "en" if value == "en" else "uk"


_LANG = None


def t(uk, en):
    global _LANG
    if _LANG is None:
        _LANG = _ui_lang()
    return en if _LANG == "en" else uk


def die(msg, code=2):
    sys.stderr.write("❌ " + msg + "\n")
    sys.exit(code)


def warn(msg):
    sys.stderr.write("⚠️  " + msg + "\n")


# ───────────────────────────────────────────────────────────────── where things are

def state_dir():
    return os.environ.get("SUPERVISOR_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "supervisor")


def config_path():
    explicit = os.environ.get("NIGHT_SHIFT_CONFIG")
    if explicit:
        return explicit
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "night-shift", "config.json")


def claude_config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def canon(path):
    try:
        return os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    except Exception:
        return path


# ───────────────────────────────────────────────────────────────── the settings themselves
#
# One table, and every command reads it: validation, `config keys`, completion, the env a start
# receives. `env` is the SUPERVISOR_* variable the engine already reads; nothing new had to be
# taught to the engine itself. `live` marks the ones a running run re-reads from its run-env file on
# every Codex call, so `config set … --run` changes them for that run straight away.

CLAUDE_EFFORTS = ["auto", "none", "low", "medium", "high", "xhigh", "max", "ultracode"]
CODEX_EFFORTS = ["auto", "low", "medium", "high", "xhigh", "max", "ultra"]
LANGUAGES = {"auto": "", "en": "English", "english": "English", "uk": "Ukrainian",
             "ukrainian": "Ukrainian", "ru": "Russian", "russian": "Russian"}
PERMISSION_MODES = ["auto", "bypassPermissions", "acceptEdits", "plan", "default"]


def _bool(value):
    v = str(value).strip().lower()
    if v in ("1", "true", "yes", "on", "так"):
        return True
    if v in ("0", "false", "no", "off", "ні"):
        return False
    raise ValueError(t("очікую on або off", "expected on or off"))


def _int_range(lo, hi):
    def check(value):
        try:
            n = int(str(value).strip())
        except ValueError:
            raise ValueError(t("очікую ціле число", "expected a whole number"))
        if n < lo or (hi is not None and n > hi):
            raise ValueError(t("має бути від %d до %s" % (lo, hi if hi is not None else "∞"),
                               "must be between %d and %s" % (lo, hi if hi is not None else "∞")))
        return n
    return check


def _choice(options):
    def check(value):
        v = str(value).strip()
        for o in options:
            if v.lower() == o.lower():
                return o
        raise ValueError(t("можна: ", "allowed: ") + ", ".join(options))
    return check


def _model(kind):
    def check(value):
        v = str(value).strip()
        if v.lower() in ("", "auto", "default"):
            return "auto"
        if not SAFE_NAME.match(v):
            raise ValueError(t("ідентифікатор моделі — лише літери, цифри, . _ -",
                               "a model id is letters, digits, . _ - only"))
        known = known_model_names(kind)
        if known and v not in known:
            warn(t("«%s» немає в каталозі %s на цій машині — збережу, але перевір: night-shift models %s"
                   % (v, kind, kind),
                   "'%s' is not in this machine's %s catalogue — saved anyway, check: night-shift models %s"
                   % (v, kind, kind)))
        return v
    return check


def _effort(kind):
    base = CLAUDE_EFFORTS if kind == "claude" else CODEX_EFFORTS

    def check(value):
        v = str(value).strip().lower()
        allowed = list(base)
        for level in catalogue_levels(kind):
            if level not in allowed:
                allowed.append(level)
        if v not in allowed:
            raise ValueError(t("можна: ", "allowed: ") + ", ".join(allowed))
        return v
    return check


def _language(value):
    v = str(value).strip().lower()
    if v not in LANGUAGES:
        raise ValueError(t("можна: auto, en, uk, ru", "allowed: auto, en, uk, ru"))
    return "auto" if v == "auto" else LANGUAGES[v]


def _branch(value):
    v = str(value).strip()
    if v in ("", "-", "none", "current"):
        return ""
    if not BRANCH_NAME.match(v) or v.startswith("-") or ".." in v:
        raise ValueError(t("некоректна назва гілки", "not a valid branch name"))
    return v


def _ui_language(value):
    v = str(value).strip().lower()
    if v not in ("uk", "en"):
        raise ValueError(t("можна: uk, en", "allowed: uk, en"))
    return v


KEYS = [
    # key, env, parse, default (as shown), live?, uk help, en help
    ("claude.model", "SUPERVISOR_CLAUDE_MODEL", _model("claude"), "auto", False,
     "модель Claude-воркера: auto, opus, sonnet, haiku, fable або точний id",
     "Claude worker model: auto, opus, sonnet, haiku, fable or an exact id"),
    ("claude.effort", "SUPERVISOR_CLAUDE_EFFORT", _effort("claude"), "auto", False,
     "глибина Claude: auto (=high), none (без --effort), low … max, ultracode",
     "Claude depth: auto (=high), none (no --effort), low … max, ultracode"),
    ("codex.model", "SUPERVISOR_CODEX_MODEL", _model("codex"), "auto", True,
     "модель Codex для рев'ю й консультацій: auto або slug із `night-shift models codex`",
     "Codex model for reviews and consultations: auto or a slug from `night-shift models codex`"),
    ("codex.effort", "SUPERVISOR_CODEX_EFFORT", _effort("codex"), "auto", True,
     "глибина Codex: auto (=high), low … max, ultra",
     "Codex depth: auto (=high), low … max, ultra"),
    ("language", "SUPERVISOR_REPORT_LANGUAGE", _language, "auto", True,
     "мова, якою воркер починає й пише звіти: auto, en, uk, ru",
     "language the worker starts in and writes reports in: auto, en, uk, ru"),
    ("report.writer", "SUPERVISOR_REPORT_WRITER", _choice(["codex", "claude"]), "codex", True,
     "хто пише підсумковий звіт: codex або claude",
     "who writes the final report: codex or claude"),
    ("collaboration", "SUPERVISOR_COLLABORATION_MODE", _choice(["adaptive_peer", "legacy"]), "adaptive_peer", True,
     "схема роботи Claude і Codex: adaptive_peer або legacy",
     "how Claude and Codex work together: adaptive_peer or legacy"),
    ("permission-mode", "SUPERVISOR_PERMISSION_MODE", _choice(PERMISSION_MODES), "auto", False,
     "режим дозволів Claude: auto, acceptEdits, plan, default, bypassPermissions",
     "Claude permission mode: auto, acceptEdits, plan, default, bypassPermissions"),
    ("branch", "SUPERVISOR_WORK_BRANCH", _branch, "", False,
     "гілка для роботи; порожньо — працювати на поточній",
     "branch to work on; empty works on the current one"),
    ("web", "SUPERVISOR_NO_WEB", _bool, "on", True,
     "чи можуть моделі ходити в інтернет: on або off",
     "whether the models may reach the internet: on or off"),
    ("review.max-rounds", "SUPERVISOR_MAX_ROUNDS", _int_range(1, 50), "3", False,
     "скільки раундів рев'ю дозволено щонайменше",
     "review rounds always allowed"),
    ("review.max-rounds-hard", "SUPERVISOR_MAX_ROUNDS_HARD", _int_range(1, 100), "12", False,
     "абсолютна стеля раундів рев'ю",
     "absolute ceiling on review rounds"),
    ("review.stall-limit", "SUPERVISOR_STALL_LIMIT", _int_range(1, 20), "2", False,
     "раундів без прогресу, після яких прогін чекає людину",
     "rounds without progress before a run waits for a person"),
    ("verify", "SUPERVISOR_VERIFIER_ENABLED", _bool, "on", False,
     "запускати збірку й тести проєкту як доказ: on або off",
     "run the project's build and tests as evidence: on or off"),
    ("usage.guard", "SUPERVISOR_USAGE_GUARD", _int_range(1, 100), "100", False,
     "% п'ятигодинного ліміту, після якого прогін стає на паузу",
     "% of the five-hour window after which a run pauses"),
    ("usage.week-guard", "SUPERVISOR_USAGE_WEEK_GUARD", _int_range(1, 100), "100", False,
     "% тижневого ліміту, після якого прогін стає на паузу",
     "% of the weekly window after which a run pauses"),
    ("idle-kill-hours", "SUPERVISOR_IDLE_KILL_HOURS", _int_range(1, 168), "4", False,
     "годин простою, після яких сесію буде закрито",
     "idle hours after which a session is closed"),
    ("skills.autonomous", "SUPERVISOR_SKILL_AUTONOMOUS", _bool, "on", False,
     "ставити перевірені навички самостійно (on) чи лише пропонувати (off)",
     "install audited skills on its own (on) or only propose them (off)"),
    ("ui.language", None, _ui_language, "uk", False,
     "мова нових команд CLI: uk або en",
     "language of the CLI's own commands: uk or en"),
]
KEY_INDEX = {k[0]: k for k in KEYS}
# Read back from a run's run-env file; the rest only matter when a run starts.
RUN_ENV_VARS = ["SUPERVISOR_CODEX_EFFORT", "SUPERVISOR_CODEX_MODEL", "SUPERVISOR_CLAUDE_EFFORT",
                "SUPERVISOR_CLAUDE_MODEL", "SUPERVISOR_REPORT_LANGUAGE", "SUPERVISOR_REPORT_WRITER",
                "SUPERVISOR_COLLABORATION_MODE", "SUPERVISOR_CONSULT_TIMEOUT", "SUPERVISOR_UNATTENDED",
                "SUPERVISOR_PLAIN_FOLDER", "SUPERVISOR_ALLOW_TOOLS", "SUPERVISOR_NO_WEB"]

ALIASES = {"model": "claude.model", "effort": "claude.effort", "lang": "language",
           "codex-model": "codex.model", "codex-effort": "codex.effort",
           "claude-model": "claude.model", "claude-effort": "claude.effort",
           "permission": "permission-mode", "permissions": "permission-mode"}


def resolve_key(name):
    key = ALIASES.get(name, name)
    if key not in KEY_INDEX:
        die(t("невідомий ключ «%s». Усі ключі: night-shift config keys" % name,
              "unknown key '%s'. All keys: night-shift config keys" % name))
    return key


def parse_value(key, raw):
    try:
        return KEY_INDEX[key][2](raw)
    except ValueError as e:
        die("%s: %s" % (key, e))


def stored(value):
    """What goes into the JSON file: booleans as on/off, numbers as numbers."""
    if value is True:
        return "on"
    if value is False:
        return "off"
    return value


def env_value(key, value):
    """The engine's spelling of a value, or None to leave the engine's own default alone."""
    if key == "web":
        return "" if _bool(value) else "1"
    if key in ("verify", "skills.autonomous"):
        return "1" if _bool(value) else "0"
    if value in ("auto", None):
        return None
    return str(value)


# ───────────────────────────────────────────────────────────────── the file, read and written safely
#
# Two terminals and a queue runner can all touch it at once, so every write takes an exclusive lock
# on a sidecar file, re-reads under that lock, and lands by rename: a reader sees the old file or the
# new one, never half of either.

EMPTY = {"version": 1, "defaults": {}, "projects": {}}


def load_config(path=None):
    path = path or config_path()
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return json.loads(json.dumps(EMPTY))
    except (OSError, ValueError) as e:
        die(t("не читається %s: %s" % (path, e), "cannot read %s: %s" % (path, e)))
    if not isinstance(data, dict):
        die(t("%s — не JSON-об'єкт" % path, "%s is not a JSON object" % path))
    data.setdefault("version", 1)
    if not isinstance(data.get("defaults"), dict):
        data["defaults"] = {}
    if not isinstance(data.get("projects"), dict):
        data["projects"] = {}
    return data


class Locked:
    def __init__(self, path):
        self.path = path + ".lock"
        self.f = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        self.f = open(self.path, "a+")
        if fcntl:
            fcntl.flock(self.f.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        if fcntl and self.f:
            fcntl.flock(self.f.fileno(), fcntl.LOCK_UN)
        if self.f:
            self.f.close()


def atomic_write(path, text, mode=0o600):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def update_config(mutate):
    path = config_path()
    with Locked(path):
        data = load_config(path)
        result = mutate(data)
        # Empty project tables are noise in a file people read.
        data["projects"] = {p: v for p, v in data["projects"].items() if v}
        atomic_write(path, json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    return result


def layer(data, project):
    if project:
        return data["projects"].get(canon(project), {})
    return data["defaults"]


def effective(data, project):
    """key → (value, origin) after defaults and the project's own layer."""
    out = {}
    for key, _env, _p, default, _live, _uk, _en in KEYS:
        out[key] = (default, "default")
        if key in data["defaults"]:
            out[key] = (data["defaults"][key], "global")
        if project:
            proj = data["projects"].get(canon(project), {})
            if key in proj:
                out[key] = (proj[key], "project")
    return out


# ───────────────────────────────────────────────────────────────── model catalogues
#
# The same files the app reads (ClaudeModelCatalog.swift, CodexModelCatalog.swift): each CLI keeps
# its own catalogue fresh, so nothing here has to know which models exist this week.

def claude_catalogue():
    d = os.path.join(claude_config_dir(), "cache", "model-catalog")
    best, best_stamp = None, -1.0
    try:
        names = os.listdir(d)
    except OSError:
        return None
    for name in names:
        if not name.endswith(".json") or name == "published-floor.json":
            continue
        try:
            with open(os.path.join(d, name), "r", encoding="utf-8") as f:
                root = json.load(f)
        except (OSError, ValueError):
            continue
        cat = _decode_claude(root)
        if not cat:
            continue
        stamp = float(root.get("fetchedAt") or 0) if isinstance(root, dict) else 0.0
        if stamp > best_stamp:
            best, best_stamp = cat, stamp
    return best


def _decode_claude(root):
    if not isinstance(root, dict):
        return None
    if isinstance(root.get("documentBytes"), str):
        try:
            return _decode_claude(json.loads(base64.b64decode(root["documentBytes"])))
        except Exception:
            return None
    config, state = None, None
    if isinstance(root.get("catalog"), dict):
        c = root["catalog"]
        if (c.get("surface") or "cc") != "cc":
            return None
        config, state = c.get("config"), c.get("state")
    elif isinstance(root.get("surfaces"), dict):
        cc = root["surfaces"].get("cc") or {}
        configs = cc.get("model_selector_config") or []
        config = next((x for x in configs if x.get("id") == "cc"), configs[0] if configs else None)
        states = cc.get("model_selector_state") or []
        state = next((x for x in states if x.get("id") == "cc"), states[0] if states else None)
    if not isinstance(config, dict) or not isinstance(config.get("models"), list):
        return None
    models = []
    for row in config["models"]:
        mid = row.get("id")
        if not isinstance(mid, str) or not SAFE_NAME.match(mid):
            continue
        offered = row.get("offered_on") or []
        if offered and "first_party" not in offered:
            continue
        runtime = row.get("runtime") or {}
        thinking = row.get("thinking") or {}
        levels = runtime.get("effort_levels") or [o.get("id") for o in thinking.get("effort_options") or []]
        levels = [lv for lv in levels if isinstance(lv, str) and lv]
        badged = next((o.get("id") for o in thinking.get("effort_options") or [] if o.get("badge")), None)
        short = row.get("short_name") or row.get("name") or mid
        models.append({
            "id": mid,
            "name": row.get("name") or mid,
            "family": (runtime.get("family") or short).lower(),
            "current": (row.get("section") or "main") == "main",
            "levels": levels if thinking.get("type") != "none" else [],
            "default_level": runtime.get("default_effort") or badged or "",
            "description": row.get("description") or "",
        })
    if not models:
        return None
    aliases = {}
    table = config.get("provider_alias_targets")
    if isinstance(table, dict):
        for alias, target in table.items():
            tid = (target or {}).get("default") if isinstance(target, dict) else None
            if tid and any(m["id"] == tid for m in models):
                aliases[alias] = tid
    else:
        for m in models:
            if m["current"] and m["family"] not in aliases:
                aliases[m["family"]] = m["id"]
    default = (state or {}).get("model") or ""
    return {"models": models, "aliases": aliases, "default": default}


def codex_catalogue():
    path = os.path.join(codex_home(), "models_cache.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            root = json.load(f)
    except (OSError, ValueError):
        return None
    out = []
    for row in root.get("models") or []:
        slug = row.get("slug")
        if not isinstance(slug, str) or not SAFE_NAME.match(slug):
            continue
        if (row.get("visibility") or "list") != "list":
            continue
        levels = [lv.get("effort") for lv in row.get("supported_reasoning_levels") or [] if lv.get("effort")]
        out.append({"id": slug, "name": row.get("display_name") or slug, "levels": levels,
                    "default_level": row.get("default_reasoning_level") or "",
                    "description": row.get("description") or "",
                    "priority": row.get("priority") if isinstance(row.get("priority"), int) else 1 << 30})
    out.sort(key=lambda m: (m["priority"], m["id"]))
    return {"models": out, "aliases": {}, "default": ""} if out else None


def catalogue(kind):
    return claude_catalogue() if kind == "claude" else codex_catalogue()


def known_model_names(kind):
    cat = catalogue(kind)
    if not cat:
        return set()
    names = {m["id"] for m in cat["models"]} | set(cat["aliases"])
    if kind == "claude":
        names |= {"opus", "sonnet", "haiku", "fable", "opusplan"}
    return names


def catalogue_levels(kind):
    cat = catalogue(kind)
    levels = []
    for m in (cat or {}).get("models", []):
        for lv in m["levels"]:
            if SAFE_NAME.match(lv) and lv not in levels:
                levels.append(lv)
    return levels


def model_levels(kind, model):
    """The effort levels `model` takes on this machine's account, or None when that is not known.

    From the engine's own catalogue — Claude Code's `model-catalog`, Codex's `models_cache.json`.
    Codex's cache is fetched for the signed-in account (it carries the account's `identity`), so
    what it lists is what this subscription may use: `ultra` appears there on the plans that have
    it and not on the others. A level is therefore never assumed to exist just because the CLI
    knows its name (22.10: `ultra` was accepted for a model and a plan that do not offer it).
    `[]` means the model takes no effort at all (Haiku 4.5).
    """
    if model in (None, "", "auto"):
        return None
    cat = catalogue(kind)
    if not cat:
        return None
    mid = cat["aliases"].get(model, model)
    found = next((m for m in cat["models"] if m["id"] == mid), None)
    if found is None and kind == "claude":
        # A family name the catalogue has no alias for: its newest current model.
        found = next((m for m in cat["models"] if m.get("family") == model and m.get("current")), None)
    return None if found is None else list(found["levels"])


def effort_problem(kind, model, effort):
    """Why `effort` does not fit `model`, in words, or None when it fits or cannot be known."""
    if effort in (None, "", "auto"):
        return None
    levels = model_levels(kind, model)
    if levels is None:
        return None
    if not levels:
        if effort == "none":
            return None
        return t("%s не має рівнів глибини — лиши auto або none" % model,
                 "%s takes no effort level — leave it at auto or none" % model)
    if effort == "none" or effort in levels:
        return None
    return t("для %s на цьому акаунті можна: %s" % (model, ", ".join(levels)),
             "%s on this account takes: %s" % (model, ", ".join(levels)))


def best_level(levels, wanted, order):
    """The highest level in `levels` not above `wanted`, by `order`; the lowest one otherwise."""
    rank = {lv: i for i, lv in enumerate(order)}
    target = rank.get(wanted, len(order))
    fitting = [lv for lv in levels if rank.get(lv, -1) <= target]
    return max(fitting, key=lambda lv: rank.get(lv, -1)) if fitting else levels[0]


# ───────────────────────────────────────────────────────────────── commands

def cmd_env(args):
    """What a start should export, one `NAME<TAB>VALUE` per line, for night-shift.sh to read.

    Precedence, highest first: a flag on this start, a variable the caller already exported, the
    project's layer, the global layer. Anything left at `auto` is not printed at all, so the engine's
    own default from supervisor/config.sh stands.
    """
    caller = set((args.caller_set or "").split())
    data = load_config() if args.use_file else json.loads(json.dumps(EMPTY))
    eff = effective(data, args.project)
    flags = {}
    for item in args.set or []:
        if "=" not in item:
            die(t("--set чекає ключ=значення, отримано «%s»" % item, "--set expects key=value, got '%s'" % item))
        k, v = item.split("=", 1)
        k = resolve_key(k.strip())
        flags[k] = stored(parse_value(k, v))
    # A model with no reasoning levels (Haiku 4.5) takes no --effort at all; the app says so with
    # `none`, and so does this, unless somebody named a depth for it on purpose.
    model = flags.get("claude.model", eff["claude.model"][0])
    effort_named = "claude.effort" in flags or eff["claude.effort"][1] != "default"
    if model not in ("auto", None) and not effort_named:
        cat = claude_catalogue()
        if cat:
            mid = cat["aliases"].get(model, model)
            found = next((m for m in cat["models"] if m["id"] == mid), None)
            if found is not None and not found["levels"]:
                flags["claude.effort"] = "none"
    # A level the model does not take on this account any more — the plan changed, the catalogue
    # moved on — is lowered to the nearest one it does take, out loud, rather than handed to the
    # engine to fail on.
    for kind, order in (("claude", CLAUDE_EFFORTS), ("codex", CODEX_EFFORTS)):
        m = flags.get(kind + ".model", eff[kind + ".model"][0])
        e = flags.get(kind + ".effort", eff[kind + ".effort"][0])
        levels = model_levels(kind, m)
        if levels and e not in ("auto", "none", None, "") and e not in levels:
            lowered = best_level(levels, e, order)
            warn(t("%s не бере глибину %s на цьому акаунті — беру %s" % (m, e, lowered),
                   "%s does not take effort %s on this account — using %s" % (m, e, lowered)))
            flags[kind + ".effort"] = lowered
    for key, env, _p, _d, _live, _uk, _en in KEYS:
        if env is None:
            continue
        if key in flags:
            value, from_flag = flags[key], True
        else:
            value, origin = eff[key]
            if origin == "default" or env in caller:
                continue
            from_flag = False
        out = env_value(key, value)
        if out is None:
            if not from_flag:
                continue
            # An explicit `--effort auto` on the command line means "the engine's default", even
            # over a file that says otherwise — so the variable is reset rather than left alone.
            out = "@default@"
        if "\t" in out or "\n" in out:
            die("%s: %s" % (key, t("недопустимий символ", "invalid character")))
        sys.stdout.write("%s\t%s\n" % (env, out))
    return 0


def _print_table(rows, json_out):
    if json_out:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return
    width = max(len(r["key"]) for r in rows) if rows else 0
    for r in rows:
        v = r["value"]
        shown = "" if v is None else str(v)
        origin = {"default": t("типово", "default"), "global": t("глобально", "global"),
                  "project": t("проєкт", "project")}.get(r["origin"], r["origin"])
        print("%-*s  %-24s  %s" % (width, r["key"], shown if shown else '""', origin))


def cmd_config(args):
    action = args.action
    project = args.project
    if action == "path":
        print(config_path())
        return 0
    if action == "keys":
        rows = []
        for key, env, _p, default, live, uk, en in KEYS:
            rows.append({"key": key, "default": default, "env": env, "live": live, "help": t(uk, en)})
        if args.json:
            print(json.dumps(rows, indent=2, ensure_ascii=False))
            return 0
        width = max(len(r["key"]) for r in rows)
        for r in rows:
            mark = " ⟳" if r["live"] else ""
            print("%-*s  %s%s" % (width, r["key"], r["help"], mark))
        print()
        print(t("⟳ — можна змінити й для запущеного прогону: night-shift config set КЛЮЧ ЗНАЧЕННЯ --run [тека]",
                "⟳ — can also change for a running run: night-shift config set KEY VALUE --run [dir]"))
        return 0
    if action in ("list", "show"):
        data = load_config()
        eff = effective(data, project)
        rows = [{"key": k, "value": v, "origin": o} for k, (v, o) in eff.items()]
        if not args.all:
            rows = [r for r in rows if r["origin"] != "default"] or rows
        _print_table(rows, args.json)
        return 0
    if action == "get":
        if not args.key:
            die(t("потрібен ключ: night-shift config get claude.model", "a key is needed: night-shift config get claude.model"))
        key = resolve_key(args.key)
        value, origin = effective(load_config(), project)[key]
        if args.json:
            print(json.dumps({"key": key, "value": value, "origin": origin}, ensure_ascii=False))
        else:
            print(value)
        return 0
    if action == "set":
        if not args.key or args.value is None:
            die(t("використання: night-shift config set КЛЮЧ ЗНАЧЕННЯ [--project ТЕКА]",
                  "usage: night-shift config set KEY VALUE [--project DIR]"))
        key = resolve_key(args.key)
        value = stored(parse_value(key, args.value))
        if key == "permission-mode" and value == "bypassPermissions":
            warn(t("bypassPermissions вимикає всі запити дозволу в Claude — лише для ізольованих машин.",
                   "bypassPermissions turns off every permission prompt in Claude — isolated machines only."))
        if key == "ui.language" and project:
            die(t("ui.language — лише глобальний", "ui.language is global only"))

        if key in ("claude.model", "claude.effort", "codex.model", "codex.effort"):
            kind = key.split(".")[0]
            eff = effective(load_config(), project)
            model = value if key.endswith(".model") else eff[kind + ".model"][0]
            effort = value if key.endswith(".effort") else eff[kind + ".effort"][0]
            problem = effort_problem(kind, model, effort)
            if problem:
                if key.endswith(".effort"):
                    die("%s: %s" % (key, problem))
                warn(t("збережена глибина %s=%s не підходить: %s — на старті візьму найближчу доступну"
                       % (kind + ".effort", effort, problem),
                       "the saved %s=%s does not fit: %s — a start will use the nearest one offered"
                       % (kind + ".effort", effort, problem)))

        def mutate(data):
            target = data["projects"].setdefault(canon(project), {}) if project else data["defaults"]
            target[key] = value
        update_config(mutate)
        where = t("для %s" % canon(project), "for %s" % canon(project)) if project else t("глобально", "globally")
        print("✅ %s = %s  (%s)" % (key, value if value != "" else '""', where))
        print(t("   діятиме з наступного `night-shift start`; застосунок Bulava це не змінює.",
                "   takes effect on the next `night-shift start`; the Bulava app is not affected."))
        return 0
    if action == "unset":
        if not args.key:
            die(t("потрібен ключ", "a key is needed"))
        key = resolve_key(args.key)

        def mutate(data):
            target = data["projects"].get(canon(project), {}) if project else data["defaults"]
            return target.pop(key, None) is not None
        removed = update_config(mutate)
        print(("✅ " + t("прибрано %s", "removed %s") % key) if removed else t("%s і так не задано", "%s was not set") % key)
        return 0
    if action == "reset":
        if not args.yes:
            die(t("це видалить усі налаштування CLI%s. Повтори з --yes" % (" для " + canon(project) if project else ""),
                  "this deletes every CLI setting%s. Repeat with --yes" % (" for " + canon(project) if project else "")))

        def mutate(data):
            if project:
                data["projects"].pop(canon(project), None)
            else:
                data["defaults"] = {}
        update_config(mutate)
        print("✅ " + t("скинуто", "reset"))
        return 0
    if action == "edit":
        path = config_path()
        if not os.path.exists(path):
            update_config(lambda d: None)
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or ("notepad" if os.name == "nt" else "vi")
        rc = subprocess.call(editor + " " + _shell_quote(path), shell=True)
        problems = validate_file(load_config(path))
        for p in problems:
            warn(p)
        if problems:
            print(t("Виправ і перевір: night-shift config check", "Fix them and check: night-shift config check"))
            return 1
        return rc
    if action == "check":
        problems = validate_file(load_config())
        for p in problems:
            warn(p)
        if not problems:
            print("✅ " + t("налаштування коректні: %s" % config_path(), "settings are valid: %s" % config_path()))
        return 1 if problems else 0
    if action == "import-app":
        return import_app(args)
    die(t("невідома дія config: %s" % action, "unknown config action: %s" % action))


def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def validate_file(data):
    problems = []
    layers = [("defaults", data["defaults"])] + [("projects[%s]" % p, v) for p, v in data["projects"].items()]
    for name, values in layers:
        if not isinstance(values, dict):
            problems.append("%s: %s" % (name, t("має бути об'єктом", "must be an object")))
            continue
        for key, value in values.items():
            if key not in KEY_INDEX:
                problems.append("%s.%s: %s" % (name, key, t("невідомий ключ", "unknown key")))
                continue
            try:
                KEY_INDEX[key][2](value)
            except ValueError as e:
                problems.append("%s.%s: %s" % (name, key, e))
    return problems


def read_app_settings(domain):
    """The app's settings blob, from the preferences file the app itself writes.

    The file first: `defaults export` goes through cfprefsd, and from a sandboxed or otherwise
    restricted shell (an agent's, for one) it answered with an old copy — ten keys, no models, a
    state folder of somebody's test — so an import carried nothing but the language (22.10).
    `defaults` is only the fallback for a file that cannot be read.
    """
    path = os.path.expanduser("~/Library/Preferences/%s.plist" % domain)
    prefs = None
    try:
        with open(path, "rb") as f:
            prefs = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        try:
            raw = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, timeout=20).stdout
            prefs = plistlib.loads(raw) if raw else {}
        except Exception as e:
            die(t("не вдалося прочитати налаштування застосунку (%s): %s" % (domain, e),
                  "could not read the app's settings (%s): %s" % (domain, e)))
    blob = (prefs or {}).get("com.nightshift.settings.v1")
    try:
        return json.loads(blob) if blob else None
    except ValueError:
        return None


def import_app(args):
    """Copies the app's own choices into the CLI's global layer — once, and only what fits.

    The app keeps them as a JSON blob under `com.nightshift.settings.v1` in its defaults domain. A
    choice the CLI already has is kept unless --force says otherwise: an import that quietly
    overwrote a terminal setting would be exactly the coupling these two stores exist to avoid.
    """
    if sys.platform != "darwin":
        die(t("застосунок Bulava є лише на macOS — імпортувати нема звідки.",
              "the Bulava app exists only on macOS — there is nothing to import."))
    domain = "stepanok.com.Night-Shift" + (".dev" if args.source == "dev" else "")
    app = read_app_settings(domain)
    if not isinstance(app, dict):
        die(t("застосунок (%s) ще не зберігав налаштувань — відкрий його й зміни будь-що в Settings."
              % domain, "the app (%s) has not saved settings yet — open it and change anything in Settings." % domain), 1)

    langs = {"en": "English", "uk": "Ukrainian", "ru": "Russian"}
    wanted = {}
    skipped = []

    def take(key, raw_value, mapped=None):
        if raw_value in (None, "", "auto", "system"):
            return
        value = mapped if mapped is not None else raw_value
        try:
            wanted[key] = stored(KEY_INDEX[key][2](value))
        except ValueError as e:
            skipped.append("%s=%s (%s)" % (key, raw_value, e))

    take("claude.model", app.get("claudeModel"))
    take("claude.effort", app.get("claudeEffort"))
    take("codex.model", app.get("codexModel"))
    take("codex.effort", app.get("codexEffort"))
    rl = app.get("reportLanguage")
    if rl in langs:
        take("language", rl, langs[rl])
    take("report.writer", app.get("reportWriter"))

    data = load_config()
    changes, kept = {}, {}
    for k, v in wanted.items():
        cur = data["defaults"].get(k)
        if cur is not None and cur != v and not args.force:
            kept[k] = (cur, v)
        elif cur != v:
            changes[k] = v

    if not wanted:
        print(t("У застосунку всюди «Автоматично» — переносити нічого.",
                "The app is on Automatic everywhere — nothing to carry over."))
    for k, v in sorted(changes.items()):
        print("  + %s = %s" % (k, v))
    for k, (cur, v) in sorted(kept.items()):
        print("  = %s = %s  %s" % (k, cur, t("(лишаю твоє; у застосунку %s — --force, щоб замінити)" % v,
                                           "(kept yours; the app has %s — --force to replace)" % v)))
    for s in skipped:
        print("  ! " + t("пропущено ", "skipped ") + s)

    state = app.get("stateDirPath")
    mine = state_dir()
    if isinstance(state, str) and state and os.path.isdir(state) and canon(state) != canon(mine):
        warn(t("застосунок дивиться в інший стан: %s (CLI — %s). Щоб бачити ті самі прогони, "
               "export SUPERVISOR_STATE_DIR=%s" % (state, mine, _shell_quote(state)),
               "the app looks at another state dir: %s (CLI: %s). To see the same runs, "
               "export SUPERVISOR_STATE_DIR=%s" % (state, mine, _shell_quote(state))))

    if args.dry_run or not changes:
        if args.dry_run:
            print(t("(--dry-run: нічого не записано)", "(--dry-run: nothing written)"))
        return 0

    def mutate(d):
        d["defaults"].update(changes)
    update_config(mutate)
    print("✅ " + t("імпортовано в %s" % config_path(), "imported into %s" % config_path()))
    return 0


def cmd_models(args):
    kinds = [args.kind] if args.kind else ["claude", "codex"]
    result = {}
    for kind in kinds:
        result[kind] = catalogue(kind)
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    data = load_config()
    eff = effective(data, args.project)
    for kind in kinds:
        cat = result[kind]
        chosen = eff["%s.model" % kind][0]
        print(("Claude" if kind == "claude" else "Codex") + "  " + t("(обрано: %s)" % chosen, "(chosen: %s)" % chosen))
        if not cat:
            where = os.path.join(claude_config_dir(), "cache", "model-catalog") if kind == "claude" \
                else os.path.join(codex_home(), "models_cache.json")
            print("  " + t("каталогу немає (%s). Запусти `%s` хоч раз — він його завантажить."
                           % (where, kind), "no catalogue (%s). Run `%s` once and it will fetch one." % (where, kind)))
            if kind == "claude":
                print("  " + t("Аліаси завжди працюють: opus, sonnet, haiku, fable", "Aliases always work: opus, sonnet, haiku, fable"))
            print()
            continue
        for m in cat["models"]:
            mark = "●" if chosen in (m["id"],) or cat["aliases"].get(chosen) == m["id"] else " "
            old = "" if m.get("current", True) else t("  (попередня)", "  (previous)")
            levels = ", ".join(m["levels"]) if m["levels"] else t("без рівнів глибини", "no depth levels")
            dflt = (" [" + t("типово ", "default ") + m["default_level"] + "]") if m["default_level"] else ""
            print("  %s %-27s %s%s" % (mark, m["id"], m["name"], old))
            print("      %s%s" % (levels, dflt))
        if cat["aliases"]:
            print("  " + t("аліаси: ", "aliases: ") + ", ".join("%s→%s" % kv for kv in sorted(cat["aliases"].items())))
        print()
    return 0


# ───────────────────────────────────────────────────────────────── live run settings

def run_env_read(idir):
    out = {}
    try:
        with open(os.path.join(idir, "run-env"), "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^export (SUPERVISOR_[A-Z_]+)='(.*)'$", line.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2).replace("'\\''", "'")
    except OSError:
        pass
    return out


def cmd_run_set(args):
    """Changes a running run's choices in its run-env file, which every later Codex call reloads.

    The worker's own Claude was launched with its flags and cannot change them from outside; inside
    the session `/model` does that. So only the keys marked live are accepted here.
    """
    idir = args.idir
    if not os.path.isdir(idir):
        die(t("прогону немає: %s" % idir, "no such run: %s" % idir), 1)
    changes = {}
    for k, v in zip(args.pairs[0::2], args.pairs[1::2]):
        key = resolve_key(k)
        if not KEY_INDEX[key][4]:
            die(t("%s не змінюється на ходу — він діє з наступного старту%s" %
                  (key, "; у самій сесії Claude: /model" if key.startswith("claude.") else ""),
                  "%s cannot change mid-run — it applies from the next start%s" %
                  (key, "; inside the Claude session: /model" if key.startswith("claude.") else "")))
        value = env_value(key, stored(parse_value(key, v)))
        changes[KEY_INDEX[key][1]] = "" if value is None else value
    if len(args.pairs) % 2:
        die(t("потрібні пари КЛЮЧ ЗНАЧЕННЯ", "KEY VALUE pairs are needed"))
    path = os.path.join(idir, "run-env")
    with Locked(path):
        current = run_env_read(idir)
        current.update(changes)
        lines = ["# generated by run_env_save — the director's choices for this run"]
        for name in RUN_ENV_VARS:
            lines.append("export %s=%s" % (name, _shell_quote(current.get(name, ""))))
        atomic_write(path, "\n".join(lines) + "\n", mode=0o644)
    for name, value in changes.items():
        print("✅ %s=%s" % (name, value if value else '""'))
    origin = _read(os.path.join(idir, "origin"))
    if origin == "app":
        warn(t("цей прогін запустив застосунок — його наступне повідомлення знову запише свій вибір.",
               "the app started this run — its next message will write its own choices again."))
    return 0


# ───────────────────────────────────────────────────────────────── status, machine-readable

def _read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def _alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, OSError):
        return False


def _tmux_has(session):
    if not session or not shutil.which("tmux"):
        return False
    sock = os.environ.get("SUPERVISOR_TMUX_SOCKET", "")
    base = ["tmux", "-L", sock] if sock else ["tmux"]
    return subprocess.run(base + ["has-session", "-t", session], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def instances():
    root = os.path.join(state_dir(), "instances")
    out = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for slug in names:
        d = os.path.join(root, slug)
        project = _read(os.path.join(d, "project"))
        if not project:
            continue
        env = run_env_read(d)
        session = _read(os.path.join(d, "session"))
        started = None
        try:
            started = int(os.path.getmtime(os.path.join(d, "started-at")))
        except OSError:
            pass
        out.append({
            "slug": slug,
            "project": project,
            "session": session,
            "branch": _read(os.path.join(d, "branch")) or None,
            "origin": _read(os.path.join(d, "origin")) or "unknown",
            "run_id": _read(os.path.join(d, "run-id")) or None,
            "watchdog_alive": _alive(_read(os.path.join(d, "watchdog.pid"))),
            "tmux": _tmux_has(session),
            "paused": os.path.exists(os.path.join(d, "paused-for-limit.json")),
            "started_at": started,
            "claude": {"model": env.get("SUPERVISOR_CLAUDE_MODEL") or "auto",
                       "effort": env.get("SUPERVISOR_CLAUDE_EFFORT") or "auto"},
            "codex": {"model": env.get("SUPERVISOR_CODEX_MODEL") or "auto",
                      "effort": env.get("SUPERVISOR_CODEX_EFFORT") or "auto"},
        })
    return out


def cmd_status_json(args):
    usage = None
    try:
        with open(os.path.join(state_dir(), "usage.json"), "r", encoding="utf-8") as f:
            usage = json.load(f)
    except (OSError, ValueError):
        pass
    print(json.dumps({"state_dir": state_dir(), "instances": instances(), "usage": usage},
                     indent=2, ensure_ascii=False))
    return 0


# ───────────────────────────────────────────────────────────────── doctor

def _version(cmd):
    exe = shutil.which(cmd[0])
    if not exe:
        return None
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        line = (r.stdout or r.stderr).strip().splitlines()
        return line[0] if line else "?"
    except Exception:
        return "?"


def platform_name():
    if sys.platform == "darwin":
        return "macOS " + platform.mac_ver()[0]
    if sys.platform.startswith("linux"):
        rel = platform.release().lower()
        wsl = "microsoft" in rel or os.environ.get("WSL_DISTRO_NAME")
        name = "Linux"
        try:
            with open("/etc/os-release") as f:
                for line in f:
                    if line.startswith("PRETTY_NAME="):
                        name = line.split("=", 1)[1].strip().strip('"')
        except OSError:
            pass
        return name + (" (WSL2: %s)" % os.environ.get("WSL_DISTRO_NAME", "?") if wsl else "")
    return sys.platform


# ── doctor for a server
#
# What a bridge asks before it hands the machine a task, and every few minutes after: a stable JSON
# shape with names that never change language, a non-zero exit only when something would break a
# run. It starts nothing and writes nothing — no probe file, no tmux server, no model call. Network
# reachability is a separate, explicit question (`--network`): a doctor that phones out on every
# poll is a doctor whose answer depends on the weather.

def _run(cmd, timeout=20, env=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env,
                           stdin=subprocess.DEVNULL)
        return r.returncode, (r.stdout or ""), (r.stderr or "")
    except FileNotFoundError:
        return 127, "", "not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"


def _engine_bin():
    return os.path.dirname(os.path.abspath(__file__))


def _lib_call(snippet, *argv, timeout=30):
    """A function of supervisor-lib.sh, asked through bash, with its arguments passed as arguments.
    Only when the state directory already exists: sourcing the library makes a folder or two inside
    it, and on a state that is there that is a no-op — on one that is not, doctor has already said so
    and asks nothing more."""
    if not os.path.isdir(state_dir()):
        return 1, ""
    lib = os.path.join(_engine_bin(), "supervisor-lib.sh")
    rc, out, _ = _run(["bash", "-c", '__lib="$1"; shift; . "$__lib" >/dev/null 2>&1; ' + snippet, "doctor", lib] + list(argv),
                      timeout=timeout)
    return rc, out


def _usage_check(name, path, stale_after):
    try:
        with open(path, "r", encoding="utf-8") as f:
            u = json.load(f)
    except (OSError, ValueError):
        return {"name": name, "status": "warn", "detail": {"five_hour_used": None, "seven_day_used": None,
                                                           "note": "no reading yet — the window is unknown"}}
    ts = u.get("observed_at") or u.get("ts") or 0
    age = int(time.time()) - int(ts or 0)
    five = (u.get("five_hour") or {}).get("used_percentage")
    week = (u.get("seven_day") or {}).get("used_percentage")
    detail = {"age_seconds": age, "five_hour_used": five, "seven_day_used": week}
    if age > stale_after:
        detail.update({"five_hour_used": None, "seven_day_used": None, "note": "stale reading — the window is unknown"})
        return {"name": name, "status": "warn", "detail": detail}
    worst = max([v for v in (five, week) if isinstance(v, (int, float))] or [0])
    return {"name": name, "status": "warn" if worst >= 100 else "ok", "detail": detail}


def _trusted(d):
    try:
        cfg = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~"), ".claude.json")
        with open(cfg, "r", encoding="utf-8") as f:
            pr = (json.load(f).get("projects") or {})
    except (OSError, ValueError):
        return False
    keys = {d, d[len("/private"):] if d.startswith("/private/") else d}
    return any((pr.get(k) or {}).get("hasTrustDialogAccepted") for k in keys)


def cmd_doctor_server(args):
    checks = []

    def add(name, status, detail=""):
        checks.append({"name": name, "status": status, "detail": detail})

    # programs
    for tool in ("bash", "git", "jq", "tmux", "python3", "perl", "openssl", "curl", "claude", "codex"):
        cmd = [tool, "-V"] if tool == "tmux" else ([tool, "version"] if tool == "openssl" else [tool, "--version"])
        v = _version(cmd)
        add("bin." + tool, "ok" if v else "fail", v or "not found")
    major = _version(["bash", "-c", "echo ${BASH_VERSINFO[0]}"])
    if major and major.isdigit() and int(major) < 4:
        add("bin.bash.version", "warn", "bash %s — 4 or newer expected" % major)

    # the profile, and the switches it implies
    prof = os.environ.get("SUPERVISOR_PROFILE", "")
    add("engine.profile", "ok" if prof == "server" else "warn",
        prof or "not set — SUPERVISOR_PROFILE=server expected on a server")
    policy = os.environ.get("SUPERVISOR_CODEX_UNAVAILABLE", "fail" if prof == "server" else "")
    add("engine.codex_policy", "ok" if policy in ("wait", "fail") else "warn",
        {"policy": policy or None, "after_hours": os.environ.get("SUPERVISOR_CODEX_UNAVAILABLE_AFTER_HOURS", "3")})
    checks_on = os.environ.get("SUPERVISOR_CLAUDE_CHECKS", "1" if prof == "server" else "0") == "1"
    add("engine.claude_checks", "ok" if checks_on or prof != "server" else "warn",
        {"enabled": checks_on, "list": os.environ.get("SUPERVISOR_CLAUDE_CHECKS_LIST", "code security").split(),
         "min_severity": os.environ.get("SUPERVISOR_CLAUDE_CHECKS_MIN_SEVERITY", "high"),
         "rounds": os.environ.get("SUPERVISOR_CLAUDE_CHECKS_ROUNDS", "1"),
         "required": os.environ.get("SUPERVISOR_CLAUDE_CHECKS_REQUIRED", "0") == "1"})

    # sign-in
    if shutil.which("claude"):
        rc, out, err = _run(["claude", "auth", "status", "--json"], timeout=30)
        try:
            st = json.loads(out)
            add("auth.claude", "ok" if st.get("loggedIn") else "fail",
                {"logged_in": bool(st.get("loggedIn")), "method": st.get("authMethod"),
                 "subscription": st.get("subscriptionType"),
                 "token_env": bool(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"))})
        except ValueError:
            add("auth.claude", "warn", "claude auth status gave no JSON (rc %s): %s" % (rc, (err or out).strip()[:200]))
        for var in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
            if os.environ.get(var):
                add("auth.claude.paid_env", "warn", "%s is set; workers strip it to stay on the subscription" % var)
    if shutil.which("codex"):
        rc, out, err = _run(["codex", "login", "status"], timeout=30)
        add("auth.codex", "ok" if rc == 0 else "fail", ((out or err).strip().splitlines() or ["?"])[0][:200])

    # limits, as last read — never refreshed from here
    sd = state_dir()
    stale = int(os.environ.get("SUPERVISOR_USAGE_STALE_SECS", "1800") or 1800)
    checks.append(_usage_check("usage.claude", os.path.join(sd, "usage.json"), stale))
    checks.append(_usage_check("usage.codex", os.path.join(sd, "codex-usage.json"), stale))

    # the engine itself
    if not os.path.isdir(sd):
        add("engine.state", "fail", "%s does not exist — run install.sh" % sd)
    else:
        add("engine.state", "ok", sd)
        ws = os.path.join(sd, "worker-settings.json")
        try:
            with open(ws, "r", encoding="utf-8") as f:
                txt = f.read()
            hooks = (json.loads(txt).get("hooks") or {})
            cmds = [h.get("command", "") for groups in hooks.values() for g in (groups or [])
                    for h in (g.get("hooks") or []) if isinstance(h, dict)]
            paths = set()
            for c in cmds:
                try:
                    first = shlex.split(c)[0] if c else ""
                except ValueError:
                    first = c
                if "/hooks/" in first:
                    paths.add(first)
            missing = sorted(m for m in paths if not os.path.isfile(m))
            add("engine.hooks", "fail" if missing else "ok", {"settings": ws, "missing": missing})
        except (OSError, ValueError) as e:
            add("engine.hooks", "fail", "%s: %s" % (ws, e))
        rc, out = _lib_call("engine_protocol_gap")
        add("engine.protocol", "fail" if rc == 0 and out.strip() else "ok",
            out.strip() or "the installed gate matches this library")
        deg = os.path.join(sd, "degraded.md")
        add("engine.degraded", "warn" if os.path.exists(deg) else "ok", deg if os.path.exists(deg) else "")
        # Waiting is not breakage: a run on a question or a parked pause is reported, as a warning.
        waiting = {}
        inst = os.path.join(sd, "instances")
        for slug in (sorted(os.listdir(inst)) if os.path.isdir(inst) else []):
            for marker in ("codex-decision", "ask-user", "paused-for-limit", "stalled"):
                if os.path.exists(os.path.join(inst, slug, marker + ".json")):
                    waiting.setdefault(marker, []).append(slug)
        add("runs.waiting", "warn" if waiting else "ok", waiting)
        try:
            fs = os.statvfs(sd)
            free = fs.f_bavail * fs.f_frsize
            add("disk.state", "fail" if free < 512 * 2**20 else ("warn" if free < 4 * 2**30 else "ok"),
                {"path": sd, "free_bytes": free})
        except OSError as e:
            add("disk.state", "warn", str(e))

    # the headless browser
    mcp_cfg = os.environ.get("SUPERVISOR_AUTOMATION_MCP_CONFIG") \
        or os.path.join(_engine_bin(), "..", "supervisor", "automation-mcp.json")
    try:
        with open(mcp_cfg, "r", encoding="utf-8") as f:
            b = (json.load(f).get("mcpServers") or {}).get("browser") or {}
        cmd = b.get("command") or ""
        found = bool(cmd) and (shutil.which(cmd) or os.path.isfile(cmd))
        add("browser.mcp", "warn" if cmd == "npx" else ("ok" if found else "fail"),
            {"config": os.path.abspath(mcp_cfg), "command": cmd,
             "note": "npx fetches the server on every start" if cmd == "npx" else ""})
    except (OSError, ValueError) as e:
        add("browser.mcp", "warn", str(e))
    if sys.platform != "darwin":
        chrome = "/opt/google/chrome/chrome" if os.path.isfile("/opt/google/chrome/chrome") else next(
            (shutil.which(c) for c in ("google-chrome-stable", "google-chrome", "chromium", "chromium-browser")
             if shutil.which(c)), None)
        add("browser.chrome", "ok" if chrome else "warn", chrome or "no Chrome or Chromium — runs go without a browser")

    # one project, and the extra repositories it is given
    if getattr(args, "dir", None):
        dirs = [canon(args.dir)]
        extra = os.environ.get("SUPERVISOR_EXTRA_DIRS_FILE")
        if extra and os.path.isfile(extra):
            with open(extra, "r", encoding="utf-8") as f:
                dirs += [canon(l.strip()) for l in f if l.strip()]
        for i, d in enumerate(dirs):
            tag = "project" if i == 0 else "project.extra[%d]" % (i - 1)
            if not os.path.isdir(d):
                add(tag, "fail", "%s does not exist" % d)
                continue
            rc, top, _ = _run(["git", "-C", d, "rev-parse", "--show-toplevel"], timeout=15)
            add(tag + ".git", "ok" if rc == 0 and canon(top.strip()) == d else "fail",
                d if rc == 0 else "not a git repository (a start would stop with 76)")
            rc, out, _ = _run(["git", "-C", d, "status", "--porcelain"], timeout=30)
            add(tag + ".clean", "ok" if rc == 0 and not out.strip() else "fail",
                "clean" if not out.strip() else "uncommitted work (a start would stop with 77): " + " ".join(out.split()[:8]))
            t = _trusted(d)
            add(tag + ".trusted", "ok" if t else "fail", "trusted" if t else "Claude would ask — run: night-shift trust " + d)
            if i == 0:
                rc, out = _lib_call('project_mcp_pending "$(canon_path "$1")"', d)
                pend = [x for x in out.split("\n") if x.strip()]
                add(tag + ".mcp", "fail" if pend else "ok",
                    {"pending": pend, "fix": "night-shift mcp-decide %s enable|skip" % d} if pend else "decided")
                rc, out = _lib_call('workspace_container_reason "$1"', d)
                add(tag + ".folder", "fail" if rc == 0 else "ok",
                    out.strip()[:300] if rc == 0 else "a project, not a folder of projects")

    # One real request to each model, only when asked: a token that is present but revoked or
    # expired looks signed in to `auth status` and fails here. It costs a few tokens, so a bridge asks
    # for it before taking work, not on every poll.
    if getattr(args, "probe", False):
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")}
        if shutil.which("claude"):
            rc, out, err = _run(["claude", "-p", "Reply with the single word OK.", "--output-format", "json",
                                 "--max-turns", "1"], timeout=120, env=env)
            try:
                r = json.loads(out)
                good = rc == 0 and not r.get("is_error")
                add("probe.claude", "ok" if good else "fail",
                    (r.get("result") or "")[:200] if good else (r.get("result") or err or out).strip()[:300])
            except ValueError:
                add("probe.claude", "fail", "rc %s: %s" % (rc, (err or out).strip()[:300]))
        if shutil.which("codex"):
            rc, out, err = _run(["codex", "exec", "--skip-git-repo-check", "-c", 'model_reasoning_effort="low"',
                                 "Reply with the single word OK."],
                                timeout=180, env=env)
            add("probe.codex", "ok" if rc == 0 else "fail",
                "answered" if rc == 0 else "rc %s: %s" % (rc, (err or out).strip()[-300:]))

    if getattr(args, "network", False):
        for name, url in (("network.anthropic", "https://api.anthropic.com"), ("network.openai", "https://api.openai.com")):
            rc, out, err = _run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "8", url], timeout=12)
            add(name, "ok" if rc == 0 and out.strip() not in ("", "000") else "fail", out.strip() or err.strip()[:200])

    ok = not any(c["status"] == "fail" for c in checks)
    print(json.dumps({"ok": ok, "schema": 1, "checks": checks}, ensure_ascii=False, indent=None if args.json else 2))
    return 0 if ok else 1


def cmd_doctor(args):
    checks = []

    def add(ok, what, detail="", fix="", level="error"):
        checks.append({"ok": ok, "what": what, "detail": detail, "fix": fix, "level": "ok" if ok else level})

    is_mac = sys.platform == "darwin"
    pkg = "brew install" if is_mac else "sudo apt install -y"
    add(True, t("платформа", "platform"), platform_name())
    bash_v = _version(["bash", "-c", "echo $BASH_VERSION"])
    add(bool(bash_v), "bash", bash_v or "", "%s bash" % pkg)
    for tool, pkgname in (("git", "git"), ("jq", "jq"), ("tmux", "tmux"), ("curl", "curl")):
        v = _version([tool, "--version"] if tool != "tmux" else ["tmux", "-V"])
        add(bool(v), tool, v or t("не знайдено", "not found"), "%s %s" % (pkg, pkgname))
    add(sys.version_info >= (3, 8), "python3", platform.python_version(), "%s python3" % pkg)
    cv = _version(["claude", "--version"])
    add(bool(cv), "claude", cv or t("не знайдено", "not found"), "https://claude.ai/code")
    xv = _version(["codex", "--version"])
    add(bool(xv), "codex", xv or t("не знайдено", "not found"), "https://developers.openai.com/codex/cli",
        level="warn")

    sd = state_dir()
    try:
        os.makedirs(sd, exist_ok=True)
        probe = os.path.join(sd, ".doctor-probe")
        open(probe, "w").close()
        os.unlink(probe)
        add(True, t("тека стану", "state dir"), sd)
    except OSError as e:
        add(False, t("тека стану", "state dir"), "%s: %s" % (sd, e))

    local_bin = os.path.join(os.path.expanduser("~"), ".local", "bin")
    on_path = local_bin in os.environ.get("PATH", "").split(os.pathsep)
    add(on_path, "~/.local/bin " + t("у PATH", "on PATH"), "",
        'export PATH="$HOME/.local/bin:$PATH"', level="warn")

    settings = os.path.join(claude_config_dir(), "settings.json")
    engine = os.environ.get("NIGHT_SHIFT_ROOT", "")
    hooked = False
    try:
        with open(settings, "r", encoding="utf-8") as f:
            text = f.read()
        hooked = "statusline.sh" in text or "night-shift" in text or (engine and engine in text)
    except OSError:
        pass
    add(hooked, t("хуки Claude Code", "Claude Code hooks"), settings, "bash %s/install.sh" % (engine or "~/.night-shift"),
        level="warn")

    problems = validate_file(load_config())
    add(not problems, t("налаштування CLI", "CLI settings"), config_path() if not problems else "; ".join(problems),
        "night-shift config edit")

    if is_mac:
        app = None
        for cand in ("/Applications/Bulava.app", os.path.expanduser("~/Applications/Bulava.app")):
            if os.path.isdir(cand):
                app = cand
        add(True, t("застосунок Bulava", "Bulava app"), app or t("не встановлено (CLI працює і без нього)",
                                                               "not installed (the CLI works without it)"))
        app_engine = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "Bulava", "engine")
        if os.path.isfile(os.path.join(app_engine, "bin", "verify.sh")) and engine:
            same = canon(engine) == canon(app_engine)
            dev_checkout = os.path.isdir(os.path.join(engine, "..", ".git"))
            add(same or dev_checkout, t("один движок із застосунком", "one engine with the app"),
                engine if same else t("термінал: %s, застосунок: %s" % (engine, app_engine),
                                      "terminal: %s, app: %s" % (engine, app_engine)),
                t("перевстанови: curl -fsSL https://bulava.app/install.sh | bash  (візьме движок застосунку)",
                  "reinstall: curl -fsSL https://bulava.app/install.sh | bash  (it will use the app's engine)"),
                level="warn")
        if app:
            try:
                raw = subprocess.run(["defaults", "export", "stepanok.com.Night-Shift", "-"],
                                     capture_output=True, timeout=10).stdout
                blob = plistlib.loads(raw).get("com.nightshift.settings.v1") if raw else None
                app_state = (json.loads(blob) or {}).get("stateDirPath") if blob else None
            except Exception:
                app_state = None
            if app_state and os.path.isdir(app_state) and canon(app_state) != canon(sd):
                add(False, t("спільний стан із застосунком", "state shared with the app"),
                    t("застосунок: %s, CLI: %s" % (app_state, sd), "app: %s, CLI: %s" % (app_state, sd)),
                    "export SUPERVISOR_STATE_DIR=%s" % _shell_quote(app_state), level="warn")
            else:
                add(True, t("спільний стан із застосунком", "state shared with the app"), sd)
    else:
        if "WSL" in platform_name() and os.getcwd().startswith("/mnt/"):
            add(False, t("тека проєкту у WSL", "project folder in WSL"),
                t("%s лежить на диску Windows — git і збірка там у рази повільніші, а права файлів губляться"
                  % os.getcwd(), "%s is on the Windows drive — git and builds are many times slower there "
                  "and file modes are lost" % os.getcwd()),
                t("тримай проєкти у файловій системі Linux, напр. ~/code, і відкривай їх з Windows як \\\\wsl$\\",
                  "keep projects on the Linux file system, e.g. ~/code, and open them from Windows via \\\\wsl$\\"),
                level="warn")
        add(False, t("знімки екрана", "screenshots"),
            t("недоступні поза macOS-застосунком — прогони, що доводять UI знімком, лишаться без нього",
              "unavailable outside the macOS app — runs that prove a UI with a screenshot go without"),
            level="warn")

    if args.json:
        print(json.dumps(checks, indent=2, ensure_ascii=False))
    else:
        for c in checks:
            icon = {"ok": "✅", "warn": "⚠️ ", "error": "❌"}[c["level"]]
            line = "%s %s" % (icon, c["what"])
            if c["detail"]:
                line += " — " + c["detail"]
            print(line)
            if not c["ok"] and c["fix"]:
                print("     → " + c["fix"])
    return 1 if any(c["level"] == "error" for c in checks) else 0


# ───────────────────────────────────────────────────────────────── help and completion
#
# One table of commands feeds `help`, the usage line and all four completion scripts, so a new
# command cannot appear in one and be missing from another.

COMMANDS = [
    ("start", "[DIR] [--model M] [--effort E] [--codex-model M] [--codex-effort E] [--lang L] "
              "[--permission-mode P] [--branch B] [--no-web] [--set KEY=VALUE] [--no-attach] [--dirty=keep|commit]",
     "запустити роботу в проєкті (типово — поточна тека)", "start work in a project (default: current dir)"),
    ("stop", "[DIR|--all] [--yes]", "зупинити роботу", "stop work"),
    ("status", "[--json]", "що зараз працює", "what is running now"),
    ("attach", "[DIR]", "під'єднатися до сесії (Ctrl-b d — від'єднатися)", "attach to the session (Ctrl-b d to detach)"),
    ("list", "", "сесії й проєкти одним рядком", "sessions and projects, one per line"),
    ("config", "list|get|set|unset|keys|edit|check|reset|path|import-app …",
     "налаштування CLI: моделі, глибина, мова, рев'ю", "CLI settings: models, effort, language, review"),
    ("models", "[claude|codex] [--json]", "які моделі доступні на цій машині", "which models this machine can use"),
    ("doctor", "[--json]", "перевірити встановлення й залежності", "check the install and its dependencies"),
    ("completion", "bash|zsh|fish|powershell", "скрипт автодоповнення для оболонки", "shell completion script"),
    ("revive", "[DIR]", "підняти впалу сесію на місці", "bring a dead session back in place"),
    ("dirty-state", "[DIR]", "чи є незакомічені зміни", "whether there are uncommitted changes"),
    ("mcp-decide", "DIR enable|skip", "увімкнути чи пропустити MCP-сервери проєкту", "enable or skip a project's MCP servers"),
    ("task", "show|events|list --task-id ID", "задача, яку назвав міст: стан, спроби, події", "a bridge's task: state, attempts, events"),
    ("trust", "DIR [DIR…]", "заздалегідь позначити теки довіреними для Claude (сервер)", "mark folders trusted for Claude beforehand (server)"),
    ("version", "", "версія й шляхи", "version and paths"),
    ("uninstall", "[--force]", "прибрати CLI з машини (стан лишається)", "remove the CLI (state is kept)"),
    ("help", "[COMMAND]", "ця довідка", "this help"),
]

CONFIG_ACTIONS = ["list", "get", "set", "unset", "keys", "edit", "check", "reset", "path", "import-app"]

DETAIL = {
    "config": (
        """Налаштування CLI живуть у %(path)s і НЕ впливають на застосунок Bulava.

  night-shift config list [--all] [--json] [--project ТЕКА]
  night-shift config get КЛЮЧ [--project ТЕКА]
  night-shift config set КЛЮЧ ЗНАЧЕННЯ [--project ТЕКА]     глобально або лише для проєкту
  night-shift config set КЛЮЧ ЗНАЧЕННЯ --run [ТЕКА]         для запущеного прогону (ключі з ⟳)
  night-shift config unset КЛЮЧ [--project ТЕКА]
  night-shift config keys                                   усі ключі й значення
  night-shift config edit | check | path
  night-shift config reset [--project ТЕКА] --yes
  night-shift config import-app [--dry-run] [--force] [--from dev]   (macOS) узяти вибір із застосунку

Пріоритет: прапорець start > змінна SUPERVISOR_* > проєкт > глобально > типово.

  night-shift config set claude.model opus
  night-shift config set claude.effort max --project ~/code/app
  night-shift config set codex.effort xhigh --run .""",
        """CLI settings live in %(path)s and do NOT affect the Bulava app.

  night-shift config list [--all] [--json] [--project DIR]
  night-shift config get KEY [--project DIR]
  night-shift config set KEY VALUE [--project DIR]          globally or for one project
  night-shift config set KEY VALUE --run [DIR]              for a running run (⟳ keys)
  night-shift config unset KEY [--project DIR]
  night-shift config keys                                   every key and its values
  night-shift config edit | check | path
  night-shift config reset [--project DIR] --yes
  night-shift config import-app [--dry-run] [--force] [--from dev]   (macOS) copy the app's choices

Precedence: start flag > SUPERVISOR_* variable > project > global > default.

  night-shift config set claude.model opus
  night-shift config set claude.effort max --project ~/code/app
  night-shift config set codex.effort xhigh --run ."""),
    "start": (
        """Запускає Claude у tmux для проєкту; Codex рев'юїть, доки робота не прийнята.

  --model M            модель Claude (opus, sonnet, fable, haiku або id)
  --effort E           глибина Claude: none, low, medium, high, xhigh, max, ultracode
  --codex-model M      модель Codex
  --codex-effort E     глибина Codex: low, medium, high, xhigh, max, ultra
  --lang L             мова звітів: en, uk, ru
  --permission-mode P  auto, acceptEdits, plan, default, bypassPermissions
  --branch B           працювати в гілці B (створить, якщо нема)
  --no-web             без інтернету для обох моделей
  --set КЛЮЧ=ЗНАЧЕННЯ  будь-який ключ із `night-shift config keys`
  --no-attach          не під'єднуватися до сесії
  --dirty=keep|commit  що робити з незакоміченими змінами

Прапорці діють лише на цей старт. Постійно — через `night-shift config set`.""",
        """Starts Claude in tmux for a project; Codex reviews until the work is accepted.

  --model M            Claude model (opus, sonnet, fable, haiku or an id)
  --effort E           Claude depth: none, low, medium, high, xhigh, max, ultracode
  --codex-model M      Codex model
  --codex-effort E     Codex depth: low, medium, high, xhigh, max, ultra
  --lang L             report language: en, uk, ru
  --permission-mode P  auto, acceptEdits, plan, default, bypassPermissions
  --branch B           work on branch B (created if missing)
  --no-web             no internet for either model
  --set KEY=VALUE      any key from `night-shift config keys`
  --no-attach          do not attach to the session
  --dirty=keep|commit  what to do with uncommitted changes

Flags apply to this start only. To keep them, use `night-shift config set`."""),
    "stop": (
        """Зупиняє роботу в теці (типово — поточна) або всю (--all).
Прогін, який запустив застосунок Bulava, у терміналі зупиняється лише після підтвердження
(або з --yes) — щоб випадково не обірвати чужу розмову.""",
        """Stops work in a dir (default: current) or everywhere (--all).
A run the Bulava app started is stopped from a terminal only after a confirmation
(or with --yes), so a conversation in the app is not cut off by accident."""),
}


def cmd_help(args):
    topic = args.topic
    if topic:
        entry = next((c for c in COMMANDS if c[0] == topic), None)
        if not entry:
            die(t("невідома команда: %s" % topic, "unknown command: %s" % topic))
        print("night-shift %s %s" % (entry[0], entry[1]))
        print()
        detail = DETAIL.get(topic)
        if detail:
            print(t(detail[0], detail[1]) % {"path": config_path()})
        else:
            print(t(entry[2], entry[3]))
        return 0
    print(t("night-shift — рушій Bulava в терміналі: Claude працює, Codex перевіряє.",
            "night-shift — the Bulava engine in a terminal: Claude works, Codex reviews."))
    print()
    print(t("Використання:", "Usage:") + " night-shift <command> [options]")
    print()
    width = max(len(c[0]) for c in COMMANDS)
    for name, _usage, uk, en in COMMANDS:
        print("  %-*s  %s" % (width, name, t(uk, en)))
    print()
    # The engine's own plumbing, which the app and the queue call; listed so nothing is hidden.
    print(t("Службові:", "Plumbing:"))
    for line in ("resume <dir> <session-id> [branch] | commit-preview [dir] | heavy-state [dir]",
                 "heavy-exclude <dir> [local|gitignore] | mcp-state [dir] | mcp-carry <src> <dst>",
                 "scan-folder <dir> | allow-git <dir>"):
        print("  " + line)
    print()
    print(t("Детальніше: night-shift help <команда>   ·   night-shift <команда> --help",
            "More: night-shift help <command>   ·   night-shift <command> --help"))
    print(t("Налаштування: %s" % config_path(), "Settings: %s" % config_path()))
    return 0


def cmd_completion(args):
    names = " ".join(c[0] for c in COMMANDS)
    keys = " ".join(k[0] for k in KEYS)
    actions = " ".join(CONFIG_ACTIONS)
    start_flags = ("--model --effort --codex-model --codex-effort --lang --permission-mode --branch --no-web "
                   "--set --no-attach --dirty=keep --dirty=commit --help")
    claude_eff = " ".join(CLAUDE_EFFORTS)
    codex_eff = " ".join(CODEX_EFFORTS)
    shell = args.shell
    if shell == "bash":
        print(r'''# night-shift bash completion — eval "$(night-shift completion bash)"
_night_shift() {
  local cur prev cmd
  cur="${COMP_WORDS[COMP_CWORD]}"; prev="${COMP_WORDS[COMP_CWORD-1]}"; cmd="${COMP_WORDS[1]}"
  if [ "$COMP_CWORD" -eq 1 ]; then COMPREPLY=($(compgen -W "%(names)s" -- "$cur")); return; fi
  case "$prev" in
    --effort) COMPREPLY=($(compgen -W "%(ceff)s" -- "$cur")); return ;;
    --codex-effort) COMPREPLY=($(compgen -W "%(xeff)s" -- "$cur")); return ;;
    --lang) COMPREPLY=($(compgen -W "en uk ru auto" -- "$cur")); return ;;
    --permission-mode) COMPREPLY=($(compgen -W "auto acceptEdits plan default bypassPermissions" -- "$cur")); return ;;
    --model|--codex-model) COMPREPLY=($(compgen -W "$(night-shift models --names 2>/dev/null)" -- "$cur")); return ;;
    --project|--run|--branch) COMPREPLY=($(compgen -d -- "$cur")); return ;;
  esac
  case "$cmd" in
    start) [[ "$cur" == -* ]] && COMPREPLY=($(compgen -W "%(flags)s" -- "$cur")) || COMPREPLY=($(compgen -d -- "$cur")) ;;
    config)
      if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=($(compgen -W "%(actions)s" -- "$cur"))
      elif [ "$COMP_CWORD" -eq 3 ]; then COMPREPLY=($(compgen -W "%(keys)s" -- "$cur"))
      else COMPREPLY=($(compgen -W "--project --run --json --all --yes --force --dry-run" -- "$cur")); fi ;;
    models) COMPREPLY=($(compgen -W "claude codex --json" -- "$cur")) ;;
    completion) COMPREPLY=($(compgen -W "bash zsh fish powershell" -- "$cur")) ;;
    help) COMPREPLY=($(compgen -W "%(names)s" -- "$cur")) ;;
    stop|attach|revive|dirty-state) COMPREPLY=($(compgen -d -- "$cur") --all) ;;
  esac
}
complete -o default -F _night_shift night-shift''' % {"names": names, "ceff": claude_eff, "xeff": codex_eff,
                                                       "flags": start_flags, "actions": actions, "keys": keys})
    elif shell == "zsh":
        print(r'''#compdef night-shift
# night-shift zsh completion — eval "$(night-shift completion zsh)"
_night_shift() {
  local -a cmds; cmds=(%(names)s)
  if (( CURRENT == 2 )); then compadd -- $cmds; return; fi
  case "${words[CURRENT-1]}" in
    --effort) compadd -- %(ceff)s; return ;;
    --codex-effort) compadd -- %(xeff)s; return ;;
    --lang) compadd -- en uk ru auto; return ;;
    --permission-mode) compadd -- auto acceptEdits plan default bypassPermissions; return ;;
    --model|--codex-model) compadd -- ${(f)"$(night-shift models --names 2>/dev/null)"}; return ;;
    --project|--run) _files -/; return ;;
  esac
  case "${words[2]}" in
    start) [[ "$PREFIX" == -* ]] && compadd -- %(flags)s || _files -/ ;;
    config) if (( CURRENT == 3 )); then compadd -- %(actions)s
            elif (( CURRENT == 4 )); then compadd -- %(keys)s
            else compadd -- --project --run --json --all --yes --force --dry-run; fi ;;
    models) compadd -- claude codex --json ;;
    completion) compadd -- bash zsh fish powershell ;;
    help) compadd -- $cmds ;;
    *) _files -/ ;;
  esac
}
if (( $+functions[compdef] )); then compdef _night_shift night-shift; fi''' % {
            "names": names, "ceff": claude_eff, "xeff": codex_eff, "flags": start_flags,
            "actions": actions, "keys": keys})
    elif shell == "fish":
        lines = ["# night-shift fish completion — night-shift completion fish | source",
                 "complete -c night-shift -f"]
        for name, _u, uk, en in COMMANDS:
            lines.append("complete -c night-shift -n '__fish_use_subcommand' -a %s -d %s"
                         % (name, _shell_quote(t(uk, en))))
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from config' -a '%s'" % actions)
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from config' -a '%s'" % keys)
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l effort -xa '%s'" % claude_eff)
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l codex-effort -xa '%s'" % codex_eff)
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l model -xa '(night-shift models --names 2>/dev/null)'")
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l codex-model -xa '(night-shift models --names 2>/dev/null)'")
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l lang -xa 'en uk ru auto'")
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l no-web")
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from start' -l no-attach")
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from models' -a 'claude codex'")
        lines.append("complete -c night-shift -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish powershell'")
        print("\n".join(lines))
    elif shell == "powershell":
        print(r'''# night-shift PowerShell completion — night-shift completion powershell | Out-String | Invoke-Expression
Register-ArgumentCompleter -Native -CommandName night-shift -ScriptBlock {
  param($wordToComplete, $commandAst, $cursorPosition)
  $words = $commandAst.CommandElements | ForEach-Object { $_.ToString() }
  $cmds = '%(names)s' -split ' '
  $candidates = @()
  if ($words.Count -le 2 -and -not ($words.Count -eq 2 -and $wordToComplete -eq '')) { $candidates = $cmds }
  else {
    switch ($words[1]) {
      'start'      { $candidates = '%(flags)s' -split ' ' }
      'config'     { if ($words.Count -le 3) { $candidates = '%(actions)s' -split ' ' } else { $candidates = '%(keys)s' -split ' ' } }
      'models'     { $candidates = @('claude', 'codex', '--json') }
      'completion' { $candidates = @('bash', 'zsh', 'fish', 'powershell') }
      'help'       { $candidates = $cmds }
    }
  }
  $candidates | Where-Object { $_ -like "$wordToComplete*" } |
    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}''' % {"names": names, "flags": start_flags, "actions": actions, "keys": keys})
    else:
        die(t("оболонки: bash, zsh, fish, powershell", "shells: bash, zsh, fish, powershell"))
    return 0


def cmd_model_names(_args):
    names = set()
    for kind in ("claude", "codex"):
        names |= known_model_names(kind)
    names |= {"opus", "sonnet", "haiku", "fable", "auto"}
    print("\n".join(sorted(names)))
    return 0


# ───────────────────────────────────────────────────────────────── entry

def main(argv):
    p = argparse.ArgumentParser(prog="night-shift", add_help=False)
    sub = p.add_subparsers(dest="cmd")

    e = sub.add_parser("env", add_help=False)
    e.add_argument("--project")
    e.add_argument("--caller-set", default="")
    e.add_argument("--set", action="append")
    e.add_argument("--no-file", dest="use_file", action="store_false")

    c = sub.add_parser("config", add_help=False)
    c.add_argument("action", nargs="?", default="list")
    c.add_argument("key", nargs="?")
    c.add_argument("value", nargs="?")
    c.add_argument("--project")
    c.add_argument("--json", action="store_true")
    c.add_argument("--all", action="store_true")
    c.add_argument("--yes", "-y", action="store_true")
    c.add_argument("--force", action="store_true")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--from", dest="source", choices=["release", "dev"], default="release")

    r = sub.add_parser("run-set", add_help=False)
    r.add_argument("idir")
    r.add_argument("pairs", nargs="*")

    m = sub.add_parser("models", add_help=False)
    m.add_argument("kind", nargs="?", choices=["claude", "codex"])
    m.add_argument("--json", action="store_true")
    m.add_argument("--names", action="store_true")
    m.add_argument("--project")

    sub.add_parser("status-json", add_help=False)

    d = sub.add_parser("doctor", add_help=False)
    d.add_argument("--json", action="store_true")
    d.add_argument("--server", action="store_true")
    d.add_argument("--network", action="store_true")
    d.add_argument("--probe", action="store_true")
    d.add_argument("dir", nargs="?")

    h = sub.add_parser("help", add_help=False)
    h.add_argument("topic", nargs="?")

    cp = sub.add_parser("completion", add_help=False)
    cp.add_argument("shell", nargs="?", default="bash")

    try:
        args = p.parse_args(argv)
    except SystemExit:
        return 2
    if args.cmd == "env":
        return cmd_env(args)
    if args.cmd == "config":
        if args.project:
            args.project = canon(args.project)
        return cmd_config(args)
    if args.cmd == "run-set":
        return cmd_run_set(args)
    if args.cmd == "models":
        return cmd_model_names(args) if args.names else cmd_models(args)
    if args.cmd == "status-json":
        return cmd_status_json(args)
    if args.cmd == "doctor":
        if args.server:
            return cmd_doctor_server(args)
        return cmd_doctor(args)
    if args.cmd == "completion":
        return cmd_completion(args)
    if args.cmd == "help" or args.cmd is None:
        return cmd_help(argparse.Namespace(topic=getattr(args, "topic", None)))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
