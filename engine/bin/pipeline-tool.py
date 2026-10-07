#!/usr/bin/env python3
"""pipeline-tool.py — the one place that knows what a pipeline description is.

A pipeline is a folder: `pipeline.json` (what runs), `layout.json` (where the boxes stand on a
canvas — never semantics) and `prompts/<node>.md`. Bulava's editor, its chat constructor, an
import from GitHub and the runner all read and write that folder, and every one of them asks THIS
file whether a description is valid. A second validator somewhere else would be a second opinion
about what may run, and the two would drift.

    pipeline-tool.py registry                         the module palette, as JSON
    pipeline-tool.py validate <dir|file|->            issues + guarantees; exit 1 on any error
    pipeline-tool.py compile <dir> --out F --snapshot D
                                                      the stage list pipeline.sh executes
    pipeline-tool.py resolve <name>                   legacy:<file> | manifest:<dir>; exit 3 if none
    pipeline-tool.py check <name>                     exit 0 when <name> can run; reason on stderr
    pipeline-tool.py needs <name>                     what a run of it needs (codex, …)
    pipeline-tool.py list                             every pipeline on this machine, summarised
    pipeline-tool.py show <id>                        the full description, prompts inline
    pipeline-tool.py save <id> [--expect-revision N]  description on stdin → written, revision+1
    pipeline-tool.py patch <id> [--dry-run]           RFC 6902 ops on stdin → applied atomically
    pipeline-tool.py duplicate <src> <new-id> [--name N]
    pipeline-tool.py delete <id>
    pipeline-tool.py inspect <dir>                    what an imported package holds, before it is added
    pipeline-tool.py install <dir> <id> --origin F    add a checked package to the library, switched off
    pipeline-tool.py arm <id>                         he has read an import and switches it on
    pipeline-tool.py export <id> --out DIR            a shareable package: no keys, no home paths

Written for the python3 that ships with macOS (3.9): no match statements, no `X | Y` types.
"""
import copy
import json
import os
import re
import shutil
import sys
import tempfile
import time

SCHEMA = "bulava.pipeline/1"
LAYOUT_SCHEMA = "bulava.layout/1"
ENGINE_MODULE_MAJOR = 1
LEGACY_NAMES = ("plain", "adaptive-peer", "dispatch", "dispatch-legacy")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
# Where a description came from when somebody else wrote it. Such a one arrives switched off.
IMPORTED = ("github", "file")

BIN_DIR = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(BIN_DIR)
STATE = os.environ.get("SUPERVISOR_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "supervisor")
USER_DIR = os.path.join(STATE, "pipelines")
BUILTIN_DIR = os.path.join(ROOT, "supervisor", "pipelines", "manifests")
LEGACY_DIR = os.path.join(ROOT, "supervisor", "pipelines")


def _config_int(name, default):
    """A number from supervisor/config.sh, so the ceiling here is the engine's own."""
    try:
        with open(os.path.join(ROOT, "supervisor", "config.sh"), encoding="utf-8") as fh:
            m = re.search(r"\$\{%s:=(\d+)\}" % re.escape(name), fh.read())
            if m:
                return int(m.group(1))
    except OSError:
        pass
    return default


REVIEW_CEILING = _config_int("SUPERVISOR_MAX_ROUNDS_HARD", 12)
REVIEW_DEFAULT = _config_int("SUPERVISOR_MAX_ROUNDS", 3)

TYPES = {
    "task": {"uk": "задача", "en": "task"},
    "context": {"uk": "контекст", "en": "context"},
    "position": {"uk": "позиція", "en": "position"},
    "checks": {"uk": "критерії", "en": "checks"},
    "brief": {"uk": "бриф", "en": "brief"},
    "work": {"uk": "зміни коду", "en": "code changes"},
    "report": {"uk": "звіт", "en": "report"},
    "feedback": {"uk": "зауваження", "en": "feedback"},
    "any": {"uk": "будь-що", "en": "anything"},
}


def T(uk, en):
    return {"uk": uk, "en": en}


# What a select option is called on screen; a value without a name here is shown as itself.
OPTION_LABELS = {
    "claude": T("Claude", "Claude"), "codex": T("Codex", "Codex"),
    "opus": T("Opus", "Opus"), "sonnet": T("Sonnet", "Sonnet"),
    "low": T("Низька", "Low"), "medium": T("Середня", "Medium"), "high": T("Висока", "High"), "max": T("Максимальна", "Max"),
    "hourly": T("Щогодини", "Every hour"), "daily": T("Щодня", "Every day"),
    "weekdays": T("У робочі дні", "On weekdays"), "weekly": T("Щотижня", "Every week"),
    "commits": T("Нові коміти", "New commits"), "feed": T("Стрічка RSS", "An RSS feed"),
    "huggingFace": T("Моделі Hugging Face", "Hugging Face models"), "webPage": T("Вебсторінка", "A web page"),
    "mail": T("Лист", "An email"), "folder": T("Файл у теці", "A file in a folder"), "meetingEnded": T("Кінець зустрічі", "A meeting ended"),
    "followup": T("Це продовження відкритої задачі", "It continues an open task"),
}


def P(k, uk, en, typ, default, options=None):
    p = {"k": k, "label": T(uk, en), "type": typ, "default": default}
    if options is not None:
        p["options"] = options
        p["ol"] = {o: OPTION_LABELS.get(o, T(o, o)) for o in options}
    return p


ENGINE_PARAM = P("engine", "Хто", "Who", "select", "codex", ["codex", "claude"])
MODEL_PARAM = P("model", "Модель", "Model", "select", "opus", ["opus", "sonnet"])
EFFORT_PARAM = P("effort", "Глибина", "Depth", "select", "high", ["low", "medium", "high", "max"])
FOLLOWUP_PARAM = P("skipOnFollowup", "Пропускати для продовження", "Skip on a follow-up", "bool", False)

# The palette. `exec` says whether THIS engine can run the module; the rest are on the map so the
# whole picture is visible, and the validator refuses them in a description that is meant to run.
REG = {
    "trigger.chat": {"t": T("Повідомлення в чаті", "Chat message"), "cat": "trigger", "phase": "trigger", "v": "v1", "exec": True,
        "d": T("Ти пишеш у чат продукту — повідомлення стає задачею цього пайплайна.", "You write in the product's chat; the message becomes this pipeline's task."),
        "out": [{"id": "task", "type": "task"}]},
    "trigger.manual": {"t": T("Запуск вручну", "Run manually"), "cat": "trigger", "phase": "trigger", "v": "v1", "exec": True,
        "d": T("Автоматизація, яку запускаєш кнопкою. Вона відкриває власний чат.", "An automation you start with a button. It opens its own chat."),
        "out": [{"id": "task", "type": "task"}]},
    "trigger.schedule": {"t": T("Розклад", "Schedule"), "cat": "trigger", "phase": "trigger", "v": "v2", "exec": True, "unattended": True,
        "d": T("Автоматизація за розкладом. Запускається без тебе.", "A scheduled automation. Runs without you."),
        "out": [{"id": "task", "type": "task"}],
        "p": [P("cadence", "Коли", "When", "select", "daily", ["hourly", "daily", "weekdays", "weekly"]), P("time", "О котрій", "At", "text", "03:00")]},
    "trigger.watch": {"t": T("Зміни ззовні", "Something changed"), "cat": "trigger", "phase": "trigger", "v": "v2", "exec": True, "unattended": True,
        "d": T("Нові коміти, запис у RSS, моделі на Hugging Face, змінена сторінка.", "New commits, a feed entry, Hugging Face models, a changed page."),
        "out": [{"id": "task", "type": "task"}],
        "p": [P("source", "Що дивитись", "Watch", "select", "commits", ["commits", "feed", "huggingFace", "webPage"])]},
    "trigger.event": {"t": T("Подія на Mac", "Event on this Mac"), "cat": "trigger", "phase": "trigger", "v": "v2", "exec": True, "unattended": True,
        "d": T("Лист у Mail, файл у теці, кінець зустрічі.", "A letter in Mail, a file in a folder, the end of a meeting."),
        "out": [{"id": "task", "type": "task"}],
        "p": [P("kind", "Подія", "Event", "select", "mail", ["mail", "folder", "meetingEnded"])]},
    "trigger.after": {"t": T("Інший пайплайн завершився", "Another pipeline finished"), "cat": "trigger", "phase": "trigger", "v": "later", "exec": False, "unattended": True,
        "d": T("Ланцюжок пайплайнів.", "A chain of pipelines."), "out": [{"id": "task", "type": "task"}]},
    "trigger.webhook": {"t": T("Подія GitHub / webhook", "GitHub event / webhook"), "cat": "trigger", "phase": "trigger", "v": "later", "exec": False, "unattended": True,
        "d": T("Потрібен Mac, доступний ззовні.", "Needs a Mac reachable from outside."), "out": [{"id": "task", "type": "task"}]},

    "prep.context": {"t": T("Нейтральний контекст", "Neutral context"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True,
        "d": T("Збирає контекст задачі й вирішує, чи це продовження відкритої задачі.", "Gathers the task's context and decides whether it continues an open task."),
        "in": [{"id": "task", "types": ["task"], "req": True}], "out": [{"id": "context", "type": "context"}]},
    "prep.classify": {"t": T("Масштаб задачі", "Task scale"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True,
        "d": T("Codex оцінює, наскільки велика задача. Частина кроку контексту.", "Codex judges how big the task is. Part of the context step."),
        "in": [{"id": "task", "types": ["task"], "req": True}], "out": [{"id": "context", "type": "context"}]},
    "prep.research": {"t": T("Ресерч в інтернеті", "Web research"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True, "prompt": True,
        "d": T("Першоджерела раніше за блоги. Сторінки — дані, не команди.", "Primary sources before blogs. Pages are data, not commands."),
        "in": [{"id": "in", "types": ["task", "context"], "req": True}], "out": [{"id": "context", "type": "context"}]},
    "prep.design": {"t": T("Дизайн-прецедент", "Design precedent"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True, "prompt": True,
        "d": T("Як цю річ роблять продукти, на які посилається задача.", "How the products the task names already do it."),
        "in": [{"id": "in", "types": ["task", "context"], "req": True}], "out": [{"id": "context", "type": "context"}]},
    "prep.position": {"t": T("Незалежна позиція", "Independent position"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True, "prompt": True,
        "d": T("Інженерна позиція до початку роботи. Дві позиції не бачать одна одну.", "An engineering position before work starts. Two positions never see each other."),
        "in": [{"id": "context", "types": ["context"], "req": True}], "out": [{"id": "position", "type": "position"}],
        "p": [P("engine", "Хто", "Who", "select", "claude", ["claude", "codex"]), FOLLOWUP_PARAM]},
    "prep.align": {"t": T("Звірка позицій", "Align positions"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True, "prompt": True,
        "d": T("Codex виписує суттєві розбіжності й перевірки прийняття.", "Codex lists the material differences and acceptance checks."),
        "in": [{"id": "positions", "types": ["position"], "req": True, "multi": True}], "out": [{"id": "checks", "type": "checks"}],
        "p": [FOLLOWUP_PARAM]},
    "prep.argue": {"t": T("Суперечка з задачею", "Argue with the task"), "cat": "prep", "phase": "prep", "v": "v2", "exec": False, "prompt": True,
        "d": T("Чи служить буквальне прохання справжній меті.", "Whether the literal request serves the real goal."),
        "in": [{"id": "context", "types": ["context"], "req": True}], "out": [{"id": "checks", "type": "checks"}]},
    "prep.plan": {"t": T("План", "Plan"), "cat": "prep", "phase": "prep", "v": "v2", "exec": False, "prompt": True,
        "d": T("Короткий план для великої задачі.", "A short plan for a large task."),
        "in": [{"id": "in", "types": ["context", "checks"], "req": True}], "out": [{"id": "checks", "type": "checks"}]},
    "prep.critique": {"t": T("Критика плану", "Critique the plan"), "cat": "prep", "phase": "prep", "v": "v2", "exec": False, "prompt": True,
        "d": T("Друга модель шукає дірки в плані.", "A second model looks for holes in the plan."),
        "in": [{"id": "checks", "types": ["checks"], "req": True}], "out": [{"id": "checks", "type": "checks"}]},
    "prep.compose": {"t": T("Бриф виконавцю", "Brief for the worker"), "cat": "prep", "phase": "prep", "v": "v1", "exec": True, "prompt": True,
        "d": T("Що отримує виконавець. Твій текст додається до стандартних розділів; доказ і завершення лишаються завжди.", "What the worker receives. Your text is added to the standard sections; proof and completion always stay."),
        "in": [{"id": "in", "types": ["task", "context", "position", "checks"], "req": True, "multi": True}], "out": [{"id": "brief", "type": "brief"}]},

    "agent.claude": {"t": T("Claude виконує", "Claude does the work"), "cat": "agent", "phase": "work", "v": "v1", "exec": True, "code": True,
        "d": T("Сесія Claude Code у робочій гілці, з консультаціями Codex.", "A Claude Code session on the work branch, with Codex on call."),
        "in": [{"id": "brief", "types": ["brief", "task"], "req": True}, {"id": "feedback", "types": ["feedback"], "multi": True}],
        "out": [{"id": "work", "type": "work"}], "eng": {"claude": True, "codex": False}},
    "agent.researcher": {"t": T("Claude досліджує", "Claude researches"), "cat": "agent", "phase": "work", "v": "v2", "exec": True, "report": True,
        "d": T("Та сама сесія, але результат — звіт в artifacts/, а не зміни коду.", "The same session, but the result is a report in artifacts/, not code."),
        "in": [{"id": "brief", "types": ["brief", "task"], "req": True}, {"id": "feedback", "types": ["feedback"], "multi": True}],
        "out": [{"id": "report", "type": "report"}], "eng": {"claude": True, "codex": False}},
    "agent.codex": {"t": T("Codex виконує", "Codex does the work"), "cat": "agent", "phase": "work", "v": "v2", "exec": False, "code": True,
        "d": T("codex exec у робочій гілці.", "codex exec on the work branch."),
        "in": [{"id": "brief", "types": ["brief", "task"], "req": True}, {"id": "feedback", "types": ["feedback"], "multi": True}],
        "out": [{"id": "work", "type": "work"}], "eng": {"claude": False, "codex": True}},
    "agent.audit": {"t": T("Глибокий аудит", "Deep audit"), "cat": "agent", "phase": "work", "v": "v2", "exec": False, "report": True,
        "d": T("Codex свіжим поглядом: вимоги, розвідка, код.", "Codex with fresh eyes: requirements, research, code."),
        "in": [{"id": "in", "types": ["task", "context"], "req": True}], "out": [{"id": "report", "type": "report"}]},

    "skill.require": {"t": T("Обов'язковий скіл", "Required skill"), "cat": "skill", "phase": "work", "v": "v2", "exec": True,
        "d": T("Виконавець мусить викликати скіл; ворота шукають виклик у транскрипті.", "The worker must call the skill; the gate looks for the call in the transcript."),
        "in": [{"id": "brief", "types": ["brief"], "req": True}], "out": [{"id": "brief", "type": "brief"}],
        "p": [P("skill", "Скіл", "Skill", "text", "minimalist-ui")]},
    "tool.consult": {"t": T("Консультації з Codex", "Codex consultations"), "cat": "skill", "phase": "work", "v": "v1", "exec": True,
        "d": T("Виконавець питає Codex, коли треба. Є завжди.", "The worker asks Codex when it needs to. Always available."),
        "in": [{"id": "brief", "types": ["brief"], "req": True}], "out": [{"id": "brief", "type": "brief"}]},
    "tool.capture": {"t": T("Знімок екрана і відео", "Screenshots and video"), "cat": "skill", "phase": "work", "v": "v1", "exec": True,
        "d": T("Справжні кадри через Булаву. Є завжди.", "Real frames through Bulava. Always available."),
        "in": [{"id": "brief", "types": ["brief"], "req": True}], "out": [{"id": "brief", "type": "brief"}]},
    "tool.mcp": {"t": T("MCP-сервер", "MCP server"), "cat": "skill", "phase": "work", "v": "v2", "exec": False,
        "d": T("Сервер лише якщо названий у пайплайні.", "A server only when the pipeline names it."),
        "in": [{"id": "brief", "types": ["brief"], "req": True}], "out": [{"id": "brief", "type": "brief"}]},

    "gate.scope": {"t": T("Межі змін", "Scope of changes"), "cat": "gate", "phase": "gate", "v": "v1", "exec": True, "g": "scope",
        "d": T("Зміни поза дозволеними шляхами відкочуються.", "Changes outside the allowed paths are rolled back."),
        "in": [{"id": "work", "types": ["work"], "req": True}], "out": [{"id": "work", "type": "work"}]},
    "gate.verify": {"t": T("Доказ збіркою", "Proof by build"), "cat": "gate", "phase": "gate", "v": "v1", "exec": True, "g": "verify",
        "d": T("Збірка, тести й зареєстровані перевірки.", "Build, tests and registered checks."),
        "in": [{"id": "work", "types": ["work"], "req": True}], "out": [{"id": "work", "type": "work"}]},
    "gate.review": {"t": T("Рев'ю Codex", "Codex review"), "cat": "gate", "phase": "gate", "v": "v1", "exec": True, "g": "review", "prompt": True,
        "d": T("Codex читає diff і приймає або повертає. Твій текст — додаткові вимоги рецензенту.", "Codex reads the diff and accepts or sends back. Your text adds requirements for the reviewer."),
        "in": [{"id": "work", "types": ["work"], "req": True}],
        "out": [{"id": "pass", "type": "work", "label": T("прийнято", "accepted")}, {"id": "fail", "type": "feedback", "label": T("повернути", "send back")}]},
    "gate.reportReview": {"t": T("Рев'ю звіту", "Report review"), "cat": "gate", "phase": "gate", "v": "v2", "exec": True, "g": "review", "prompt": True,
        "d": T("Codex перевіряє зміст звіту: джерела, відповіді на питання.", "Codex checks the report itself: sources, answers to the questions."),
        "in": [{"id": "report", "types": ["report"], "req": True}],
        "out": [{"id": "pass", "type": "report", "label": T("прийнято", "accepted")}, {"id": "fail", "type": "feedback", "label": T("повернути", "send back")}]},
    "gate.approval": {"t": T("Чекати на тебе", "Wait for you"), "cat": "gate", "phase": "gate", "v": "v2", "exec": False, "g": "human",
        "d": T("Питання в чаті; без тебе не чекає вічно.", "A question in the chat; never waits for ever."),
        "in": [{"id": "in", "types": ["any"], "req": True}],
        "out": [{"id": "yes", "type": "any", "label": T("так", "yes")}, {"id": "no", "type": "any", "label": T("ні", "no")}]},
    "gate.budget": {"t": T("Ліміти Claude і Codex", "Claude and Codex limits"), "cat": "gate", "phase": "gate", "v": "v1", "exec": True,
        "d": T("Пауза, коли вікно вичерпано. Є завжди.", "A pause when a window runs out. Always on."),
        "in": [{"id": "in", "types": ["any"], "req": True}], "out": [{"id": "out", "type": "any"}]},

    "flow.condition": {"t": T("Умова", "Condition"), "cat": "flow", "phase": "any", "v": "v2", "exec": True,
        "d": T("Дві гілки. Рушій поки розрізняє лише «продовження відкритої задачі».", "Two branches. The engine currently tells apart only 'a follow-up to an open task'."),
        "in": [{"id": "in", "types": ["any"], "req": True}],
        "out": [{"id": "yes", "type": "any", "label": T("так", "yes")}, {"id": "no", "type": "any", "label": T("ні", "no")}],
        "p": [P("when", "Коли", "When", "select", "followup", ["followup"])]},
    "flow.hold": {"t": T("Чекати вікно Codex", "Wait for Codex"), "cat": "flow", "phase": "any", "v": "v1", "exec": True,
        "d": T("Задача чекає, поки Codex повернеться.", "The task waits until Codex is back."),
        "in": [{"id": "in", "types": ["any"], "req": True}], "out": [{"id": "out", "type": "any"}]},
    "flow.sub": {"t": T("Під-пайплайн", "Sub-pipeline"), "cat": "flow", "phase": "any", "v": "later", "exec": False,
        "d": T("Інший пайплайн як один крок.", "Another pipeline as one step."),
        "in": [{"id": "in", "types": ["any"], "req": True}], "out": [{"id": "out", "type": "any"}]},

    "out.report": {"t": T("Звіт", "Report"), "cat": "out", "phase": "finish", "v": "v1", "exec": True,
        "d": T("HTML у artifacts/ продукту.", "HTML in the product's artifacts/."),
        "in": [{"id": "in", "types": ["work", "report"], "req": True, "multi": True}], "out": []},
    "out.merge": {"t": T("Злиття гілки", "Merge the branch"), "cat": "out", "phase": "finish", "v": "v1", "exec": True, "effect": True,
        "d": T("Після твого «Прийняти».", "After your Accept."),
        "in": [{"id": "work", "types": ["work"], "req": True}], "out": []},
    "out.notify": {"t": T("Сповіщення на телефон", "Notify the phone"), "cat": "out", "phase": "finish", "v": "v2", "exec": False, "effect": True,
        "d": T("Push через зв'язок із телефоном.", "A push through the phone link."),
        "in": [{"id": "in", "types": ["any"], "req": True}], "out": []},
    "out.chat": {"t": T("Чат зі знахідками", "A chat with the findings"), "cat": "out", "phase": "finish", "v": "v2", "exec": False, "effect": True,
        "d": T("Знахідки стають новим чатом продукту.", "Findings become a new chat in the product."),
        "in": [{"id": "in", "types": ["report", "work"], "req": True}], "out": []},
    "out.pr": {"t": T("Чернетка PR", "Draft PR"), "cat": "out", "phase": "finish", "v": "later", "exec": False, "effect": True,
        "d": T("Через gh.", "Through gh."), "in": [{"id": "work", "types": ["work"], "req": True}], "out": []},
    "out.release": {"t": T("Реліз", "Release"), "cat": "out", "phase": "finish", "v": "later", "exec": False, "effect": True,
        "d": T("Скіл release.", "The release skill."), "in": [{"id": "work", "types": ["work"], "req": True}], "out": []},
    "x.script": {"t": T("Свій скрипт", "Your own script"), "cat": "later", "phase": "any", "v": "later", "exec": False,
        "d": T("Лише створений на цьому Mac, ніколи з імпорту.", "Only made on this Mac, never imported."),
        "in": [{"id": "in", "types": ["any"]}], "out": [{"id": "out", "type": "any"}]},
}

# The engine's own prompt for a module, shown when a description has not replaced it.
DEFAULT_PROMPTS = {"prep.position": "peer-brief.md", "prep.align": "peer-align.md",
                   "prep.research": "research.md", "prep.design": "design-research.md"}

AESTHETIC = ("minimalist-ui", "high-end-visual-design", "industrial-brutalist-ui")
SECRET_RE = re.compile(r"(sk-ant-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[bp]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)")
ABS_PATH_RE = re.compile(r"/Users/[^\s/\"']+/")
REF_RE = re.compile(r"^([a-z0-9-]+)/([a-zA-Z.]+)@(\d+)$")
CONTEXT_KEYS = ("prep.context", "prep.classify", "prep.research", "prep.design")


# ── reading ────────────────────────────────────────────────────────────────────────────────────

def parse_ref(ref):
    m = REF_RE.match(ref or "")
    return {"ns": m.group(1), "key": m.group(2), "major": int(m.group(3))} if m else None


def module_of(node):
    r = parse_ref(node.get("module"))
    return REG.get(r["key"]) if r and r["ns"] == "bulava" else None


def key_of(node):
    r = parse_ref(node.get("module"))
    return r["key"] if r else None


def split(end):
    end = end or ""
    i = end.rfind(".")
    return (end, "") if i < 0 else (end[:i], end[i + 1:])


def compatible(out_type, in_types):
    return bool(out_type) and bool(in_types) and ("any" in in_types or out_type == "any" or out_type in in_types)


def loop_allowed(a, b):
    if not a or not b:
        return False
    return (a["phase"] == "gate" and b["phase"] == "work") or (a["phase"] == "prep" and b["phase"] == "prep")


class Graph(object):
    def __init__(self, m):
        self.by_id = {}
        self.fwd = {}
        self.back = {}
        for n in m.get("nodes") or []:
            self.by_id[n.get("id")] = n
            self.fwd.setdefault(n.get("id"), [])
            self.back.setdefault(n.get("id"), [])
        for e in m.get("edges") or []:
            if e.get("loop"):
                continue
            a, _ = split(e.get("from"))
            b, _ = split(e.get("to"))
            if a in self.fwd and b in self.back:
                self.fwd[a].append(b)
                self.back[b].append(a)

    def _walk(self, start, nxt):
        seen = set()
        stack = list(nxt.get(start, []))
        while stack:
            x = stack.pop()
            if x in seen:
                continue
            seen.add(x)
            stack.extend(nxt.get(x, []))
        return seen

    def downstream(self, start):
        return self._walk(start, self.fwd)

    def upstream(self, start):
        return self._walk(start, self.back)


def would_cycle(m, a, b):
    return a == b or a in Graph(m).downstream(b)


# ── validation ───────────────────────────────────────────────────────────────────────────────

def _title(n, mod):
    return n.get("title") or (mod["t"]["uk"] if mod else n.get("module", "?"))


def validate(m, require_exec=True):
    """Issues with codes the app and the tests rely on; the codes are the contract, the words are not."""
    issues = []

    def add(level, code, uk, en, node=None, edge=None):
        issues.append({"level": level, "code": code, "msg": {"uk": uk, "en": en}, "node": node, "edge": edge})

    if not isinstance(m, dict):
        add("error", "V15", "Це не опис пайплайна.", "This is not a pipeline description.")
        return {"issues": issues, "guarantees": [], "unverified": True, "needs": []}
    if m.get("schema") != SCHEMA:
        add("error", "V15", "Формат «%s» невідомий цьому рушію (чекаю %s)." % (m.get("schema") or "—", SCHEMA),
            "Format '%s' is unknown to this engine (expected %s)." % (m.get("schema") or "—", SCHEMA))
    pid = m.get("id")
    if pid is not None and not ID_RE.match(str(pid)):
        add("error", "V22", "Ідентифікатор «%s» не годиться: лише малі латинські літери, цифри й дефіс." % pid,
            "Identifier '%s' is not allowed: lowercase letters, digits and hyphens only." % pid)
    nodes = m.get("nodes") or []
    edges = m.get("edges") or []
    ids = set()
    for n in nodes:
        nid = n.get("id")
        if not nid or not re.match(r"^[A-Za-z0-9_-]{1,40}$", str(nid)):
            add("error", "V19", "Крок без придатного ідентифікатора.", "A step without a usable identifier.", nid)
            continue
        if nid in ids:
            add("error", "V19", "Два кроки з ідентифікатором «%s»." % nid, "Two steps share the identifier '%s'." % nid, nid)
        ids.add(nid)
        r = parse_ref(n.get("module"))
        if not r or r["ns"] != "bulava" or r["key"] not in REG:
            add("error", "V1", "Невідомий модуль «%s». Лише модулі рушія." % n.get("module"),
                "Unknown module '%s'. Only engine modules are allowed." % n.get("module"), nid)
            continue
        mod = REG[r["key"]]
        if r["major"] > ENGINE_MODULE_MAJOR:
            add("error", "V16", "«%s» потребує модуля версії %d, а цей рушій знає лише %d. Онови Булаву." % (mod["t"]["uk"], r["major"], ENGINE_MODULE_MAJOR),
                "'%s' needs module version %d; this engine knows only %d. Update Bulava." % (mod["t"]["en"], r["major"], ENGINE_MODULE_MAJOR), nid)
        if require_exec and not mod.get("exec"):
            if mod["v"] == "later":
                add("error", "V18", "«%s» поки немає в рушії." % mod["t"]["uk"], "'%s' is not in the engine yet." % mod["t"]["en"], nid)
            else:
                add("error", "V18", "«%s» ще не виконується цим рушієм." % mod["t"]["uk"], "'%s' cannot run on this engine yet." % mod["t"]["en"], nid)
        texts = [str(n.get("title") or ""), str(n.get("prompt") or "")] + [str(v) for v in (n.get("params") or {}).values()]
        if any(SECRET_RE.search(t) for t in texts):
            add("error", "V8", "У «%s» схоже на ключ доступу. Ключі — це вимоги, кожен прив'язує свої." % _title(n, mod),
                "'%s' looks like it contains an access key. Keys are requirements; everyone binds their own." % _title(n, mod), nid)
        elif any(ABS_PATH_RE.search(t) for t in texts):
            add("warn", "V8b", "У «%s» є абсолютний шлях /Users/… — при експорті він стане ~/…" % _title(n, mod),
                "'%s' contains an absolute /Users/… path — exporting turns it into ~/…" % _title(n, mod), nid)
        if r["key"] == "flow.condition" and (n.get("params") or {}).get("when", "followup") != "followup":
            add("error", "V18", "Умову «%s» рушій ще не вміє перевіряти." % (n.get("params") or {}).get("when"),
                "The engine cannot test the condition '%s' yet." % (n.get("params") or {}).get("when"), nid)
        if r["key"] == "skill.require":
            sk = str((n.get("params") or {}).get("skill") or "").strip()
            if not re.match(r"^[A-Za-z0-9._:-]{1,80}$", sk):
                add("error", "V23", "Обов'язковий скіл без назви.", "A required skill without a name.", nid)

    g = Graph(m)
    in_count = {}
    for i, e in enumerate(edges):
        a, ap = split(e.get("from"))
        b, bp = split(e.get("to"))
        na, nb = g.by_id.get(a), g.by_id.get(b)
        if not na or not nb:
            add("error", "V20", "Зв'язок %s → %s веде до кроку, якого немає." % (e.get("from"), e.get("to")),
                "Edge %s → %s points at a step that does not exist." % (e.get("from"), e.get("to")), None, i)
            continue
        ma, mb = module_of(na), module_of(nb)
        if not ma or not mb:
            continue
        po = next((p for p in ma.get("out", []) if p["id"] == ap), None)
        pi = next((p for p in mb.get("in", []) if p["id"] == bp), None)
        if not po or not pi:
            add("error", "V20", "Зв'язок %s → %s: такого входу чи виходу немає." % (e.get("from"), e.get("to")),
                "Edge %s → %s: no such input or output." % (e.get("from"), e.get("to")), b, i)
            continue
        if not compatible(po["type"], pi["types"]):
            add("error", "V2", "«%s» дає «%s», а «%s» чекає %s." % (_title(na, ma), TYPES[po["type"]]["uk"], _title(nb, mb), " або ".join("«%s»" % TYPES[t]["uk"] for t in pi["types"])),
                "'%s' gives '%s' but '%s' expects %s." % (_title(na, ma), TYPES[po["type"]]["en"], _title(nb, mb), " or ".join("'%s'" % TYPES[t]["en"] for t in pi["types"])), b, i)
        if e.get("loop"):
            try:
                mx = int((e.get("loop") or {}).get("max"))
            except (TypeError, ValueError):
                mx = 0
            if mx < 1:
                add("error", "V6", "Петля %s → %s без межі кіл." % (e.get("from"), e.get("to")), "Loop %s → %s has no round limit." % (e.get("from"), e.get("to")), a, i)
            elif mx > REVIEW_CEILING:
                add("error", "V6", "Петля на %d кіл — більше за стелю %d." % (mx, REVIEW_CEILING), "A loop of %d rounds exceeds the ceiling of %d." % (mx, REVIEW_CEILING), a, i)
            if not loop_allowed(ma, mb):
                add("error", "V7", "Петля з «%s» у «%s» перетинає фази." % (_title(na, ma), _title(nb, mb)),
                    "The loop from '%s' to '%s' crosses phases." % (_title(na, ma), _title(nb, mb)), a, i)
            if po["type"] != "feedback":
                add("error", "V7", "Петля можлива лише з виходу «повернути».", "A loop can only start at a 'send back' output.", a, i)
        k = b + "." + bp
        in_count[k] = in_count.get(k, 0) + (0 if e.get("loop") else 1)
        if not pi.get("multi") and not e.get("loop") and in_count[k] > 1:
            add("error", "V2", "У вхід «%s» кроку «%s» веде більше одного зв'язку." % (bp, _title(nb, mb)),
                "More than one edge enters input '%s' of '%s'." % (bp, _title(nb, mb)), b, i)

    # Cycles that are left once the counted loops are taken out have no bound.
    color = {}
    cyc = []

    def dfs(u, path):
        color[u] = 1
        path.append(u)
        for v in g.fwd.get(u, []):
            if cyc:
                return
            if color.get(v) == 1:
                cyc.extend(path[path.index(v):])
                return
            if not color.get(v):
                dfs(v, path)
        path.pop()
        color[u] = 2

    for n in nodes:
        if not cyc and not color.get(n.get("id")):
            dfs(n.get("id"), [])
    if cyc:
        names = " → ".join(_title(g.by_id[i], module_of(g.by_id[i])) for i in cyc if i in g.by_id)
        add("error", "V5", "Цикл без межі: %s." % names, "A loop without a limit: %s." % names, cyc[0])

    triggers = [n for n in nodes if (module_of(n) or {}).get("cat") == "trigger"]
    if nodes and not triggers:
        add("error", "V11", "Немає тригера: пайплайн ніколи не запуститься.", "No trigger: the pipeline would never start.")
    if len(triggers) > 1:
        add("error", "V24", "Тригер має бути один.", "There must be exactly one trigger.")
    reach = set()
    for t in triggers:
        reach.add(t["id"])
        reach |= g.downstream(t["id"])
    for n in nodes:
        mod = module_of(n)
        if not mod:
            continue
        if mod["cat"] != "trigger" and triggers and n["id"] not in reach:
            add("error", "V4", "«%s» ніколи не виконається: до нього не веде жоден шлях." % _title(n, mod),
                "'%s' would never run: no path leads to it." % _title(n, mod), n["id"])
        for p in mod.get("in", []):
            if p.get("req") and not any((not e.get("loop")) and e.get("to") == n["id"] + "." + p["id"] for e in edges):
                add("error", "V3", "«%s»: вхід «%s» нічим не заповнений." % (_title(n, mod), p["id"]),
                    "'%s': input '%s' is not connected." % (_title(n, mod), p["id"]), n["id"])
        if key_of(n) == "prep.align":
            c = sum(1 for e in edges if e.get("to") == n["id"] + ".positions")
            if c == 1:
                add("warn", "V21", "Звірка з однієї позиції — не звірка: рушій запише деградацію замість порівняння.",
                    "Aligning a single position is not an alignment: the engine records a degradation instead.", n["id"])
        if mod.get("code") or mod.get("report"):
            if not any((not e.get("loop")) and split(e.get("from"))[0] == n["id"] for e in edges):
                add("warn", "V14", "Результат «%s» нікуди не йде." % _title(n, mod), "The result of '%s' goes nowhere." % _title(n, mod), n["id"])

    agents = [n for n in nodes if key_of(n) in ("agent.claude", "agent.codex", "agent.researcher")]
    if len(agents) > 1:
        add("error", "V25", "Виконавець має бути один: рушій веде одну сесію на запуск.", "There must be one worker: the engine runs one session per run.")
    for ag in agents:
        ups = [g.by_id[i] for i in g.upstream(ag["id"]) if i in g.by_id]
        skills = [u for u in ups if key_of(u) == "skill.require"]
        if skills and key_of(ag) == "agent.codex":
            add("error", "V9", "Codex не повідомляє, який скіл використав, тож обов'язковість «%s» неможливо перевірити." % (skills[0].get("params") or {}).get("skill"),
                "Codex does not report which skill it used, so requiring '%s' cannot be checked." % (skills[0].get("params") or {}).get("skill"), skills[0]["id"])
        aest = sorted(set(str((s.get("params") or {}).get("skill")) for s in skills if (s.get("params") or {}).get("skill") in AESTHETIC))
        if len(aest) > 1:
            add("error", "V10", "Дві естетики на одного виконавця (%s). Лиши одну." % ", ".join(aest),
                "Two aesthetics for one worker (%s). Keep one." % ", ".join(aest), skills[1]["id"])
    if not agents:
        for n in nodes:
            if key_of(n) == "prep.compose":
                add("warn", "V26", "Бриф є, а виконавця немає.", "There is a brief but no worker.", n["id"])
    for n in nodes:
        if key_of(n) == "gate.reportReview":
            if not any(key_of(g.by_id[u]) == "agent.researcher" for u in g.upstream(n["id"]) if u in g.by_id):
                add("error", "V27", "«Рев'ю звіту» стоїть після виконавця, що пише звіт.", "'Report review' must follow a worker that writes a report.", n["id"])

    G = guarantees(m, g)
    unattended = any((module_of(t) or {}).get("unattended") for t in triggers)
    if unattended and G["unverified"] and not ((m.get("acks") or {}).get("unattendedWithoutReview") or {}).get("signature"):
        add("error", "V13", "Автоматизація без рев'ю: результат ніхто не перевірить, а тебе поруч немає. Потрібен твій підпис.",
            "An automation without review: nobody checks the result and you are not there. It needs your signature.")
    origin = m.get("origin") or {}
    if origin.get("kind") in IMPORTED and m.get("armed") and not ((m.get("acks") or {}).get("armed") or {}).get("at"):
        add("error", "V12", "Імпортований пайплайн не може прийти з увімкненим тригером.", "An imported pipeline cannot arrive with its trigger switched on.")
    return {"issues": issues, "guarantees": G["list"], "unverified": G["unverified"], "needs": needs_of(m)}


def guarantees(m, g=None):
    g = g or Graph(m)
    nodes = m.get("nodes") or []
    code = [n for n in nodes if (module_of(n) or {}).get("code")]
    rep = [n for n in nodes if (module_of(n) or {}).get("report")]

    def covered(n, gate):
        return any(key_of(g.by_id[i]) == gate for i in g.downstream(n["id"]) if i in g.by_id)

    unverified = any(not covered(n, "gate.review") for n in code) or any(not covered(n, "gate.reportReview") for n in rep)
    for n in nodes:
        mod = module_of(n) or {}
        if mod.get("effect") and key_of(n) != "out.notify":
            ups = [key_of(g.by_id[i]) for i in g.upstream(n["id"]) if i in g.by_id]
            if "gate.review" not in ups and "gate.reportReview" not in ups:
                unverified = True
    out = []
    if (code or rep) and unverified:
        out.append({"k": "unverified", "t": T("Не перевірено", "Not verified"), "tone": "bad"})
    if (code or rep) and not unverified:
        out.append({"k": "review", "t": T("Перевіряє Codex", "Codex reviews"), "tone": "ok"})
    if code and all(covered(n, "gate.scope") for n in code):
        out.append({"k": "scope", "t": T("Межі змін", "Scope"), "tone": "ok"})
    if code and all(covered(n, "gate.verify") for n in code):
        out.append({"k": "verify", "t": T("Доказ збіркою", "Build proof"), "tone": "ok"})
    if not code and rep:
        out.append({"k": "nocode", "t": T("Без змін коду", "No code changes"), "tone": "info"})
    for n in nodes:
        if key_of(n) == "skill.require":
            sk = str((n.get("params") or {}).get("skill") or "?")
            out.append({"k": "skill", "t": T("Скіл: " + sk, "Skill: " + sk), "tone": "lime"})
    if any((module_of(n) or {}).get("unattended") for n in nodes):
        out.append({"k": "unattended", "t": T("Без нагляду", "Unattended"), "tone": "warn"})
    return {"list": out, "unverified": unverified}


def needs_of(m):
    need = set()
    for n in m.get("nodes") or []:
        k = key_of(n)
        p = n.get("params") or {}
        if k in ("prep.align", "prep.research", "prep.design", "prep.classify", "gate.review", "gate.reportReview", "flow.hold"):
            need.add("codex")
        if k == "prep.position" and p.get("engine", "claude") == "codex":
            need.add("codex")
    return sorted(need)


# ── compiling into the stage list pipeline.sh already executes ──────────────────────────────

def _topo(m):
    g = Graph(m)
    indeg = {n["id"]: len(g.back.get(n["id"], [])) for n in m.get("nodes") or []}
    level = {}
    order = []
    queue = [nid for nid, d in indeg.items() if d == 0]
    for q in queue:
        level[q] = 0
    while queue:
        u = queue.pop(0)
        order.append(u)
        for v in g.fwd.get(u, []):
            level[v] = max(level.get(v, 0), level[u] + 1)
            indeg[v] -= 1
            if indeg[v] == 0:
                queue.append(v)
    return order, level, g


def compile_manifest(m, prompt_dir=None):
    """The description as the ordered stage list `pipeline.sh` runs, plus what the gates need.

    Nothing here invents behaviour: every stage is a command the engine already has. Context-like
    nodes collapse into the one context stage (it is the one that writes the shared peer prompt);
    positions at the same depth form one parallel group; the brief and the hand-over close it.
    """
    v = validate(m)
    errors = [i for i in v["issues"] if i["level"] == "error"]
    if errors:
        raise ValueError("; ".join(i["msg"]["uk"] for i in errors))
    order, level, g = _topo(m)
    by_id = g.by_id
    stages = []
    node_stage = {}
    keys = [key_of(by_id[i]) for i in order]

    def prompt_file(n):
        if not n.get("prompt") or not prompt_dir:
            return None
        return os.path.join(prompt_dir, n["id"] + ".md")

    # Follow-up skipping: a node's own flag, or every node only reachable through a condition's
    # "no" branch (a new task) and not through its "yes" branch.
    followup_only_new = set()
    for n in m.get("nodes") or []:
        if key_of(n) == "flow.condition":
            yes, no = set(), set()
            for e in m.get("edges") or []:
                a, ap = split(e.get("from"))
                if a != n["id"] or e.get("loop"):
                    continue
                b, _ = split(e.get("to"))
                tgt = {b} | g.downstream(b)
                (yes if ap == "yes" else no).update(tgt)
            followup_only_new |= (no - yes)

    def skip_flag(n):
        return bool((n.get("params") or {}).get("skipOnFollowup")) or n["id"] in followup_only_new

    ctx_nodes = [by_id[i] for i in order if key_of(by_id[i]) in CONTEXT_KEYS]
    if ctx_nodes:
        run = ["preflight.sh", "--stage", "context"]
        for n in ctx_nodes:
            k = key_of(n)
            if k == "prep.research":
                run += ["--research", "always"]
                pf = prompt_file(n)
                if pf:
                    run += ["--research-prompt", pf]
            if k == "prep.design":
                run += ["--design", "always"]
                pf = prompt_file(n)
                if pf:
                    run += ["--design-prompt", pf]
        positions = [by_id[i] for i in order if key_of(by_id[i]) == "prep.position"]
        pp = next((prompt_file(p) for p in positions if prompt_file(p)), None)
        if pp:
            run += ["--peer-prompt", pp]
        sid = "context"
        stages.append({"id": sid, "node": ctx_nodes[0]["id"], "nodes": [n["id"] for n in ctx_nodes],
                       "title": "neutral context", "run": run})
        for n in ctx_nodes:
            node_stage[n["id"]] = sid

    positions = [by_id[i] for i in order if key_of(by_id[i]) == "prep.position"]
    by_level = {}
    for p in positions:
        by_level.setdefault(level.get(p["id"], 0), []).append(p)
    for lv in sorted(by_level):
        grp = by_level[lv]
        for p in grp:
            eng = (p.get("params") or {}).get("engine", "claude")
            st = {"id": p["id"], "node": p["id"], "title": "%s's independent position" % eng.capitalize(),
                  "run": ["preflight.sh", "--stage", "peer", "--engine", eng], "optional": True}
            if len(grp) > 1:
                st["group"] = "peers-%d" % lv if len(by_level) > 1 else "peers"
            if skip_flag(p):
                st["skip_when_followup"] = True
            stages.append(st)
            node_stage[p["id"]] = p["id"]

    for i in order:
        n = by_id[i]
        k = key_of(n)
        if k == "prep.align":
            run = ["preflight.sh", "--stage", "align"]
            pf = prompt_file(n)
            if pf:
                run += ["--prompt", pf]
            st = {"id": n["id"], "node": n["id"], "title": "material deltas and acceptance checks", "run": run, "optional": True}
            if skip_flag(n):
                st["skip_when_followup"] = True
            stages.append(st)
            node_stage[n["id"]] = n["id"]

    brief = {"extra": None, "research": False, "skills": []}
    agent = next((by_id[i] for i in order if key_of(by_id[i]) in ("agent.claude", "agent.researcher")), None)
    compose = next((by_id[i] for i in order if key_of(by_id[i]) == "prep.compose"), None)
    if compose is not None or agent is not None:
        sid = compose["id"] if compose is not None else "compose"
        stages.append({"id": sid, "node": compose["id"] if compose is not None else None, "title": "the prompt the worker receives",
                       "run": ["pipeline-compose.sh"]})
        if compose is not None:
            node_stage[compose["id"]] = sid
            if (compose.get("prompt") or "").strip():
                brief["extra"] = prompt_file(compose)
    gates = {"review": False, "maxRounds": REVIEW_DEFAULT, "reportReview": False, "reportMaxRounds": 2,
             "requiredSkills": [], "research": False, "reviewExtra": None, "reportCriteria": None}
    if agent is not None:
        stages.append({"id": agent["id"], "node": agent["id"], "title": "hand it to the worker", "run": ["pipeline-deliver.sh"]})
        node_stage[agent["id"]] = agent["id"]
        ups = [by_id[u] for u in g.upstream(agent["id"]) if u in by_id]
        gates["requiredSkills"] = [str((u.get("params") or {}).get("skill")).strip() for u in ups if key_of(u) == "skill.require"]
        brief["skills"] = list(gates["requiredSkills"])
        if key_of(agent) == "agent.researcher":
            gates["research"] = True
            brief["research"] = True
        for d in g.downstream(agent["id"]):
            dn = by_id.get(d)
            if key_of(dn) == "gate.review":
                gates["review"] = True
                if (dn.get("prompt") or "").strip():
                    gates["reviewExtra"] = prompt_file(dn)
            if key_of(dn) == "gate.reportReview":
                gates["reportReview"] = True
                if (dn.get("prompt") or "").strip():
                    gates["reportCriteria"] = prompt_file(dn)
        for e in m.get("edges") or []:
            if e.get("loop") and split(e.get("to"))[0] == agent["id"]:
                src = key_of(by_id.get(split(e.get("from"))[0]) or {})
                mx = int((e.get("loop") or {}).get("max") or 0)
                if src == "gate.review":
                    gates["maxRounds"] = max(1, min(REVIEW_CEILING, mx))
                if src == "gate.reportReview":
                    gates["reportMaxRounds"] = max(1, min(REVIEW_CEILING, mx))
    for n in m.get("nodes") or []:
        node_stage.setdefault(n["id"], None)
    return {"name": m.get("id"), "description": m.get("description", ""), "source": "manifest",
            "revision": m.get("revision", 1), "stages": stages, "needs": v["needs"], "gates": gates,
            "brief": brief, "node_stage": node_stage, "unverified": v["unverified"]}


# ── RFC 6902 ─────────────────────────────────────────────────────────────────────────────────

class PatchError(Exception):
    def __init__(self, code, msg, path=None):
        Exception.__init__(self, msg)
        self.code = code
        self.path = path


def _ptr(path):
    if path == "":
        return []
    if not path.startswith("/"):
        raise PatchError("bad-path", "path must start with /: " + path, path)
    return [s.replace("~1", "/").replace("~0", "~") for s in path[1:].split("/")]


def apply_patch(doc, ops):
    out = copy.deepcopy(doc)
    for i, op in enumerate(ops):
        if not isinstance(op, dict) or "op" not in op or "path" not in op:
            raise PatchError("bad-op", "operation %d is malformed" % (i + 1))
        parts = _ptr(op["path"])
        if not parts:
            raise PatchError("bad-path", "the whole document cannot be the target", op["path"])
        last = parts.pop()
        parent = out
        for p in parts:
            if isinstance(parent, list):
                try:
                    parent = parent[int(p)]
                except (ValueError, IndexError):
                    raise PatchError("bad-path", "no %s" % op["path"], op["path"])
            elif isinstance(parent, dict) and p in parent:
                parent = parent[p]
            else:
                raise PatchError("bad-path", "no %s" % op["path"], op["path"])
        is_list = isinstance(parent, list)
        if is_list:
            if last == "-":
                idx = len(parent)
            else:
                try:
                    idx = int(last)
                except ValueError:
                    raise PatchError("bad-path", "index %s" % last, op["path"])
        kind = op["op"]
        if kind == "test":
            try:
                cur = parent[idx] if is_list else parent[last]
            except (IndexError, KeyError, TypeError):
                cur = None
            if json.dumps(cur, sort_keys=True) != json.dumps(op.get("value"), sort_keys=True):
                raise PatchError("test-failed", "test %s: expected %s, found %s" % (op["path"], json.dumps(op.get("value"), ensure_ascii=False), json.dumps(cur, ensure_ascii=False)), op["path"])
        elif kind == "add":
            if is_list:
                if idx < 0 or idx > len(parent):
                    raise PatchError("bad-path", "index %d out of range" % idx, op["path"])
                parent.insert(idx, copy.deepcopy(op.get("value")))
            elif isinstance(parent, dict):
                parent[last] = copy.deepcopy(op.get("value"))
            else:
                raise PatchError("bad-path", "cannot add into %s" % op["path"], op["path"])
        elif kind == "remove":
            try:
                if is_list:
                    del parent[idx]
                else:
                    del parent[last]
            except (IndexError, KeyError, TypeError):
                raise PatchError("bad-path", "no %s" % op["path"], op["path"])
        elif kind == "replace":
            exists = (0 <= idx < len(parent)) if is_list else (isinstance(parent, dict) and last in parent)
            if not exists:
                raise PatchError("bad-path", "no %s" % op["path"], op["path"])
            if is_list:
                parent[idx] = copy.deepcopy(op.get("value"))
            else:
                parent[last] = copy.deepcopy(op.get("value"))
        else:
            raise PatchError("bad-op", "unknown operation " + str(kind))
    return out


# ── packages on disk ─────────────────────────────────────────────────────────────────────────

def _read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def load_package(d):
    """Description with prompts inline and positions merged in, the shape every editor works on."""
    m = _read_json(os.path.join(d, "pipeline.json"))
    lay = {}
    lp = os.path.join(d, "layout.json")
    if os.path.exists(lp):
        try:
            lay = (_read_json(lp).get("nodes") or {})
        except (OSError, ValueError):
            lay = {}
    for n in m.get("nodes") or []:
        pr = n.get("prompt")
        if isinstance(pr, str) and pr.startswith("prompts/") and pr.endswith(".md"):
            safe = os.path.normpath(os.path.join(d, pr))
            if safe.startswith(os.path.normpath(d) + os.sep) and os.path.exists(safe):
                with open(safe, encoding="utf-8") as fh:
                    n["prompt"] = fh.read()
            else:
                n["prompt"] = ""
        pos = lay.get(n.get("id"))
        if isinstance(pos, dict) and "x" in pos and "y" in pos:
            n["x"], n["y"] = pos["x"], pos["y"]
    return m


def to_files(m):
    man = copy.deepcopy(m)
    layout = {"schema": LAYOUT_SCHEMA, "nodes": {}}
    prompts = {}
    for n in man.get("nodes") or []:
        if "x" in n or "y" in n:
            layout["nodes"][n["id"]] = {"x": n.pop("x", 0), "y": n.pop("y", 0)}
        if "prompt" in n:
            text = n.pop("prompt") or ""
            if text.strip():
                prompts[n["id"]] = text
                n["prompt"] = "prompts/%s.md" % n["id"]
    return man, layout, prompts


def semantic(m):
    """What runs, without layout or the revision counter: two descriptions equal here run the same."""
    man, _, prompts = to_files(m)
    man.pop("revision", None)
    return json.dumps([man, prompts], sort_keys=True, ensure_ascii=False)


def save_package(d, m):
    man, layout, prompts = to_files(m)
    os.makedirs(os.path.join(d, "prompts"), exist_ok=True)
    for name in os.listdir(os.path.join(d, "prompts")):
        if name.endswith(".md") and name[:-3] not in prompts:
            os.remove(os.path.join(d, "prompts", name))
    for nid, text in prompts.items():
        _atomic_write(os.path.join(d, "prompts", nid + ".md"), text)
    _atomic_write(os.path.join(d, "layout.json"), json.dumps(layout, ensure_ascii=False, indent=2) + "\n")
    _atomic_write(os.path.join(d, "pipeline.json"), json.dumps(man, ensure_ascii=False, indent=2) + "\n")


class Lock(object):
    """One writer per package. mkdir either creates or fails — no window between asking and having."""

    def __init__(self, d):
        self.path = os.path.join(d, ".lock")

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        deadline = time.time() + 10
        while True:
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > 60:
                        os.rmdir(self.path)
                        continue
                except OSError:
                    pass
                if time.time() > deadline:
                    raise PatchError("busy", "another writer holds this pipeline")
                time.sleep(0.05)

    def __exit__(self, *a):
        try:
            os.rmdir(self.path)
        except OSError:
            pass


class _NoLock(object):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def user_dir(pid):
    if not ID_RE.match(pid or ""):
        raise PatchError("bad-id", "bad pipeline id: %r" % pid)
    return os.path.join(USER_DIR, pid)


def builtin_dir(pid):
    return os.path.join(BUILTIN_DIR, pid)


def find(pid):
    """(kind, dir) for a description that can be shown or duplicated; built-ins are read-only."""
    if ID_RE.match(pid or "") and os.path.exists(os.path.join(builtin_dir(pid), "pipeline.json")):
        return "builtin", builtin_dir(pid)
    if ID_RE.match(pid or "") and os.path.exists(os.path.join(user_dir(pid), "pipeline.json")):
        return "user", user_dir(pid)
    return None, None


def resolve(name):
    """What pipeline.sh should execute for `name`. Built-ins keep their proven stage lists."""
    if not ID_RE.match(name or ""):
        return None, None
    legacy = os.path.join(LEGACY_DIR, name + ".json")
    if os.path.exists(legacy):
        return "legacy", legacy
    d = user_dir(name)
    if os.path.exists(os.path.join(d, "pipeline.json")):
        return "manifest", d
    return None, None


def summary(kind, d):
    try:
        m = load_package(d)
    except (OSError, ValueError) as e:
        return {"id": os.path.basename(d), "kind": kind, "broken": str(e)}
    v = validate(m)
    return {"id": m.get("id") or os.path.basename(d), "kind": kind, "name": m.get("name"), "description": m.get("description", ""),
            "revision": m.get("revision", 1), "version": m.get("version"), "origin": m.get("origin"), "builtin": kind == "builtin",
            "armed": m.get("armed", True), "nodes": len(m.get("nodes") or []),
            "steps": [key_of(n) for n in (m.get("nodes") or [])],
            "errors": sum(1 for i in v["issues"] if i["level"] == "error"),
            "warnings": sum(1 for i in v["issues"] if i["level"] == "warn"),
            "guarantees": v["guarantees"], "needs": v["needs"], "executes": m.get("executes"), "i18n": m.get("i18n"),
            "hidden": m.get("hidden"),
            "updated": os.path.getmtime(os.path.join(d, "pipeline.json"))}


def list_all():
    out = []
    for kind, base in (("builtin", BUILTIN_DIR), ("user", USER_DIR)):
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            d = os.path.join(base, name)
            if ID_RE.match(name) and os.path.exists(os.path.join(d, "pipeline.json")):
                out.append(summary(kind, d))
    return out


# ── evidence that a required skill was used ──────────────────────────────────────────────────

def _ts(s):
    """ISO-8601 (with Z or offset) → epoch seconds; None when unreadable."""
    if not s:
        return None
    import datetime
    t = str(s).strip().replace("Z", "+00:00")
    if "." in t:
        head, _, rest = t.partition(".")
        frac = ""
        tail = ""
        for i, ch in enumerate(rest):
            if ch.isdigit():
                frac += ch
            else:
                tail = rest[i:]
                break
        t = head + ("." + frac[:6] if frac else "") + tail
    try:
        d = datetime.datetime.fromisoformat(t)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d.timestamp()


def _skill_matches(called, wanted):
    called = (called or "").strip().lstrip("/")
    return called == wanted or called.split(":")[-1] == wanted.split(":")[-1]


def skill_evidence(transcript, since, wanted):
    """Which of `wanted` were called through the Skill tool, successfully, at or after `since`.

    Only the transcript of THIS session counts, and only a call whose result came back without an
    error: a call that failed applied nothing. A skill the director typed as a slash command shows
    up as a command in a user turn and counts the same way.
    """
    since_ts = _ts(since) if since else None
    calls = {}
    found = {}
    try:
        fh = open(transcript, encoding="utf-8", errors="replace")
    except OSError:
        return {"found": {}, "missing": list(wanted), "readable": False}
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            at = _ts(o.get("timestamp"))
            if since_ts is not None and at is not None and at + 1 < since_ts:
                continue
            msg = o.get("message") or {}
            content = msg.get("content")
            if isinstance(content, str) and o.get("type") == "user":
                for w in wanted:
                    if ("<command-name>/%s</command-name>" % w) in content or ("<command-name>%s</command-name>" % w) in content:
                        found.setdefault(w, {"via": "command", "at": o.get("timestamp")})
                continue
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use" and c.get("name") == "Skill":
                    inp = c.get("input") or {}
                    calls[c.get("id")] = {"skill": inp.get("skill") or inp.get("name") or inp.get("command"), "at": o.get("timestamp")}
                elif c.get("type") == "tool_result" and c.get("tool_use_id") in calls and not c.get("is_error"):
                    call = calls[c.get("tool_use_id")]
                    for w in wanted:
                        if _skill_matches(call["skill"], w):
                            found.setdefault(w, {"via": "Skill", "tool_use_id": c.get("tool_use_id"), "at": call["at"]})
    return {"found": found, "missing": [w for w in wanted if w not in found], "readable": True}


# ── the report a research run produced ───────────────────────────────────────────────────────

REPORT_EXT = (".html", ".htm", ".md", ".markdown", ".txt", ".pdf")


def find_report(cwd, summary, since):
    """The report this run wrote: the path the worker named, else the newest one it left in artifacts/."""
    root = os.path.realpath(cwd)
    for m in re.finditer(r"((?:/[^\s'\"`]+)?artifacts/[^\s'\"`]+?\.(?:html?|md|markdown|txt|pdf))", summary or ""):
        cand = m.group(1)
        p = cand if cand.startswith("/") else os.path.join(root, cand)
        p = os.path.realpath(p)
        if (p == root or p.startswith(root + os.sep)) and os.path.isfile(p):
            return p
    since_ts = _ts(since) if since else None
    art = os.path.join(root, "artifacts")
    best, best_m = None, -1
    if os.path.isdir(art):
        for dp, dn, fn in os.walk(art):
            dn[:] = [d for d in dn if not d.startswith(".")]
            for f in fn:
                if not f.lower().endswith(REPORT_EXT):
                    continue
                fp = os.path.join(dp, f)
                try:
                    mt = os.path.getmtime(fp)
                except OSError:
                    continue
                if since_ts is not None and mt + 60 < since_ts:
                    continue
                if mt > best_m:
                    best, best_m = fp, mt
    return best


def report_text(path, limit=60000):
    """What a reviewer reads: text, not markup. Scripts and styles are dropped, never executed."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read(4 * limit)
    except OSError:
        return ""
    text = raw.decode("utf-8", errors="replace")
    if path.lower().endswith((".html", ".htm")):
        from html.parser import HTMLParser

        class P(HTMLParser):
            def __init__(self):
                HTMLParser.__init__(self)
                self.out, self.skip = [], 0

            def handle_starttag(self, tag, attrs):
                if tag in ("script", "style", "svg"):
                    self.skip += 1
                if tag in ("p", "li", "tr", "h1", "h2", "h3", "h4", "div", "br", "section"):
                    self.out.append("\n")
                if tag == "a":
                    href = dict(attrs).get("href")
                    if href and href.startswith("http"):
                        self.out.append(" [%s] " % href)

            def handle_endtag(self, tag):
                if tag in ("script", "style", "svg") and self.skip:
                    self.skip -= 1

            def handle_data(self, data):
                if not self.skip:
                    self.out.append(data)

        p = P()
        p.feed(text)
        text = re.sub(r"\n\s*\n+", "\n\n", "".join(p.out))
    return text[:limit]


# ── sharing ──────────────────────────────────────────────────────────────────────────────────

PACKAGE_FILES = ("pipeline.json", "layout.json", "README.md")


def package_files(d):
    """The files a package may carry, and the ones it may not. Only description, layout, prompts
    and a readme ever leave the quarantine: a pipeline is data, and anything runnable in the
    folder is somebody else's code that has no business on this machine."""
    keep, other = [], []
    root = os.path.realpath(d)
    for base, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x != ".git"]
        for f in files:
            full = os.path.join(base, f)
            rel = os.path.relpath(full, d)
            real = os.path.realpath(full)
            if os.path.islink(full) or not real.startswith(root + os.sep):
                other.append(rel)
            elif rel in PACKAGE_FILES or (rel.startswith("prompts" + os.sep) and rel.endswith(".md") and rel.count(os.sep) == 1):
                keep.append(rel)
            else:
                other.append(rel)
    return sorted(keep), sorted(other)


def find_package(root, sub=None):
    """The folder holding pipeline.json: the one named, the root, or the only one below it."""
    if sub:
        cand = os.path.realpath(os.path.join(root, sub))
        if not cand.startswith(os.path.realpath(root) + os.sep) and cand != os.path.realpath(root):
            raise PatchError("bad-path", "the path leaves the downloaded folder")
        if os.path.exists(os.path.join(cand, "pipeline.json")):
            return cand, []
        raise PatchError("not-found", "no pipeline.json in %s" % sub)
    if os.path.exists(os.path.join(root, "pipeline.json")):
        return root, []
    found = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git" and not x.startswith(".")]
        if "pipeline.json" in files:
            found.append(os.path.relpath(base, root))
    if len(found) == 1:
        return os.path.join(root, found[0]), found
    return None, sorted(found)


def skills_of(m):
    return sorted({str((n.get("params") or {}).get("skill") or "").strip() for n in m.get("nodes") or []
                   if key_of(n) == "skill.require" and str((n.get("params") or {}).get("skill") or "").strip()})


HOME_RE = re.compile(r"/Users/[^\s/\"']+")


def scrub(m):
    """A copy fit to leave this machine: home paths become ~, his own bookkeeping goes."""
    out = copy.deepcopy(m)
    replaced = 0
    for n in out.get("nodes") or []:
        for k in ("title", "prompt"):
            v = n.get(k)
            if isinstance(v, str) and HOME_RE.search(v):
                n[k], c = HOME_RE.subn("~", v)
                replaced += c
        for pk, pv in list((n.get("params") or {}).items()):
            if isinstance(pv, str) and HOME_RE.search(pv):
                n["params"][pk], c = HOME_RE.subn("~", pv)
                replaced += c
    for k in ("acks", "armed", "builtin", "executes", "hidden"):
        out.pop(k, None)
    if (out.get("origin") or {}).get("kind") != "github":
        out.pop("origin", None)
    return out, replaced


def readme(m, v):
    lines = ["# %s" % (m.get("name") or m.get("id")), ""]
    if m.get("description"):
        lines += [m["description"], ""]
    en = ((m.get("i18n") or {}).get("en") or {}).get("description")
    if en and en != m.get("description"):
        lines += [en, ""]
    lines += ["A pipeline for [Bulava](https://github.com/Stepanokdev/bulava): what a message goes through before and after the worker has it.", ""]
    lines += ["## Steps", ""]
    order = _topo(m)[0]
    by_id = dict((n["id"], n) for n in m.get("nodes") or [])
    for nid in order:
        n = by_id.get(nid)
        if not n:
            continue
        mod = REG.get(key_of(n)) or {}
        lines.append("- **%s** — %s" % (n.get("title") or (mod.get("t") or {}).get("en", nid), (mod.get("t") or {}).get("en", key_of(n))))
    sk = skills_of(m)
    if sk:
        lines += ["", "## Skills it requires", ""] + ["- `%s`" % x for x in sk]
    if v.get("needs"):
        lines += ["", "## Needs", ""] + ["- %s" % x for x in v["needs"]]
    lines += ["", "## Import", "", "In Bulava: Pipelines → Import → paste this repository's address.",
              "It arrives switched off: read it, then switch it on.", ""]
    return "\n".join(lines)


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────

def emit(obj, code=0):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.exit(code)


def fail(msg, exit_code=2, **extra):
    d = {"ok": False, "error": msg}
    d.update(extra)
    sys.stdout.write(json.dumps(d, ensure_ascii=False) + "\n")
    sys.stderr.write(msg + "\n")
    sys.exit(exit_code)


def read_input(arg):
    if arg in (None, "-"):
        return json.load(sys.stdin)
    if os.path.isdir(arg):
        return load_package(arg)
    return _read_json(arg)


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]

    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            val = args[i + 1] if i + 1 < len(args) else default
            del args[i:i + 2]
            return val
        return default

    def flag(name):
        if name in args:
            args.remove(name)
            return True
        return False

    if cmd == "registry":
        emit({"schema": SCHEMA, "engine_module_major": ENGINE_MODULE_MAJOR, "review_ceiling": REVIEW_CEILING,
              "review_default": REVIEW_DEFAULT, "types": TYPES, "modules": REG})
    if cmd == "validate":
        draft = flag("--draft")
        try:
            m = read_input(args[0] if args else "-")
        except (OSError, ValueError) as e:
            fail("cannot read the description: %s" % e)
        v = validate(m, require_exec=not draft)
        v["ok"] = not any(i["level"] == "error" for i in v["issues"])
        emit(v, 0 if v["ok"] else 1)
    if cmd == "compile":
        out = opt("--out")
        snap = opt("--snapshot")
        if not args or not out:
            fail("usage: compile <dir> --out FILE [--snapshot DIR]")
        src = args[0]
        try:
            m = load_package(src)
        except (OSError, ValueError) as e:
            fail("cannot read %s: %s" % (src, e), 3)
        prompt_dir = None
        if snap:
            # The run reads its own copy: an edit saved while it prepares changes the NEXT run.
            if os.path.exists(snap):
                shutil.rmtree(snap)
            shutil.copytree(src, snap, ignore=shutil.ignore_patterns(".lock", ".tmp-*"))
            prompt_dir = os.path.join(snap, "prompts")
            os.makedirs(prompt_dir, exist_ok=True)
            # prompts written inline (old copies) are materialised so the stages can name a file
            for n in m.get("nodes") or []:
                if (n.get("prompt") or "").strip() and not os.path.exists(os.path.join(prompt_dir, n["id"] + ".md")):
                    _atomic_write(os.path.join(prompt_dir, n["id"] + ".md"), n["prompt"])
        try:
            c = compile_manifest(m, prompt_dir)
        except ValueError as e:
            fail("invalid pipeline: %s" % e, 4)
        _atomic_write(out, json.dumps(c, ensure_ascii=False, indent=2) + "\n")
        emit({"ok": True, "out": out, "stages": [s["id"] for s in c["stages"]], "needs": c["needs"]})
    if cmd in ("resolve", "check", "needs"):
        name = args[0] if args else ""
        kind, path = resolve(name)
        if not kind:
            msg = "Пайплайн «%s» не знайдено." % name
            if cmd == "check":
                sys.stderr.write(msg + "\n")
                return 3
            fail(msg, 3)
        if cmd == "resolve":
            sys.stdout.write("%s:%s\n" % (kind, path))
            return 0
        if kind == "legacy":
            needs = ["codex"] if name in ("dispatch", "adaptive-peer") else []
            if cmd == "needs":
                emit({"ok": True, "needs": needs})
            return 0
        try:
            m = load_package(path)
        except (OSError, ValueError) as e:
            if cmd == "check":
                sys.stderr.write("Пайплайн «%s» пошкоджено: %s\n" % (name, e))
                return 4
            fail(str(e), 4)
        v = validate(m)
        if cmd == "needs":
            emit({"ok": True, "needs": v["needs"]})
        if m.get("armed") is False:
            sys.stderr.write("Пайплайн «%s» ще не ввімкнено. Відкрий його в Булаві, переглянь і ввімкни.\n" % name)
            return 4
        errs = [i for i in v["issues"] if i["level"] == "error"]
        if errs:
            sys.stderr.write("Пайплайн «%s» не можна запустити: %s\n" % (name, "; ".join(i["msg"]["uk"] for i in errs)))
            return 4
        return 0
    if cmd == "default-prompt":
        key = args[0] if args else ""
        name = DEFAULT_PROMPTS.get(key)
        if not name:
            emit({"ok": True, "module": key, "prompt": ""})
        with open(os.path.join(ROOT, "supervisor", "prompts", name), encoding="utf-8") as fh:
            emit({"ok": True, "module": key, "prompt": fh.read(), "file": name})
    if cmd == "find-report":
        cwd = opt("--cwd") or "."
        p = find_report(cwd, opt("--summary") or "", opt("--since"))
        if not p:
            return 1
        sys.stdout.write(p + "\n")
        return 0
    if cmd == "report-text":
        mx = int(opt("--max") or 60000)
        sys.stdout.write(report_text(args[0] if args else "", mx))
        return 0
    if cmd == "skill-evidence":
        tr = opt("--transcript")
        since = opt("--since")
        names = [x for x in (opt("--skills") or "").split(",") if x.strip()]
        if not tr or not names:
            fail("usage: skill-evidence --transcript F --since ISO --skills a,b")
        r = skill_evidence(tr, since, [n.strip() for n in names])
        r["ok"] = not r["missing"]
        emit(r, 0 if r["ok"] else 1)
    if cmd == "list":
        emit({"ok": True, "pipelines": list_all()})
    if cmd == "show":
        kind, d = find(args[0] if args else "")
        if not kind:
            fail("no such pipeline", 3)
        m = load_package(d)
        v = validate(m)
        emit({"ok": True, "kind": kind, "pipeline": m, "validation": v})
    if cmd == "save":
        pid = args[0] if args else ""
        expect = opt("--expect-revision")
        src_in = opt("--in")
        try:
            d = user_dir(pid)
            m = _read_json(src_in) if src_in else json.load(sys.stdin)
        except (PatchError, ValueError) as e:
            fail(str(e))
        if pid in LEGACY_NAMES or os.path.exists(os.path.join(builtin_dir(pid), "pipeline.json")):
            fail("built-in pipelines are read-only; duplicate it", 5)
        m["id"] = pid
        m.setdefault("schema", SCHEMA)
        with Lock(d):
            cur = None
            if os.path.exists(os.path.join(d, "pipeline.json")):
                cur = load_package(d)
            cur_rev = int((cur or {}).get("revision") or 0)
            if expect is not None and int(expect) != cur_rev:
                fail("stale: the description is at revision %d, not %s" % (cur_rev, expect), 6, revision=cur_rev, code="stale")
            # Positions alone are layout and do not count as a change to what runs.
            m["revision"] = cur_rev if (cur is not None and semantic(cur) == semantic(m)) else cur_rev + 1
            save_package(d, m)
        v = validate(m, require_exec=False)
        emit({"ok": True, "revision": m["revision"], "validation": v})
    if cmd == "patch":
        pid = args[0] if args else ""
        dry = flag("--dry-run")
        src_in = opt("--in")
        try:
            ops = _read_json(src_in) if src_in else json.load(sys.stdin)
            kind, d = find(pid)
        except (PatchError, ValueError) as e:
            fail(str(e))
        if kind is None:
            fail("no such pipeline", 3)
        if kind == "builtin" and not dry:
            fail("built-in pipelines are read-only; duplicate it", 5)
        with (Lock(d) if kind == "user" else _NoLock()):
            cur = load_package(d)
            try:
                nxt = apply_patch(cur, ops)
            except PatchError as e:
                fail(str(e), 6 if e.code == "test-failed" else 2, code=e.code, path=e.path, revision=cur.get("revision", 1))
            before = [i["code"] + json.dumps(i["msg"], sort_keys=True) for i in validate(cur, require_exec=False)["issues"] if i["level"] == "error"]
            v = validate(nxt, require_exec=False)
            new_errors = [i for i in v["issues"] if i["level"] == "error" and i["code"] + json.dumps(i["msg"], sort_keys=True) not in before]
            if dry:
                emit({"ok": not new_errors, "pipeline": nxt, "validation": v, "new_errors": new_errors, "revision": cur.get("revision", 1)})
            if new_errors:
                fail("the change would break the pipeline: " + "; ".join(i["msg"]["uk"] for i in new_errors), 7, new_errors=new_errors)
            nxt["revision"] = int(cur.get("revision") or 0) + 1
            save_package(d, nxt)
        emit({"ok": True, "revision": nxt["revision"], "validation": v})
    if cmd == "duplicate":
        if len(args) < 2:
            fail("usage: duplicate <src> <new-id> [--name N]")
        name = opt("--name")
        src, new = args[0], args[1]
        kind, d = find(src)
        if kind is None:
            fail("no such pipeline", 3)
        try:
            nd = user_dir(new)
        except PatchError as e:
            fail(str(e))
        if os.path.exists(nd) or new in LEGACY_NAMES or os.path.exists(os.path.join(builtin_dir(new), "pipeline.json")):
            fail("a pipeline with this id already exists", 5)
        m = load_package(d)
        m["id"] = new
        m["name"] = name or (m.get("name", src) + " — копія")
        m.pop("builtin", None)
        m.pop("executes", None)
        m["armed"] = False if (m.get("origin") or {}).get("kind") in IMPORTED and not m.get("armed") else m.get("armed", True)
        m["origin"] = {"kind": "fork", "of": src, "ofRevision": m.get("revision", 1)}
        m["revision"] = 1
        with Lock(nd):
            save_package(nd, m)
        emit({"ok": True, "id": new, "revision": 1})
    if cmd == "delete":
        pid = args[0] if args else ""
        try:
            d = user_dir(pid)
        except PatchError as e:
            fail(str(e))
        if not os.path.exists(d):
            fail("no such pipeline", 3)
        trash = os.path.join(STATE, "pipelines-trash", "%s-%d" % (pid, int(time.time())))
        os.makedirs(os.path.dirname(trash), exist_ok=True)
        shutil.move(d, trash)
        emit({"ok": True, "trash": trash})
    if cmd == "inspect":
        sub = opt("--path")
        root = args[0] if args else ""
        if not os.path.isdir(root):
            fail("no such folder", 3)
        try:
            d, candidates = find_package(root, sub)
        except PatchError as e:
            fail(str(e), 3)
        if d is None:
            fail("no single pipeline.json here", 9, candidates=candidates)
        try:
            m = load_package(d)
        except (OSError, ValueError) as e:
            fail("cannot read the description: %s" % e, 4)
        keep, other = package_files(d)
        v = validate(m, require_exec=True)
        emit({"ok": True, "dir": d, "pipeline": m, "validation": v, "files": keep, "ignored": other,
              "skills": skills_of(m), "secrets": any(i["code"] == "V8" for i in v["issues"])})
    if cmd == "install":
        origin_file = opt("--origin")
        if len(args) < 2:
            fail("usage: install <dir> <id> --origin FILE")
        src, pid = args[0], args[1]
        try:
            nd = user_dir(pid)
        except PatchError as e:
            fail(str(e))
        if os.path.exists(nd) or pid in LEGACY_NAMES or os.path.exists(os.path.join(builtin_dir(pid), "pipeline.json")):
            fail("a pipeline with this id already exists", 5)
        m = load_package(src)
        v = validate(m, require_exec=False)
        if any(i["code"] == "V8" for i in v["issues"]):
            fail("the package carries something that looks like an access key", 8)
        origin = _read_json(origin_file) if origin_file else {}
        origin["kind"] = "github" if origin.get("repo") else "file"
        m["id"] = pid
        m["origin"] = origin
        m["armed"] = False
        m.pop("acks", None)
        m.pop("builtin", None)
        m.pop("executes", None)
        m["revision"] = 1
        with Lock(nd):
            save_package(nd, m)
        if os.path.exists(os.path.join(src, "README.md")):
            shutil.copyfile(os.path.join(src, "README.md"), os.path.join(nd, "README.md"))
        emit({"ok": True, "id": pid, "revision": 1})
    if cmd == "arm":
        pid = args[0] if args else ""
        try:
            d = user_dir(pid)
        except PatchError as e:
            fail(str(e))
        if not os.path.exists(os.path.join(d, "pipeline.json")):
            fail("no such pipeline", 3)
        with Lock(d):
            m = load_package(d)
            m["armed"] = True
            acks = m.get("acks") or {}
            acks["armed"] = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                             "sha": (m.get("origin") or {}).get("sha"), "revision": m.get("revision", 1)}
            m["acks"] = acks
            m["revision"] = int(m.get("revision") or 1) + 1
            save_package(d, m)
        emit({"ok": True, "revision": m["revision"]})
    if cmd == "export":
        out = opt("--out")
        pid = args[0] if args else ""
        if not out:
            fail("usage: export <id> --out DIR")
        kind, d = find(pid)
        if kind is None:
            fail("no such pipeline", 3)
        m = load_package(d)
        v = validate(m, require_exec=False)
        secrets = [i for i in v["issues"] if i["code"] == "V8"]
        if secrets:
            fail("it carries something that looks like an access key", 8, issues=secrets)
        clean, replaced = scrub(m)
        clean["id"] = pid
        dest = os.path.join(out, pid)
        if os.path.exists(dest) and os.listdir(dest):
            fail("the folder %s is not empty" % dest, 5, dir=dest)
        os.makedirs(dest, exist_ok=True)
        save_package(dest, clean)
        _atomic_write(os.path.join(dest, "README.md"), readme(clean, v))
        emit({"ok": True, "dir": dest, "replaced_paths": replaced, "files": package_files(dest)[0]})
    sys.stderr.write("unknown command: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
