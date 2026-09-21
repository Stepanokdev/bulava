#!/usr/bin/env python3
"""The demo conversation's own words, in the language the frame is being taken in.

The application's chrome translates itself; the conversation inside it does not. A Ukrainian
window whose largest block of text is English is the seam a reader notices before anything else,
so the fixture's prose lives here twice. It is invented prose about an invented product either
way — see site/analytics/check-screenshots.py, which proves that.
"""

import os

LANG = os.environ.get("BULAVA_DEMO_LANG", "en")

WORDS = {
    "ledger.brief": {
        "en": "A small Mac and iOS app for tracking shared household spending. "
              "SwiftUI on the front, a tiny Vapor service behind it.",
        "uk": "Невеликий застосунок для Mac і iOS, щоб рахувати спільні домашні витрати. "
              "SwiftUI спереду, крихітний сервіс на Vapor позаду.",
    },
    "bulava.brief": {
        "en": "This app. It has been writing itself since July.",
        "uk": "Оцей застосунок. Пише себе сам із липня.",
    },
    "trail.brief": {
        "en": "Offline hiking maps for iOS.",
        "uk": "Офлайнові туристичні мапи для iOS.",
    },
    "task.export": {
        "en": "Export the transaction list to CSV",
        "uk": "Експорт списку транзакцій у CSV",
    },
    "task.sync": {
        "en": "Two devices, one household, no merge conflicts",
        "uk": "Два пристрої, одна сімʼя, жодних конфліктів злиття",
    },
    "task.shortcuts": {
        "en": "Keyboard shortcuts on a Ukrainian layout",
        "uk": "Гарячі клавіші на українській розкладці",
    },
    "chat.sync.first": {
        "en": "Two devices editing the same household budget keep overwriting each other. "
              "Work out what the merge rule should be and implement it.",
        "uk": "Два пристрої правлять один бюджет і затирають зміни один одного. "
              "Визнач, яким має бути правило злиття, і зроби його.",
    },
    "chat.shortcuts.first": {
        "en": "Command-F does nothing when the keyboard is on the Ukrainian layout.",
        "uk": "Command-F нічого не робить, коли клавіатура на українській розкладці.",
    },
    "ac.1": {
        "en": "A CSV lands in the chosen folder and opens in Numbers with the columns intact",
        "uk": "CSV лягає у вибрану теку й відкривається в Numbers із цілими колонками",
    },
    "ac.2": {
        "en": "Amounts keep two decimals under every locale the app ships",
        "uk": "Суми тримають два знаки після коми в кожній локалі, яку має застосунок",
    },
    "ac.3": {
        "en": "Cancelling the save panel leaves no partial file behind",
        "uk": "Скасування панелі збереження не лишає недописаного файлу",
    },
    "ac.4": {
        "en": "The whole suite still passes",
        "uk": "Уся збірка тестів і далі проходить",
    },
    "ev.1": {
        "en": "7 tests, including a note containing a comma, a quote and a newline",
        "uk": "7 тестів, зокрема нотатка з комою, лапкою і переносом рядка",
    },
    "ev.2": {
        "en": "de_DE, en_US, uk_UA — the file is written with a fixed locale",
        "uk": "de_DE, en_US, uk_UA — файл пишеться з фіксованою локаллю",
    },
    "ev.3": {
        "en": "the handle is opened after the panel answers, not before",
        "uk": "дескриптор відкривається після відповіді панелі, а не до неї",
    },
    "ev.4": {"en": "214 tests, 0 failures", "uk": "214 тестів, 0 падінь"},
    "msg.first": {
        "en": "People keep asking for their transactions in a spreadsheet. Add an export to the "
              "transactions list — CSV, the columns that are on screen, and the date range the "
              "filter is already showing. It has to survive a comma inside a note.",
        "uk": "Люди весь час просять свої транзакції таблицею. Додай експорт до списку "
              "транзакцій — CSV, колонки, які на екрані, і діапазон дат, який уже стоїть у "
              "фільтрі. Кома всередині нотатки має його не ламати.",
    },
    "say.open": {
        "en": "Reading how the list is filtered before I add anything to it — the export has to "
              "agree with what is on screen, not with the whole table.",
        "uk": "Спершу читаю, як фільтрується список, і аж потім щось додаю — експорт має "
              "збігатися з тим, що на екрані, а не з усією таблицею.",
    },
    "say.plan": {
        "en": "The filter already owns the range, so the export can take the same value instead "
              "of recomputing it. Writing the encoder now — RFC 4180 quoting, because a note "
              "with a comma in it is the first thing anyone will try.",
        "uk": "Діапазон уже належить фільтру, тож експорт може взяти те саме значення, а не "
              "рахувати заново. Пишу кодувальник — лапкування за RFC 4180, бо нотатка з комою "
              "це перше, що хтось спробує.",
    },
    "say.tests": {
        "en": "Seven tests, all passing — including the one that puts a comma, a quote and a "
              "newline into the same note. Handing it to Codex.",
        "uk": "Сім тестів, усі проходять — зокрема той, що кладе в одну нотатку кому, лапку й "
              "перенос рядка. Передаю Codex.",
    },
    "say.took": {
        "en": "Both are real. Fixing the formatter to a fixed locale for the file and moving the "
              "handle behind the panel's answer.",
        "uk": "Обидва справжні. Ставлю формату фіксовану локаль для файлу і переношу дескриптор "
              "за відповідь панелі.",
    },
    "ask.columns": {
        "en": "Does it keep the column order the list is showing, or the model's order?",
        "uk": "Він тримає порядок колонок, який показує список, чи порядок моделі?",
    },
    "say.answer": {
        "en": "The list's. The header row is built from the visible columns in their current "
              "order, so hiding a column removes it from the file as well — which is what "
              "someone exporting what they are looking at means. I have added a test that "
              "reorders two columns and asserts the header follows.",
        "uk": "Списку. Рядок заголовків будується з видимих колонок у їхньому поточному порядку, "
              "тож прихована колонка зникає і з файлу — а саме це має на увазі той, хто "
              "експортує те, на що дивиться. Додав тест, який міняє місцями дві колонки і "
              "перевіряє, що заголовок іде за ними.",
    },
    "consult.ask": {
        "en": "Review the CSV export: quoting, locale-dependent decimal separators, and what "
              "happens when the save panel is cancelled.",
        "uk": "Перевір експорт у CSV: лапкування, десяткові роздільники залежно від локалі і що "
              "буде, якщо скасувати панель збереження.",
    },
    "consult.answer": {
        "en": "Two findings. The amount formatter follows the user's locale, so a German locale "
              "writes 1.234,56 into a file the header calls CSV — pick one and say which. And "
              "the file handle is created before the save panel returns, so cancelling leaves a "
              "zero-byte file behind.",
        "uk": "Дві знахідки. Формат суми йде за локаллю користувача, тож німецька локаль пише "
              "1.234,56 у файл, який заголовок називає CSV — обери щось одне і скажи, що саме. "
              "І дескриптор створюється до того, як панель відповіла, тож скасування лишає файл "
              "на нуль байтів.",
    },
}


def w(key):
    """The phrase for this run's language. A missing key is a bug, not a fallback."""
    return WORDS[key][LANG]
