#!/usr/bin/env python3
"""Render a run report.json into a self-contained, theme-aware report.html.

Screenshots are inlined as data URIs so the file is portable on its own; video is
referenced relatively (media/<label>.mp4) since it is too large to inline, and
travels with the report folder.

The styling is the app's own report stylesheet, token for token — neutral surfaces
(paper on light, graphite on dark) and the brand lime as the only accent — because a
report that arrives looking like a different product reads as a different product.
The `b` in the header is the same geometry the app draws and the icon is cut from.
"""
import base64
import html
import json
import mimetypes
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brand  # noqa: E402  (needs the path above)

REPORT_DIR = os.environ["NS_REPORT_DIR"]
MEDIA_DIR = os.environ.get("NS_MEDIA_DIR", os.path.join(REPORT_DIR, "media"))

with open(os.path.join(REPORT_DIR, "report.json"), encoding="utf-8") as f:
    R = json.load(f)


def esc(x):
    return html.escape(str(x if x is not None else ""))


def data_uri(fname):
    # Manifest files are bare names living under MEDIA_DIR; report.html sits one
    # level up, so on-disk reads use MEDIA_DIR and href paths use "media/<name>".
    p = os.path.join(MEDIA_DIR, fname)
    if not os.path.isfile(p):
        return None
    mime = mimetypes.guess_type(p)[0] or "image/png"
    with open(p, "rb") as fh:
        return f"data:{mime};base64," + base64.b64encode(fh.read()).decode()


def media_for(label):
    """Return (screenshot_data_uri_or_None, video_href_or_None, note)."""
    shot = video = note = None
    for m in R.get("media", []):
        if m.get("label") != label:
            continue
        if m.get("kind") == "screenshot" and m.get("file"):
            shot = data_uri(m["file"])
        elif m.get("kind") == "video" and m.get("file"):
            video = "media/" + m["file"]
        elif m.get("kind") == "none":
            note = m.get("note")
    return shot, video, note


def frame(label, sub):
    shot, video, note = media_for(label)
    inner = ""
    if shot:
        inner += f'<img src="{shot}" alt="{esc(label)}"/>'
    if video:
        inner += (f'<video controls preload="metadata" src="{esc(video)}"></video>')
    if not shot and not video:
        inner = f'<div class="empty">{esc(note or "not captured")}</div>'
    return f'''<div class="shot">
      <div class="shot-head"><span class="tag">{esc(label)}</span><span class="shot-sub">{esc(sub)}</span></div>
      <div class="shot-body">{inner}</div>
    </div>'''


# --- pieces ------------------------------------------------------------------
ev = R.get("evidence")
ev_rows = ""
ev_summary = ""
if isinstance(ev, dict):
    crits = ev.get("criteria", [])
    passed = sum(1 for c in crits if c.get("status") == "pass" and c.get("exit_code") == 0)
    total = len(crits)
    overall = ev.get("overall_status", "—")
    ev_summary = f'{passed}/{total} checks · {esc(overall)}'
    for c in crits:
        st = c.get("status", "")
        dot = {"pass": "ok", "fail": "bad", "inconclusive": "warn"}.get(st, "warn")
        ev_rows += (f'<tr><td><span class="dot {dot}"></span>{esc(c.get("criterion"))}</td>'
                    f'<td class="mono">{esc(c.get("command"))}</td>'
                    f'<td class="mono r">{esc(c.get("exit_code"))}</td>'
                    f'<td class="st {dot}">{esc(st)}</td></tr>')

commits = R.get("commits", [])
commit_rows = "".join(
    f'<li><span class="mono sha">{esc(c.get("sha"))}</span><span>{esc(c.get("subject"))}</span></li>'
    for c in commits
)

t_what_done = "What was done"

# What this run really has. A block asking for something absent renders nothing at all.
before_src = media_for("before")[0]
after_src = media_for("after")[0]
video_src = next((("media/" + m["file"]) for m in R.get("media", [])
                  if m.get("kind") == "video" and m.get("file")), None)


def _card(eyebrow, inner, cls="card"):
    head = f'<div class="eyebrow">{esc(eyebrow)}</div>' if eyebrow else ""
    return f'<section class="{cls}">{head}{inner}</section>'


def _prose(text):
    # Blank-line separated paragraphs, so a writer's shape survives.
    paras = [p.strip() for p in (text or "").split("\n\n") if p.strip()]
    return "".join(f'<div class="prose dim">{esc(p)}</div>' for p in paras) or ""


def render_block(b):
    """One block of the writer's document, or "" when its data does not exist.

    An absent screenshot is not a section. The old renderer always drew a Before & after pane, so a
    backend change or a piece of research was shown with two "not captured" placeholders and read as
    a failure to take screenshots. Anything this function cannot ground in real data returns nothing.
    """
    if not isinstance(b, dict):
        return ""
    kind = str(b.get("type") or "").strip()
    heading = b.get("heading") or ""

    if kind == "prose":
        body = _prose(b.get("text"))
        return _card(heading, body) if body else ""

    if kind in ("bullets", "steps"):
        items = [i for i in (b.get("items") or []) if str(i).strip()]
        if not items:
            return ""
        tag = "ol" if kind == "steps" else "ul"
        rows = "".join(f"<li>{esc(i)}</li>" for i in items)
        return _card(heading, f'<{tag} class="doc">{rows}</{tag}>')

    if kind == "table":
        cols = [c for c in (b.get("columns") or []) if str(c).strip()]
        rows = [r for r in (b.get("rows") or []) if isinstance(r, list) and any(str(c).strip() for c in r)]
        if not rows:
            return ""
        head = "".join(f"<th>{esc(c)}</th>" for c in cols)
        body = "".join("<tr>" + "".join(f"<td>{esc(c)}</td>" for c in r) + "</tr>" for r in rows)
        thead = f"<thead><tr>{head}</tr></thead>" if head else ""
        return _card(heading, f'<table class="doc">{thead}<tbody>{body}</tbody></table>')

    if kind == "code":
        text = (b.get("text") or "").strip()
        return _card(heading, f'<pre class="doc">{esc(text)}</pre>') if text else ""

    if kind == "beforeAfter":
        if not (before_src and after_src):
            return ""
        cap = f'<div class="prose dim">{esc(b.get("caption"))}</div>' if b.get("caption") else ""
        return _card(heading or "Before & after",
                     f'{cap}<div class="ba">{frame("before", "at base " + (R.get("base_sha") or "")[:7])}'
                     f'{frame("after", "on " + (R.get("branch") or ""))}</div>')

    if kind == "media":
        label = (b.get("label") or "after").strip()
        src = {"before": before_src, "after": after_src}.get(label)
        if not src:
            return ""
        cap = f'<div class="prose dim">{esc(b.get("caption"))}</div>' if b.get("caption") else ""
        return _card(heading or label.capitalize(), f'{cap}<div class="ba one">{frame(label, "")}</div>')

    if kind == "video":
        if not video_src:
            return ""
        cap = f'<div class="prose dim">{esc(b.get("caption"))}</div>' if b.get("caption") else ""
        return _card(heading or "Recording",
                     f'{cap}<video class="vid" controls src="{esc(video_src)}"></video>')

    if kind == "commits":
        return _card(heading or "Commits", f'<ul class="commits">{commit_rows}</ul>') if commit_rows else ""

    if kind == "evidence":
        return _card(heading or "Machine evidence", f"<table class='ev'>{ev_rows}</table>") if ev_rows else ""

    if kind == "findings":
        return _card(heading or "Noticed along the way",
                     f'<ul class="finds">{finding_rows}</ul>') if finding_rows else ""

    return ""


stack_chips = "".join(f'<span class="chip">{esc(s)}</span>' for s in R.get("stacks", []))



# What the run noticed OUTSIDE its own fence. These used to be materialised as cards in the
# director's feed, each with a "start this" button — so one task he asked for came back as four
# he had to triage, titled with code fragments. They belong to the run that noticed them.
# The kind is named in words: `needs_scope` is the channel's vocabulary, not his.
FINDING_KIND = {
    "blocker": "блокер", "needs_scope": "поза межами", "risk": "ризик", "bug": "баг",
    "idea": "ідея", "note": "нотатка", "question": "питання", "pre_existing": "було до нас",
    "budget_increase": "потрібен запас",
}
finding_rows = "".join(
    f'<li><span class="tag">{esc(FINDING_KIND.get(str(f.get("kind")).lower(), "нотатка"))}</span>'
    f'<span>{esc(f.get("text"))}</span></li>'
    for f in (R.get("findings") or [])[:40]
)

task_block = ""
if R.get("task", "").strip():
    task_block = f'''<section class="card">
      <div class="eyebrow">The task</div>
      <div class="prose">{esc(R["task"])}</div>
    </section>'''

diffstat = R.get("diffstat", "")

# The document. Blocks when the writer composed one; otherwise its prose, and if there was none of
# that either, the recorded facts on their own — never a placeholder pane.
blocks = R.get("blocks") or []
document = "".join(render_block(b) for b in blocks)
if not document.strip():
    parts = []
    if (R.get("narrative") or "").strip():
        parts.append(_card(t_what_done, _prose(R.get("narrative"))))
    if before_src and after_src:
        parts.append(render_block({"type": "beforeAfter"}))
    elif after_src:
        parts.append(render_block({"type": "media", "label": "after"}))
    if video_src:
        parts.append(render_block({"type": "video"}))
    parts.append(render_block({"type": "commits"}))
    parts.append(render_block({"type": "evidence"}))
    parts.append(render_block({"type": "findings"}))
    document = "".join(p for p in parts if p)

HTML = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>{esc(R.get("project_name"))} · run report</title>
<style>
/* The app's report palette, token for token: neutral paper on light, graphite on dark,
   and the brand lime as the only accent — deepened to a forest green where it has to be
   ink on white, left as the lime where it has graphite under it. */
:root {{
  color-scheme: light dark;
  --bg1:#f6f6f7; --bg2:#eeeef0; --card:#ffffff; --shell:#efeff1;
  --line:rgba(0,0,0,.075); --line2:rgba(0,0,0,.14);
  --t1:#202023; --t2:#626268; --t3:#96969b;
  --acc:#4b7510; --acc2:#3c5f0d; --accdeep:#3c5f0d;
  --brand:#c7f183; --brand-field:#16291c;
  --ok:#1f6b41; --bad:#a83b36; --warn:#8a4e12;
  --shadow:0 1px 2px rgba(43,43,46,.05), 0 10px 26px rgba(43,43,46,.07);
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg1:#19191a; --bg2:#1f1f21; --card:#242426; --shell:#2b2b2e;
    --line:rgba(255,255,255,.075); --line2:rgba(255,255,255,.13);
    --t1:#f2f2f3; --t2:#b5b5bb; --t3:#77777e;
    --acc:#b4e76d; --acc2:#c7f183; --accdeep:#c7f183;
    --ok:#69c58c; --bad:#ef7770; --warn:#e8a45d;
    --shadow:0 1px 2px rgba(0,0,0,.2), 0 10px 26px rgba(0,0,0,.28);
  }}
}}
* {{ box-sizing:border-box; }}
html,body {{ margin:0; }}
body {{
  font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display",system-ui,sans-serif;
  background:var(--bg1); color:var(--t1);
  -webkit-font-smoothing:antialiased; line-height:1.5;
  padding:48px 28px 80px;
}}
.wrap {{ max-width:960px; margin:0 auto; }}
.eyebrow {{ font-size:10px; letter-spacing:.8px; text-transform:uppercase; color:var(--acc2); font-weight:700; margin-bottom:10px; }}
.mono {{ font-family:"SF Mono",ui-monospace,Menlo,monospace; }}

{brand.CSS}

header.top {{ display:flex; align-items:flex-start; justify-content:space-between; gap:24px; margin-bottom:14px; flex-wrap:wrap; }}
.title {{ font-size:31px; font-weight:600; letter-spacing:-1.1px; line-height:1.14; margin:0; }}
.subtitle {{ color:var(--t2); font-size:14px; margin-top:8px; }}
.subtitle .mono {{ color:var(--t3); }}
.chips {{ display:flex; gap:6px; flex-wrap:wrap; margin-top:12px; }}
.chip {{ font-size:11px; font-weight:500; color:var(--acc2); background:color-mix(in srgb, var(--acc) 12%, transparent);
        border:1px solid color-mix(in srgb, var(--acc) 26%, transparent); padding:3px 9px; border-radius:999px; }}
.gen {{ text-align:right; color:var(--t3); font-size:12px; }}

.stats {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; margin:22px 0 26px; }}
.stat {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:15px 16px; box-shadow:var(--shadow); }}
.stat .k {{ font-size:10px; letter-spacing:.8px; text-transform:uppercase; color:var(--t3); font-weight:700; }}
.stat .v {{ font-size:24px; font-weight:600; margin-top:6px; letter-spacing:-.5px; }}
.stat .v.small {{ font-size:15px; font-weight:600; letter-spacing:0; }}

.card {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:20px 22px; margin-bottom:16px; box-shadow:var(--shadow); }}
.prose {{ white-space:pre-wrap; color:var(--t1); font-size:14.5px; line-height:1.68; }}
.prose.dim {{ color:var(--t2); }}

.ba {{ display:grid; grid-template-columns:1fr 1fr; gap:12px; }}
@media (max-width:760px) {{ .ba {{ grid-template-columns:1fr; }} }}
.shot {{ background:var(--shell); border:1px solid var(--line); border-radius:12px; padding:9px; }}
.shot-head {{ display:flex; align-items:center; gap:8px; padding:1px 3px 9px; }}
.tag {{ font-size:9.5px; letter-spacing:.6px; text-transform:uppercase; font-weight:700; color:var(--acc2);
        background:color-mix(in srgb, var(--acc) 14%, transparent); padding:3px 8px; border-radius:5px; }}
.shot-sub {{ color:var(--t3); font-size:11.5px; }}
.shot-body {{ border-radius:8px; overflow:hidden; border:1px solid var(--line); background:var(--bg2); min-height:120px; display:flex; align-items:center; justify-content:center; }}
.shot-body img, .shot-body video {{ width:100%; display:block; }}
.empty {{ color:var(--t3); font-size:12.5px; padding:34px 16px; text-align:center; }}

ul.commits {{ list-style:none; margin:0; padding:0; }}
ul.commits li {{ display:flex; gap:12px; padding:8px 0; border-bottom:1px solid var(--line); font-size:13.5px; }}
ul.commits li:last-child {{ border-bottom:0; }}
ul.finds {{ list-style:none; margin:0; padding:0; }}
ul.finds li {{ display:flex; gap:12px; padding:8px 0; border-bottom:1px solid var(--line); font-size:13.5px; }}
ul.finds li:last-child {{ border-bottom:0; }}
ul.finds .tag {{ color:var(--acc2); flex:0 0 auto; min-width:104px; }}
.sha {{ color:var(--acc2); min-width:64px; }}

table.ev {{ width:100%; border-collapse:collapse; font-size:13px; }}
table.ev td {{ padding:9px 8px; border-bottom:1px solid var(--line); vertical-align:top; }}
table.ev tr:last-child td {{ border-bottom:0; }}
table.ev td.r {{ text-align:right; }}
.dot {{ display:inline-block; width:8px; height:8px; border-radius:999px; margin-right:8px; vertical-align:middle; }}
.dot.ok,.st.ok {{ color:var(--ok); }} .dot.ok {{ background:var(--ok); }}
.dot.bad,.st.bad {{ color:var(--bad); }} .dot.bad {{ background:var(--bad); }}
.dot.warn,.st.warn {{ color:var(--warn); }} .dot.warn {{ background:var(--warn); }}
.st {{ font-weight:600; text-transform:capitalize; }}
ul.doc, ol.doc {{ margin:0; padding-left:20px; color:var(--t2); font-size:14px; line-height:1.6; }}
ul.doc li, ol.doc li {{ padding:3px 0; }}
table.doc {{ width:100%; border-collapse:collapse; font-size:13.5px; }}
table.doc th {{ text-align:left; color:var(--t3); font-weight:600; font-size:11px;
                text-transform:uppercase; letter-spacing:.08em; padding:0 10px 8px 0; }}
table.doc td {{ padding:8px 10px 8px 0; border-top:1px solid var(--line); color:var(--t2);
                vertical-align:top; }}
pre.doc {{ margin:0; white-space:pre-wrap; font-family:"SF Mono",ui-monospace,Menlo,monospace;
           font-size:12.5px; color:var(--t2); background:var(--shell); border:1px solid var(--line);
           border-radius:10px; padding:14px 16px; overflow-x:auto; }}
.ba.one {{ grid-template-columns:1fr; }}
video.vid {{ width:100%; border-radius:12px; border:1px solid var(--line); background:#000; }}
.foot {{ color:var(--t3); font-size:12px; margin-top:8px; }}
.foot .mono {{ color:var(--t2); }}
</style>
</head>
<body>
<div class="wrap">
  {brand.lockup()}
  <header class="top">
    <div>
      <div class="eyebrow">Night shift · run report</div>
      <h1 class="title">{esc(R.get("project_name"))}</h1>
      <div class="subtitle">branch <span class="mono">{esc(R.get("branch"))}</span>
        &nbsp;·&nbsp; base <span class="mono">{esc((R.get("base_sha") or "")[:9])}</span></div>
      <div class="chips">{stack_chips}</div>
    </div>
    <div class="gen">{esc(R.get("generated_human"))}<br/><span class="mono">{esc(R.get("language"))}</span></div>
  </header>

  <div class="stats">
    <div class="stat"><div class="k">Files changed</div><div class="v">{esc(R.get("files_changed"))}</div></div>
    <div class="stat"><div class="k">Insertions</div><div class="v" style="color:var(--ok)">+{esc(R.get("insertions"))}</div></div>
    <div class="stat"><div class="k">Deletions</div><div class="v" style="color:var(--bad)">-{esc(R.get("deletions"))}</div></div>
    <div class="stat"><div class="k">Verification</div><div class="v small">{ev_summary or "—"}</div></div>
  </div>

  {task_block}

  {document}

  {"<div class='foot'>Diff: <span class='mono'>" + esc(diffstat) + "</span></div>" if diffstat else ""}
  <div class="foot">Generated by the Night Shift engine · head <span class="mono">{esc((R.get("head_sha") or "")[:9])}</span></div>
</div>
</body>
</html>'''

with open(os.path.join(REPORT_DIR, "report.html"), "w", encoding="utf-8") as f:
    f.write(HTML)
print(os.path.join(REPORT_DIR, "report.html"))
