"""Which language a piece of writing is in — the person's, for the worker to answer in, and a
report's, for the page's own words around it.

A worker told only "answer in the person's language" answered a question asked in English or
Russian in Ukrainian: the engine's notes around every message are Ukrainian and outweighed a line of
English. So the engine names the language — "the person wrote this in English" — and to name it
reads the person's own words only: pasted paths, links, code and the app's note about attachments
say nothing about the language they write in.

Bulava speaks English, Ukrainian and Russian. Ukrainian and Russian share most of the alphabet; each
has letters the other lacks, and short everyday words tell them apart when no such letter comes up.
Latin text is called English only when it reads as English; another language written in Latin
letters is left unnamed, and the worker is then told to follow the person's words as they are.

    python3 language.py name < text     → English | Ukrainian | Russian | (nothing)
"""
import re
import sys

NAMES = {"en": "English", "uk": "Ukrainian", "ru": "Russian"}

_EN = set("the a an and or but is are was were be to of in on at for with from this that it you i we "
          "they he she my your our what why how when where which who can could would should do does "
          "did not no yes please if then so there here have has had will just all some any".split())
_UK = set("що як це чому де коли мені треба можна зроби привіт дякую тільки якщо або є ні вже теж "
          "який яка яке бо щоб його її їх він вона вони ми ви я у в на з із до від для".split())
_RU = set("что как это почему где когда мне нужно можно сделай привет спасибо только если или есть "
          "нет уже тоже какой какая какое потому чтобы его её их он она они мы вы я у в на с из до от для".split())


def words_of(text):
    """The person's own words: without fenced or inline code, links, paths, and the app's line
    listing attached files."""
    t = str(text or "")
    t = re.sub(r"```.*?```", " ", t, flags=re.S)
    t = re.sub(r"`[^`]*`", " ", t)
    t = re.sub(r"(?m)^Attached files are available at these paths:.*?(?=\n\S|\Z)", " ", t, flags=re.S)
    t = re.sub(r"\S*[/\\]\S*", " ", t)           # paths and links
    t = re.sub(r"\S+@\S+", " ", t)               # addresses
    return t


def code(said):
    """A language as a setting or a manifest names it — "Ukrainian", "uk", "Русский" — as uk/ru/en."""
    s = str(said or "").strip().lower()
    if s.startswith(("uk", "укр")):
        return "uk"
    if s.startswith(("ru", "рус")):
        return "ru"
    if s.startswith(("en", "англ")):
        return "en"
    return ""


def detect(text):
    """uk, ru, en — or "" when the words do not say."""
    t = words_of(text).lower()
    cyrillic = sum(1 for c in t if "а" <= c <= "я" or c in "іїєґё")
    latin = sum(1 for c in t if "a" <= c <= "z")
    tokens = re.findall(r"[a-zа-яіїєґё']+", t)
    if cyrillic > latin:
        uk = sum(t.count(c) for c in "іїєґ") + sum(1 for w in tokens if w in _UK and w not in _RU)
        ru = sum(t.count(c) for c in "ыэъё") + sum(1 for w in tokens if w in _RU and w not in _UK)
        if uk > ru:
            return "uk"
        if ru > uk:
            return "ru"
        return ""
    if latin > cyrillic and tokens:
        english = sum(1 for w in tokens if w in _EN)
        if english >= max(1, len(tokens) // 8):
            return "en"
    return ""


def of_text(text, said="", fallback="en"):
    """uk, ru or en: what the text shows, else what `said` names, else `fallback`."""
    return detect(text) or code(said) or fallback


def name_of(text):
    """English, Ukrainian, Russian — or "" when the words do not say."""
    return NAMES.get(detect(text), "")


if __name__ == "__main__":
    if sys.argv[1:2] == ["name"]:
        print(name_of(sys.stdin.read()))
