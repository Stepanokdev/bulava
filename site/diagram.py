#!/usr/bin/env python3
"""The pipeline schemes — drawn as schemes, in ordinary elements.

An SVG would be the obvious choice and is the wrong one here. An SVG scales its text with its
box, so a diagram wide enough to read on a desktop is eight-point type on a phone; and every
label has to exist twice, once per language, in a form a translator can edit and a screen reader
can read. Elements do all of that for free — the text is text, it reflows, it inherits the page's
type scale — and everything a scheme needs beyond text is a line, an arrowhead and a diamond,
which CSS draws.

So: boxes in a lane, an arrow between every two of them, a diamond where the engine decides
something, a labelled branch for each way out of that decision, and a bracket where two things
happen at once. Same vocabulary as the deck, only it survives a 390px screen.

`today` is the flow the engine SHIPPED in the release the page offers, not what is in the working
tree. Every stage is traceable: the stage list comes from
`engine/supervisor/pipelines/adaptive-peer.json`, the branch at the top from `preflight.sh`
(a follow-up to an open task skips classification, research and the design precedent), and the
numbers on the review loop from `engine/supervisor/config.sh` — three rounds of patience, two
without progress parks it for a person, a ceiling of twelve, eight hours of rounds parks it too.

`console`, `v1` and `v2` are the versions that came before, kept because "how it works" is easier
to trust when the three worse answers it replaced are next to it.
"""

import html


def _esc(text):
    return html.escape(str(text), quote=True)


def _node(strings, key, *, accent=False, note=None, exit_=False, tail=None, start=False):
    """One box. `exit_` marks a way out that ENDS there; `note` is the condition on a stage."""
    title = _esc(strings[f"{key}.t"])
    detail = strings.get(f"{key}.d")
    classes = "node" + (" accent" if accent else "") + (" exit" if exit_ else "") \
        + (" start" if start else "")
    parts = [f'<div class="{classes}">', '<span class="pip" aria-hidden="true"></span>',
             f'<b>{title}</b>']
    if detail:
        parts.append(f"<small>{_esc(detail)}</small>")
    if note:
        parts.append(f'<em class="opt">{_esc(strings[note])}</em>')
    if tail:
        parts.append(f'<span class="tail">{_esc(strings[tail])}</span>')
    parts.append("</div>")
    return "".join(parts)


def _arrow():
    """A line with a head on it, down the middle. The only thing here that is drawn."""
    return '<div class="arrow" aria-hidden="true"></div>'


def _gate(strings, key):
    """A decision. A diamond on a wide screen, a plain box on a narrow one — the shape carries
    the meaning, and a diamond narrower than its own words carries nothing."""
    return ('<div class="gate"><div class="d"><div>'
            f'<span>{_esc(strings[key])}</span></div></div></div>')


def _legs(legs):
    """The ways out of a decision, side by side, each with the word that chooses it."""
    cells = "".join(
        f'<div class="leg"><span class="tag">{_esc(tag)}</span>{body}</div>'
        for tag, body in legs)
    return f'<div class="legs">{cells}</div>'


def _pair(strings, label, left, right):
    """Two things that happen at the same time, bracketed and said so."""
    return (f'<div class="pair"><span class="tag">{_esc(strings[label])}</span>'
            f'<div class="both">{left}{right}</div></div>')


def _lane(*parts):
    return '<div class="lane">' + "".join(parts) + "</div>"


def _scheme(label, body):
    return f'<div class="scheme" role="img" aria-label="{_esc(label)}">{body}</div>'


def _sequence(strings, keys):
    """The common case: boxes one after another, an arrow between each two."""
    out = []
    for i, key in enumerate(keys):
        if i:
            out.append(_arrow())
        out.append(_node(strings, key) if isinstance(key, str) else key)
    return out


def today(strings):
    """Message in, result out — the arrangement the downloadable release runs."""
    # A follow-up to an open task is not classified again and buys no new research: those answers
    # have not changed since the task began. Everything else comes in through the right-hand leg.
    new_task = _lane(
        _node(strings, "dg.t.classify"),
        _arrow(),
        _node(strings, "dg.t.ask", note="dg.when.unclear"),
        _arrow(),
        _pair(strings, "dg.t.before",
              _node(strings, "dg.t.design", note="dg.when.ui"),
              _node(strings, "dg.t.research", note="dg.when.needed")),
    )
    entry = _legs([
        (strings["dg.t.b.follow"], _node(strings, "dg.t.follow", tail="dg.t.rejoin")),
        (strings["dg.t.b.new"], new_task),
    ])

    # Blocked, or a decision only the director can take, is not a verdict of the review — it
    # happens while the work is being done, and it ends the run there.
    after_implement = _lane(
        _node(strings, "dg.t.consult", note="dg.when.hard"),
        _arrow(),
        _node(strings, "dg.t.review"),
        _arrow(),
        _gate(strings, "dg.t.q.verdict"),
        _legs([
            (strings["dg.t.b.pass"], _node(strings, "dg.t.done", accent=True)),
            (strings["dg.t.b.fail"], _node(strings, "dg.t.fix", tail="dg.t.loop")),
        ]),
    )

    body = _lane(
        _node(strings, "dg.t.msg", start=True),
        _arrow(),
        _gate(strings, "dg.t.q.entry"),
        entry,
        _arrow(),
        _node(strings, "dg.t.context"),
        _arrow(),
        _pair(strings, "dg.t.same.time",
              _node(strings, "dg.t.claude"),
              _node(strings, "dg.t.codex")),
        _arrow(),
        _node(strings, "dg.t.align"),
        _arrow(),
        _node(strings, "dg.t.implement"),
        _legs([
            (strings["dg.t.b.on"], after_implement),
            (strings["dg.t.b.stop"], _node(strings, "dg.t.stop", exit_=True)),
        ]),
    )
    return _scheme(strings["dg.t.alt"], body)


def console(strings):
    """The first arrangement: no application at all, two CLIs and a watchdog."""
    body = _lane(*_sequence(strings, [
        "dg.c.task", "dg.c.tmux", "dg.c.hook", "dg.c.persona", "dg.c.gate", "dg.c.limit",
    ]), _arrow(), _node(strings, "dg.c.branch", accent=True))
    return _scheme(strings["dg.c.alt"], body)


def v1(strings):
    """Version one: a plan, criticised once, then work."""
    body = _lane(*_sequence(strings, [
        "dg.1.task", "dg.1.classify", "dg.1.plan", "dg.1.critique", "dg.1.rewrite",
        "dg.1.code", "dg.1.review",
    ]), _arrow(), _node(strings, "dg.1.done", accent=True))
    return _scheme(strings["dg.1.alt"], body)


def v2(strings):
    """Version two: the two independent positions appear, and the open line to Codex."""
    body = _lane(
        _node(strings, "dg.2.task"),
        _arrow(),
        _node(strings, "dg.2.context"),
        _arrow(),
        _pair(strings, "dg.t.same.time",
              _node(strings, "dg.2.claude"),
              _node(strings, "dg.2.codex")),
        _arrow(),
        *_sequence(strings, ["dg.2.align", "dg.2.implement"]),
        _arrow(),
        _node(strings, "dg.2.consult", note="dg.when.hard"),
        _arrow(),
        *_sequence(strings, ["dg.2.checks", "dg.2.review"]),
        _arrow(),
        _node(strings, "dg.2.done", accent=True),
    )
    return _scheme(strings["dg.2.alt"], body)


def all_diagrams(lang, strings):
    return {"today": today(strings), "console": console(strings),
            "v1": v1(strings), "v2": v2(strings)}


# Declared rather than discovered: the renderer refuses a translation table with a key nothing
# uses, and these keys are used from here instead of from the template. Without the list, every
# diagram label looked like dead weight and the render stopped.
KEYS = [
    "dg.when.unclear", "dg.when.ui", "dg.when.needed", "dg.when.hard",
    "dg.t.alt", "dg.t.loop", "dg.t.rejoin",
    # the words on the branches, and the questions in the diamonds
    "dg.t.q.entry", "dg.t.q.verdict",
    "dg.t.b.follow", "dg.t.b.new", "dg.t.b.on", "dg.t.b.stop", "dg.t.b.pass", "dg.t.b.fail",
    "dg.t.same.time", "dg.t.before",
    "dg.t.msg.t", "dg.t.msg.d",
    "dg.t.follow.t", "dg.t.follow.d",
    "dg.t.new.t", "dg.t.new.d",
    "dg.t.classify.t", "dg.t.classify.d",
    "dg.t.ask.t", "dg.t.ask.d",
    "dg.t.design.t", "dg.t.design.d",
    "dg.t.research.t", "dg.t.research.d",
    "dg.t.context.t", "dg.t.context.d",
    "dg.t.claude.t", "dg.t.claude.d",
    "dg.t.codex.t", "dg.t.codex.d",
    "dg.t.align.t", "dg.t.align.d",
    "dg.t.implement.t", "dg.t.implement.d",
    "dg.t.consult.t", "dg.t.consult.d",
    "dg.t.review.t", "dg.t.review.d",
    "dg.t.stop.t", "dg.t.stop.d",
    "dg.t.fix.t", "dg.t.fix.d",
    "dg.t.done.t", "dg.t.done.d",
    "dg.c.alt",
    "dg.c.task.t", "dg.c.task.d", "dg.c.tmux.t", "dg.c.tmux.d",
    "dg.c.hook.t", "dg.c.hook.d", "dg.c.persona.t", "dg.c.persona.d",
    "dg.c.gate.t", "dg.c.gate.d", "dg.c.limit.t", "dg.c.limit.d",
    "dg.c.branch.t", "dg.c.branch.d",
    "dg.1.alt",
    "dg.1.task.t", "dg.1.classify.t", "dg.1.classify.d", "dg.1.plan.t",
    "dg.1.critique.t", "dg.1.critique.d", "dg.1.rewrite.t", "dg.1.code.t",
    "dg.1.review.t", "dg.1.review.d", "dg.1.done.t", "dg.1.done.d",
    "dg.2.alt",
    "dg.2.task.t", "dg.2.context.t", "dg.2.context.d",
    "dg.2.claude.t", "dg.2.claude.d", "dg.2.codex.t", "dg.2.codex.d",
    "dg.2.align.t", "dg.2.align.d", "dg.2.implement.t",
    "dg.2.consult.t", "dg.2.consult.d", "dg.2.checks.t", "dg.2.checks.d",
    "dg.2.review.t", "dg.2.review.d", "dg.2.done.t",
]
