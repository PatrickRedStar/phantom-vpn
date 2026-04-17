---
updated: 2026-04-17
---

# gstack (REQUIRED)

`gstack` — CLI и набор skill'ов, обязательных для AI-ассистированной работы в этом репо. Даёт унифицированные slash-команды (`/qa`, `/ship`, `/review`, `/investigate`, `/browse`) и web-browsing через `/browse`.

---

## Check перед работой

Перед тем, как что-либо делать в репо, проверить что gstack установлен:

```bash
test -d ~/.claude/skills/gstack/bin && echo "GSTACK_OK" || echo "GSTACK_MISSING"
```

Если `GSTACK_MISSING` — **СТОП**, не продолжать. Установить (см. ниже) и рестартнуть AI-tool.

---

## Install

Если `GSTACK_MISSING`:

```bash
git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
cd ~/.claude/skills/gstack && ./setup --team
```

Флаг `--team` — установка в team-режиме (настройки под общий репо). После этого перезапустить AI-tool (Claude Code), skill'ы подхватятся автоматически.

---

## Что становится доступно

После установки доступны slash-команды (skill'ы):

| Команда | Назначение |
|---|---|
| `/qa` | Прогон QA-checks перед commit'ом (lint, tests, smoke-тесты) |
| `/ship` | Полный release-флоу (bump version, commit, tag, push) |
| `/review` | Структурированное ревью изменений |
| `/investigate` | Debugging workflow (repro → isolate → diagnose → fix) |
| `/browse` | Web browsing — **обязательно использовать для всех web-запросов**, НЕ WebFetch/WebSearch напрямую |

---

## Path для файлов

Все gstack-файлы лежат в глобальном пути: `~/.claude/skills/gstack/...`

Примеры:
- `~/.claude/skills/gstack/bin/` — бинарники.
- `~/.claude/skills/gstack/skills/` — skill-определения.
- `~/.claude/skills/gstack/lib/` — shared helpers.

Не ссылаться на локальные пути в репо — gstack общий для всех проектов.

---

## Правила

- **Не пропускать проверку.** Если `GSTACK_MISSING` — остановиться, рассказать пользователю как установить, не пытаться обойти.
- **Не игнорировать ошибки gstack.** Если skill выдаёт ошибку — разбираться, не workaround'ить.
- **`/browse` для любого web-контента.** WebFetch/WebSearch напрямую — только если `/browse` недоступен (обычно не должен — если вдруг так, это симптом проблемы с gstack).

---

## Связанное

- Главный индекс tools — [../README.md](../README.md).
- Второй обязательный инструмент — [gitnexus.md](gitnexus.md) (code graph).
