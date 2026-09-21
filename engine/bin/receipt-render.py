#!/usr/bin/env python3
"""receipt-render.py — the floor under every finished run: a verdict the director can open.

Why it exists: a report used to be an LLM run (report.sh) triggered on demand for work that
produced a diff. A run that finished with nothing to show — blocked on an account, nothing to
change, a research answer, a failure — had no artifact at all. The card said "Needs you" and
opening it showed an empty screen; the night's actual answer lived in a terminal nobody reads.

This is written by worker-outcome.sh on EVERY terminal outcome, from facts already on disk
(no model, milliseconds): the verdict, the worker's own words, the commits and diffstat that
exist, what would unblock it, and the findings it filed. When the rich report is generated it
supersedes this one (the app opens whichever artifact is newer).

  receipt-render.py <out.html>   # facts as JSON on stdin
"""
import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brand  # noqa: E402  (needs the path above)

R = json.load(sys.stdin)
out = sys.argv[1]


def esc(v):
    return html.escape(str(v if v is not None else ""))


# --- Language ------------------------------------------------------------------
#
# The receipt is a page the director reads, so it speaks his language — the same one report.sh
# passes for the rich report (`language`). Ukrainian was hard-coded here, which made the artifact
# monolingual while the app itself ships en/uk/ru.
LANG = (R.get("language") or "Ukrainian").strip().lower()
LOC = "uk" if LANG.startswith(("ukrain", "укр")) else ("ru" if LANG.startswith(("russ", "рус")) else "en")


def t(en, uk, ru):
    return {"uk": uk, "ru": ru}.get(LOC, en)


# The verdict in the director's language: what happened, and whether it needs him.
VERDICT = {
    "succeeded_changes":   (t("Done", "Зроблено", "Готово"), "ok",
                            t("The work is finished; the changes are on the branch.",
                              "Робота виконана, зміни в гілці.",
                              "Работа выполнена, изменения в ветке.")),
    "succeeded_no_change": (t("Nothing was needed", "Нічого не потрібно", "Ничего не нужно"), "ok",
                            t("Checked — there was nothing to change.",
                              "Перевірено — змінювати не було чого.",
                              "Проверено — менять было нечего.")),
    "succeeded_research":  (t("Answer ready", "Відповідь готова", "Ответ готов"), "ok",
                            t("This was research: the result is the conclusion below.",
                              "Це було дослідження: результат — висновок нижче.",
                              "Это было исследование: результат — вывод ниже.")),
    "blocked":             (t("Stuck", "Застрягло", "Застряло"), "bad",
                            t("I cannot go further without you.",
                              "Далі не можу без тебе.", "Дальше не могу без тебя.")),
    "needs_input":         (t("Needs a decision", "Потрібне рішення", "Нужно решение"), "warn",
                            t("Waiting on an answer to continue.",
                              "Чекаю на відповідь, щоб продовжити.",
                              "Жду ответа, чтобы продолжить.")),
    "failed":              (t("Did not work out", "Не вийшло", "Не вышло"), "bad",
                            t("I tried and could not.", "Спробував і не зміг.", "Попробовал и не смог.")),
}
label, tone, lede = VERDICT.get(R.get("result"), (t("Finished", "Завершено", "Завершено"), "warn", ""))

# A worker DECLARING success is not the same as the work being accepted.
#
# The receipt is written the moment the worker declares its outcome, which is before the review
# gate has looked at the diff. It said "Done" over work that the reviewer might still refuse —
# and when the review ended in debt (the reviewer out of quota), that "Done" was simply
# untrue. Only a PASS earns it; anything else says plainly where it stands.
review = (R.get("review") or "").strip()      # "" | pending | passed | debt | failed
if R.get("result") == "succeeded_changes":
    if review == "passed":
        label, tone, lede = (t("Done", "Зроблено", "Готово"), "ok",
                             t("The work is finished and reviewed.",
                               "Робота виконана й перевірена.", "Работа выполнена и проверена."))
    elif review == "debt":
        label, tone, lede = (t("Done, not reviewed", "Зроблено, не перевірено", "Готово, не проверено"), "warn",
                             t("The changes are on the branch but no review was done — read it yourself before trusting it.",
                               "Зміни в гілці, але перевірку не провели — глянь сам, перш ніж довіряти.",
                               "Изменения в ветке, но проверку не проводили — посмотри сам, прежде чем доверять."))
    elif review == "failed":
        label, tone, lede = (t("Not accepted", "Не прийнято", "Не принято"), "bad",
                             t("The review did not pass the work — details below.",
                               "Перевірка не пропустила роботу — деталі нижче.",
                               "Проверка не пропустила работу — детали ниже."))
    else:
        label, tone, lede = (t("Awaiting review", "Очікує перевірки", "Ожидает проверки"), "warn",
                             t("The worker says it is done; the review has not finished yet.",
                               "Воркер каже, що зробив; перевірка ще не завершилась.",
                               "Воркер говорит, что сделал; проверка ещё не завершилась."))

commits = R.get("commits") or []
findings = R.get("findings") or []
diffstat = (R.get("diffstat") or "").strip()
needed = (R.get("unblock") or "").strip()
summary = (R.get("summary") or "").strip()
task = (R.get("task") or "").strip()

rows = []


def card(title, body, accent=False):
    rows.append(
        f'<section class="card{" hi" if accent else ""}">'
        f'<div class="eyebrow">{esc(title)}</div>{body}</section>'
    )


# What the worker said, in its own words — never paraphrased.
if summary:
    card(t("What happened", "Що сталося", "Что произошло"), f'<p class="lead">{esc(summary)}</p>')
elif lede:
    card(t("What happened", "Що сталося", "Что произошло"), f'<p class="lead">{esc(lede)}</p>')

# Why the review did not accept it. A verdict he cannot act on is not a verdict.
review_why = (R.get("review_why") or "").strip()
if review_why and review in ("failed", "debt"):
    card(t("What the review said", "Що сказала перевірка", "Что сказала проверка"),
         f'<pre class="task">{esc(review_why[:4000])}</pre>', accent=True)

# The one action that unblocks it. A blocker without this is not a blocker, it is a shrug.
if needed:
    card(t("What is needed from you", "Що потрібно від тебе", "Что нужно от тебя"),
         f'<p class="lead">{esc(needed)}</p>', accent=True)

# The partial result, as evidence rather than a claim.
if commits or diffstat:
    items = "".join(
        f'<li><span class="mono sha">{esc(c.get("sha"))}</span><span>{esc(c.get("subject"))}</span></li>'
        for c in commits[:40]
    )
    body = ""
    if diffstat:
        body += f'<p class="stat-line mono">{esc(diffstat)}</p>'
    if items:
        body += f'<ul class="commits">{items}</ul>'
    if len(commits) > 40:
        body += f'<p class="muted">{t("…and %d more", "…і ще %d", "…и ещё %d") % (len(commits) - 40)}</p>'
    card(t("Already on the branch", "Що вже в гілці", "Уже в ветке") if commits
         else t("Uncommitted changes", "Незакомічені зміни", "Незакоммиченные изменения"), body)

# Findings: things noticed outside the job's fence. Notes, never queued work.
#
# The kind is named in the director's language — `needs_scope` and `blocker` are the channel's
# vocabulary, not his. An internal enum on a surface he reads is the same defect as a run id in
# a card title.
KIND = {
    "blocker":     t("blocker", "блокер", "блокер"),
    "needs_scope": t("out of scope", "поза межами", "вне границ"),
    "risk":        t("risk", "ризик", "риск"),
    "bug":         t("bug", "баг", "баг"),
    "idea":        t("idea", "ідея", "идея"),
    "note":        t("note", "нотатка", "заметка"),
    "question":    t("question", "питання", "вопрос"),
}
if findings:
    items = "".join(
        f'<li><span class="tag">{esc(KIND.get(str(f.get("kind")).lower(), t("note", "нотатка", "заметка")))}</span>'
        f'<span>{esc(f.get("text"))}</span></li>'
        for f in findings[:25]
    )
    card(t("Noticed along the way", "Помічено по дорозі", "Замечено по пути"),
         f'<ul class="finds">{items}</ul>')

if task:
    card(t("The task", "Задача", "Задача"), f'<pre class="task">{esc(task[:4000])}</pre>')

body_html = "".join(rows) or ('<section class="card"><p class="lead">'
    + esc(t("The work finished without details.", "Робота завершена без деталей.",
            "Работа завершена без деталей.")) + '</p></section>')

# The project and the branch — no run id. A run id is machine identity: it belongs behind
# «Details», not in the header of the one page the director actually reads.
chips = "".join(
    f'<span class="chip">{esc(c)}</span>'
    for c in [R.get("project_name"), R.get("branch")] if c
)

DOC = f"""<!doctype html>
<html lang="uk"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>{esc(R.get("project_name"))} · {esc(label)}</title>
<style>
/* The app's palette — see engine/bin/report-render.py and the app's ReportHTML: one look
   across every document Bulava produces. */
:root {{
  color-scheme: light dark;
  --bg1:#f6f6f7; --bg2:#eeeef0; --card:#ffffff;
  --line:rgba(0,0,0,.075);
  --t1:#202023; --t2:#626268; --t3:#96969b;
  --acc:#4b7510; --acc2:#3c5f0d;
  --brand:#c7f183; --brand-field:#16291c;
  --ok:#1f6b41; --bad:#a83b36; --warn:#8a4e12;
  --shadow:0 1px 2px rgba(43,43,46,.05), 0 10px 26px rgba(43,43,46,.07);
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg1:#19191a; --bg2:#1f1f21; --card:#242426;
    --line:rgba(255,255,255,.075);
    --t1:#f2f2f3; --t2:#b5b5bb; --t3:#77777e;
    --acc:#b4e76d; --acc2:#c7f183;
    --ok:#69c58c; --bad:#ef7770; --warn:#e8a45d;
    --shadow:0 1px 2px rgba(0,0,0,.2), 0 10px 26px rgba(0,0,0,.28);
  }}
}}
* {{ box-sizing:border-box; }}
html,body {{ margin:0; }}
body {{
  font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text",system-ui,sans-serif;
  background:var(--bg1); color:var(--t1);
  -webkit-font-smoothing:antialiased; line-height:1.5; padding:48px 28px 80px;
}}
.wrap {{ max-width:840px; margin:0 auto; }}
.eyebrow {{ font-size:10px; letter-spacing:.8px; text-transform:uppercase; color:var(--acc2); font-weight:700; margin-bottom:10px; }}
.mono {{ font-family:"SF Mono",ui-monospace,Menlo,monospace; }}
.muted {{ color:var(--t3); font-size:13px; }}
.verdict {{ display:flex; align-items:center; gap:12px; }}
.dot {{ width:11px; height:11px; border-radius:50%; flex:0 0 auto; }}
.tone-ok .dot {{ background:var(--ok); box-shadow:0 0 0 5px color-mix(in srgb, var(--ok) 18%, transparent); }}
.tone-bad .dot {{ background:var(--bad); box-shadow:0 0 0 5px color-mix(in srgb, var(--bad) 18%, transparent); }}
.tone-warn .dot {{ background:var(--warn); box-shadow:0 0 0 5px color-mix(in srgb, var(--warn) 18%, transparent); }}
h1 {{ font-size:31px; font-weight:600; letter-spacing:-1.1px; line-height:1.14; margin:0; }}
.sub {{ color:var(--t2); font-size:14px; margin-top:8px; }}
.chips {{ display:flex; gap:6px; flex-wrap:wrap; margin:14px 0 30px; }}
.chip {{ font-size:11px; font-weight:500; color:var(--acc2); background:color-mix(in srgb, var(--acc) 12%, transparent);
        border:1px solid color-mix(in srgb, var(--acc) 26%, transparent); padding:3px 9px; border-radius:999px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:20px 22px; margin-bottom:16px; box-shadow:var(--shadow); }}
.card.hi {{ border-color:color-mix(in srgb, var(--acc) 40%, transparent); }}
.lead {{ margin:0; font-size:16px; }}
.stat-line {{ margin:0 0 10px; font-size:13px; color:var(--t2); }}
ul.commits, ul.finds {{ list-style:none; margin:0; padding:0; }}
ul.commits li, ul.finds li {{ display:flex; gap:12px; padding:8px 0; border-bottom:1px solid var(--line); font-size:13.5px; }}
ul.commits li:last-child, ul.finds li:last-child {{ border-bottom:0; }}
.sha {{ color:var(--t3); flex:0 0 auto; }}
.tag {{ color:var(--acc2); flex:0 0 auto; font-size:11.5px; padding-top:1px; min-width:88px; }}
pre.task {{ margin:0; white-space:pre-wrap; font-family:"SF Mono",ui-monospace,Menlo,monospace; font-size:12.5px; color:var(--t2); }}
{brand.CSS}
</style></head>
<body><div class="wrap">
{brand.lockup()}
<header class="tone-{esc(tone)}">
  <div class="verdict"><span class="dot"></span><h1>{esc(label)}</h1></div>
  <p class="sub">{esc(lede)} · {esc(R.get("ts"))}</p>
  <div class="chips">{chips}</div>
</header>
{body_html}
</div></body></html>
"""

with open(out, "w", encoding="utf-8") as fh:
    fh.write(DOC)
print(out)
