#!/usr/bin/env python3
"""Render the download page — English at /, Ukrainian at /uk/ — from one template.

    render.py <version> <bytes-or-dmg-or-app> <out-dir> <min-macos>

Writes <out-dir>/index.html, <out-dir>/uk/index.html and <out-dir>/index.html.assets, the last
being one line per picture: where it is published, where it came from, and its sha256.

Why a renderer and not `sed` any more: the page carries two languages now, and a substitution
engine that does not know what HTML means will happily put an `&` or a `<` from a translation
straight into the markup. Text goes through `{{t:key}}` and is escaped; the few strings that
genuinely contain markup go through `{{h:key}}` and are not, which is a decision taken once per
key rather than hoped about per character.

Three things this refuses to do, each because the alternative has already cost a release:

  * a picture the template names and `site/assets` does not have stops the render — there is no
    placeholder, and a page with a hole in it must not be publishable;
  * the minimum macOS is never typed here. It comes off the built artefact, and when it cannot,
    the render stops rather than print a number nobody checked;
  * a `{{t:}}` key missing from either language stops the render, so a half-translated page
    cannot be published by forgetting one line.
"""

import hashlib
import html
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Written once, here, because both pages name them and a typo in an address is the kind of thing
# that survives a review: the repository and the address people write to.
GITHUB = "https://github.com/Stepanokdev/bulava"
EMAIL = "stepanokdev@gmail.com"
# Two pages per language: the landing page, and the history of the arrangements that came before
# the current one. Same tokens, same styles, same translation table — a second template rather
# than a second site.
PAGES = {
    "index.html": os.path.join(HERE, "index.template.html"),
    os.path.join("pipeline", "index.html"): os.path.join(HERE, "pipeline.template.html"),
}
STRINGS = os.path.join(HERE, "strings.json")
BENCHMARK = os.path.join(HERE, "benchmark.json")
ASSETS = os.path.join(HERE, "assets")

# The picture behind the first screen: green aurora over black, chosen out of eight candidates
# the director looked at through the preview's switch. The switch is gone with the choice.
HERO = "aurora.webp"

# The default language lives at the root; every other language gets a directory of its own, so a
# shared link says which language it is and nothing has to guess from a header.
LANGS = {"en": "/", "uk": "/uk/"}
DEFAULT = "en"

CONTENT = re.compile(r"\{\{(t|h):([a-zA-Z0-9_.-]+)\}\}"
                     r"|\{\{ASSET:([A-Za-z0-9._-]+)\}\}"
                     r"|\{\{SHOT:([A-Za-z0-9._-]+)\}\}"
                     r"|\{\{DIAGRAM:([a-zA-Z0-9_-]+)\}\}"
                     r"|\{\{(METHOD|METRICS|HERO)\}\}")
# Substituted in a second pass, AFTER the translations, so that a translated sentence may carry
# one — "macOS {{MINOS}} or newer" has to be one string for a translator, not three fragments
# glued together in an order that is wrong in half the languages that exist.
VALUE = re.compile(r"\{\{(VERSION|SIZE|MINOS|LANG|ALT_LANG|LANG_HREF|LANG_LABEL|LANG_SHORT|ALT_SHORT|HOME|ALT_HREF|GITHUB|EMAIL)\}\}"
                   r"|\{\{BM:([a-z_.]+)\}\}")


def die(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def size_in_bytes(argument):
    if argument.isdigit():
        return int(argument)
    if not os.path.exists(argument):
        die(f"не знаю розміру: «{argument}» не число і не файл")
    return os.path.getsize(argument)


def minimum_macos(given, artefact):
    if given:
        return given
    if artefact.endswith(".app"):
        plist = os.path.join(artefact, "Contents", "Info.plist")
        out = subprocess.run(["/usr/libexec/PlistBuddy", "-c",
                              "Print :LSMinimumSystemVersion", plist],
                             capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    die("не знаю, з якої macOS це працює — і вигадувати не буду.\n\n"
        "Передай четвертим аргументом те, що каже сам застосунок:\n\n"
        "    /usr/libexec/PlistBuddy -c \"Print :LSMinimumSystemVersion\" "
        "Bulava.app/Contents/Info.plist\n\n"
        "Число на сторінці має походити з артефакту, а не з памʼяті: коли воно походило з\n"
        "памʼяті, сторінка три релізи поспіль відмовляла людям, які чудово могли поставити\n"
        "застосунок.")


def benchmark_numbers():
    """The published figures, flattened to the names the template asks for."""
    data = json.load(open(BENCHMARK, encoding="utf-8"))
    out = {
        "cache_share": str(data["cache_read_share_percent"]),
        "idle_hours": f"{data['pure_idle_hours']:.1f}",
        "limit_pauses": str(data["pure_confirmed_limit_pauses"]),
        "measured": data["measured_at"][:10],
        "window": data["window"],
    }
    for scenario in data["scenarios"]:
        key = scenario["key"]
        out[f"{key}.hours"] = f"{scenario['hours']:.1f}"
        out[f"{key}.tokens"] = f"{scenario['tokens_millions']:.1f}"
        out[f"{key}.count"] = scenario["outcome_count"]
        out[f"{key}.url"] = scenario["result_url"]
        out[f"{key}.effort"] = scenario["effort"]
    return out


def hero_backdrop(assets):
    """The picture behind the first screen.

    Injected by the renderer rather than written in the template because the template should not
    have to know the file's name: the published name carries a content hash, and the hero is the
    one picture the page cannot fall back from.
    """
    return (f'<div class="hero-bg" aria-hidden="true">'
            f'<img src="{assets[HERO]}" alt="" decoding="async"></div>')


def published_assets(template):
    """Every {{ASSET:…}} the template names, resolved to its published, content-hashed path.

    The hash is in the NAME because the page and its pictures are uploaded as separate files: a
    URL that keeps its name while its bytes change is one a browser is entitled to keep serving
    from cache. With the hash in the name an upload only ever adds an address, so a page already
    in somebody's cache keeps working and "pictures before the page" becomes a guarantee.

    Root-relative on purpose. The Ukrainian page is served from /uk/, and a relative `assets/x`
    there asks the server for /uk/assets/x, which does not exist.
    """
    resolved, manifest, missing = {}, [], []
    wanted = set(re.findall(r"\{\{ASSET:([A-Za-z0-9._-]+)\}\}", template))
    # The hero backdrop is chosen in code, not named in the template.
    wanted.add(HERO)
    for shot in set(re.findall(r"\{\{SHOT:([A-Za-z0-9._-]+)\}\}", template)):
        stem, ext = os.path.splitext(shot)
        wanted |= {f"{stem}-{code}{ext}" for code in LANGS}
    for name in sorted(wanted):
        source = os.path.join(ASSETS, name)
        if not os.path.isfile(source) or os.path.getsize(source) == 0:
            missing.append(name)
            continue
        digest = hashlib.sha256(open(source, "rb").read()).hexdigest()
        stem, ext = os.path.splitext(name)
        published = f"assets/{stem}.{digest[:8]}{ext}"
        resolved[name] = "/" + published
        manifest.append((published, source, digest))
    if missing:
        die("сторінці бракує файлів у site/assets: " + " ".join(missing)
            + "\nЗаглушку не підставляю — сторінка з дірками не має публікуватись.")
    return resolved, manifest


def render(template, lang, strings, values, assets, diagrams, numbers, methodology,
           metrics, hero):
    alt = [code for code in LANGS if code != lang][0]

    def content(match):
        kind, key, asset, shot, diagram, block = match.groups()
        if kind:
            table = strings[lang]
            if key not in table:
                die(f"немає перекладу «{key}» для мови {lang} — половина сторінки не публікується")
            text = table[key]
            # Escaped unless the key is declared to carry markup. Decided once per key rather
            # than hoped about per character: a translation is ordinary prose and will contain
            # an ampersand sooner or later.
            return text if kind == "h" else html.escape(text, quote=False)
        if asset:
            return assets[asset]
        if shot:
            # A capture of the application, in the language of the page it is on. An English
            # window on a Ukrainian page is the seam a reader notices first, and the app has
            # both interfaces already.
            stem, ext = os.path.splitext(shot)
            return assets[f"{stem}-{lang}{ext}"]
        if block:
            return {"METHOD": methodology, "METRICS": metrics, "HERO": hero}[block]
        if diagram not in diagrams:
            die(f"немає схеми «{diagram}»")
        return diagrams[diagram]

    values = dict(values, LANG=lang, ALT_LANG=alt, HOME=LANGS[lang], ALT_HREF=LANGS[alt],
                  LANG_HREF=LANGS[alt], LANG_LABEL=strings[alt]["site.language.name"],
                  LANG_SHORT=strings[lang]["site.lang.short"],
                  ALT_SHORT=strings[alt]["site.lang.short"],
                  GITHUB=GITHUB, EMAIL=EMAIL)
    def value(match):
        name, figure = match.groups()
        if name:
            return values[name]
        # Numbers are data, not prose. They come out of site/benchmark.json, which is copied from
        # the measurement the presentation publishes — so the page and the talk cannot drift
        # apart again by somebody retyping a figure into one of them.
        if figure not in numbers:
            die(f"немає числа «{figure}» у benchmark.json")
        return numbers[figure]

    page = CONTENT.sub(content, template)
    return VALUE.sub(value, page)


def main():
    if len(sys.argv) != 5:
        die("usage: render.py <version> <bytes|dmg|app> <out-dir> <min-macos>")
    version, artefact, out_dir, minos_arg = sys.argv[1:5]

    templates = {name: open(path, encoding="utf-8").read() for name, path in PAGES.items()}
    every = "\n".join(templates.values())
    strings = json.load(open(STRINGS, encoding="utf-8"))
    for code in LANGS:
        if code not in strings:
            die(f"у strings.json немає мови {code}")

    # Both directions. A key the template stopped using is dead weight somebody will translate
    # again next time; a key only one language has is half a page.
    sys.path.insert(0, HERE)
    import diagram as diagrams_module
    import method as method_module

    used = (set(re.findall(r"\{\{[th]:([a-zA-Z0-9_.-]+)\}\}", every))
            | set(diagrams_module.KEYS) | set(method_module.KEYS)
            | {"site.language.name", "site.lang.short"}
            # The methodology names each run by the same key the cards use.
            | {f"bm.row.{s['key']}" for s in json.load(open(BENCHMARK, encoding="utf-8"))["scenarios"]})
    for code in LANGS:
        missing = used - set(strings[code])
        if missing:
            die(f"у мові {code} немає ключів: " + ", ".join(sorted(missing)))
        unused = set(strings[code]) - used
        if unused:
            die(f"у мові {code} є ключі, яких немає в шаблоні: " + ", ".join(sorted(unused)))

    size_bytes = size_in_bytes(artefact)
    values = {
        "VERSION": version,
        "SIZE": f"{size_bytes / 1048576:.1f} MB",
        "MINOS": minimum_macos(minos_arg, artefact),
    }
    assets, manifest = published_assets(every)
    numbers = benchmark_numbers()

    scenarios = json.load(open(BENCHMARK, encoding="utf-8"))["scenarios"]
    for lang in LANGS:
        diagrams = diagrams_module.all_diagrams(lang, strings[lang])
        methodology = method_module.methodology(strings[lang], numbers, scenarios)
        metrics = method_module.metrics(strings[lang], scenarios)
        hero = hero_backdrop(assets)
        prefix = "" if lang == DEFAULT else lang
        for name, template in templates.items():
            page = render(template, lang, strings, values, assets, diagrams, numbers,
                          methodology, metrics, hero)
            left = re.findall(r"\{\{[^}]*\}\}", page)
            if left:
                die(f"у сторінці {prefix or 'en'}/{name} лишились незаповнені місця: "
                    + " ".join(sorted(set(left))))
            path = os.path.join(out_dir, prefix, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w", encoding="utf-8").write(page)

    with open(os.path.join(out_dir, "index.html.assets"), "w", encoding="utf-8") as f:
        for published, source, digest in manifest:
            f.write(f"{published}\t{source}\t{digest}\n")

    print(f"сторінки зібрано: версія {version}, {values['SIZE']}, від macOS {values['MINOS']}, "
          f"{len(PAGES)} сторінки × {len(LANGS)} мови, файлів поруч: {len(manifest)}")


if __name__ == "__main__":
    main()
