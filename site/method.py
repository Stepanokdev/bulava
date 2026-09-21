#!/usr/bin/env python3
"""The methodology table, built from the measurement rather than written beside it.

A benchmark figure without the conditions it was taken under is a number, not a claim, and the
three test results on the page — 12/12, a passing verify.sh, 57/57 — were plain text that a
reader had no way to check. This turns each run into a row of facts somebody can act on: when it
ran, where the elapsed time came from, how much of the token count was re-reading cache, and the
SHA-256 of the artefact that is being served, so the thing linked from the page can be downloaded
and hashed.

It also says the one thing a number cannot: those test counts are what each project's own suite
reported at the end of its own run. They were read off the run. They were not re-run here, and
this page does not pretend otherwise.
"""

import html


def _esc(text):
    return html.escape(str(text), quote=True)


def methodology(strings, numbers, scenarios):
    rows = []
    for scenario in scenarios:
        key = scenario["key"]
        # Two digests, never one. The first is of the files the run produced; the second is of
        # what that address is serving, on the date it was last re-hashed. For one of the three
        # they are different builds, and collapsing them into a single "digest" row is how the
        # first draft of this section managed to contradict its own caveat.
        if scenario["served_matches_measured"]:
            served = (f'<b>{_esc(strings["bm.method.same"])}</b> — '
                      f'{_esc(strings["bm.method.rechecked"])} {_esc(scenario["served_checked"])}')
        else:
            served = (f'<b>{_esc(strings["bm.method.differs"])}</b> '
                      f'<code>{_esc(scenario["served_sha256"])}</code> — '
                      f'{_esc(strings["bm.method.rechecked"])} {_esc(scenario["served_checked"])}')
        cells = [
            (strings["bm.method.ran"],
             f'{_esc(scenario["ran_from"])} → {_esc(scenario["ran_to"])}'
             if scenario["ran_from"] else _esc(strings["bm.method.no_window"])),
            (strings["bm.method.timing"], _esc(strings["bm.timing." + scenario["timing_source"]])),
            (strings["bm.method.effort"], _esc(scenario["effort"])),
            (strings["bm.method.own"], f'<code>{_esc(scenario["own_tests"])}</code>'),
            (strings["bm.method.files"], _esc(scenario["measured_files"])),
            (strings["bm.method.digest"],
             f'<code class="digest">{_esc(scenario["measured_sha256"])}</code>'),
            (strings["bm.method.served"], served),
        ]
        body = "".join(
            f'<div><dt>{_esc(label)}</dt><dd>{value}</dd></div>' for label, value in cells)
        rows.append(
            f'<section class="method" id="method-{_esc(key)}">'
            f'<h3>{_esc(strings["bm.row." + key])}</h3>'
            f'<dl class="spec">{body}</dl>'
            f'<p class="method-note">{_esc(strings["bm.method.note." + key])}</p>'
            f'</section>')
    procedure = (
        f'<section class="method how">'
        f'<h3>{_esc(strings["bm.method.how.t"])}</h3>'
        f'<p>{_esc(strings["bm.method.how.d"])}</p>'
        f'<pre>{_esc(strings["bm.method.how.cmd"])}</pre>'
        f'<p class="method-note">{_esc(strings["bm.method.how.manifest"])} '
        f'<a href="/benchmark.json">/benchmark.json</a>.</p>'
        f'</section>')
    return ('<div class="methods">' + "".join(rows) + procedure + "</div>")


def metrics(strings, scenarios):
    """The comparison as the slide lays it out: one row per metric, three columns, winner in lime.

    A table rather than three cards, because the whole argument is a comparison — and the slide
    makes it by putting the same number in the same place three times. The last column is the one
    that won, so it carries the accent; the rest is the presentation's own order of metrics.
    """
    order = ["pure", "review", "peer"]
    by_key = {s["key"]: s for s in scenarios}
    rows = [
        (strings["bm.metric.time"], None,
         [f'{by_key[k]["hours"]:.1f}<span class="u">{_esc(strings["bm.unit.hours"])}</span>'
          for k in order]),
        (strings["bm.metric.tokens"], None,
         [f'{by_key[k]["tokens_millions"]:.1f}<span class="u">{_esc(strings["bm.unit.millions"])}</span>'
          for k in order]),
        (strings["bm.metric.effort"], strings["bm.metric.effort.sub"],
         [_esc(by_key[k]["effort"]) for k in order]),
        (strings["bm.metric.outcome"], None,
         [f'{_esc(by_key[k]["outcome_count"])}'
          f'<span class="w">{_esc(strings["bm.row." + k + ".bugs"])}</span>' for k in order]),
    ]
    head = "".join(f'<th scope="col"{" class=\"best\"" if k == "peer" else ""}>'
                   f'{_esc(strings["bm.col." + k])}</th>' for k in order)
    body = ""
    for label, sub, cells in rows:
        tds = "".join(f'<td{" class=\"best\"" if i == 2 else ""}>{c}</td>'
                      for i, c in enumerate(cells))
        note = f'<span>{_esc(sub)}</span>' if sub else ""
        body += f'<tr><th scope="row">{_esc(label)}{note}</th>{tds}</tr>'
    return (f'<div class="metrics"><table><thead><tr><td></td>{head}</tr></thead>'
            f'<tbody>{body}</tbody></table></div>')


# Declared for the renderer's translation-coverage check, the same way the diagrams declare theirs.
KEYS = [
    "bm.method.ran", "bm.method.timing", "bm.method.effort", "bm.method.own",
    "bm.method.files", "bm.method.digest", "bm.method.served",
    "bm.method.same", "bm.method.differs", "bm.method.no_window", "bm.method.rechecked",
    "bm.method.how.t", "bm.method.how.d", "bm.method.how.cmd", "bm.method.how.manifest",
    "bm.timing.session_log", "bm.timing.stage_clock",
    "bm.method.note.pure", "bm.method.note.review", "bm.method.note.peer",
    "bm.metric.time", "bm.metric.tokens", "bm.metric.effort", "bm.metric.outcome",
    "bm.metric.effort.sub", "bm.unit.hours", "bm.unit.millions",
    "bm.col.pure", "bm.col.review", "bm.col.peer",
    "bm.row.pure.bugs", "bm.row.review.bugs", "bm.row.peer.bugs",
]
