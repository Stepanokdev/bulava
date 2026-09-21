---
description: Черга проєктів для нічної зміни — додати / список / запустити / зупинити
argument-hint: "[add|list|remove|clear|run|stop|status] [аргументи]"
---

Користувач керує чергою проєктів. Черга виконує проєкти ПО ОДНОМУ (кожен отримує
повне 5h-вікно), переиспользуючи per-project інстанси й рев'ю-гейт. Аргумент: $ARGUMENTS

Виконуй через команду `night-queue` (встановлюється в PATH через `~/.local/bin`):

- «add <шлях> [задача...]», «додай» → `night-queue add "<шлях>" "<задача>"` (без задачі — піде стандартна «зроби все за SPEC.md»).
- «list», «список», порожньо → `night-queue list`.
- «remove N», «прибери N» → `night-queue remove N`.
- «clear», «очисти» → `night-queue clear`.
- «run», «запусти» → `night-queue run` (стартує фоновий runner; проєкти підуть по черзі).
- «stop», «зупини» → `night-queue stop` (завершить після поточного проєкту).
- «status», «статус» → `night-queue status`.

Після виконання коротко звітуй стан. Нагадай: спершу треба мігрувати зі старого
single-session режиму, якщо він активний (`night-shift stop --all && tmux kill-session -t night`).
