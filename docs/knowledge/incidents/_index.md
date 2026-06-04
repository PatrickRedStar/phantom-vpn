---
updated: 2026-06-05
---

# Incidents & Postmortems

Инциденты и дебаги которые стоили часов. Фиксируем чтобы **не повторять**.

| Дата | Slug | Severity | Что |
|---|---|---|---|
| 2026-05-06 | [vpn-throughput-regression](2026-05-06-vpn-throughput-regression.md) | high | TX dispatcher `try_send` молча ронял пакеты → CWND collapse |
| 2026-05-17 | [cert-pem-keychain-regression](2026-05-17-cert-pem-keychain-regression.md) | critical | macOS — cert/key в Keychain недоступны для system-extension под root |
| 2026-06-05 | [android-ghs-copypaste-padding](2026-06-05-android-ghs-copypaste-padding.md) | high | Android v0.26.7 — `InvalidTrailingPadding` при импорте длинного `ghs://` из терминала |

## Формат

Имя файла: `YYYY-MM-DD-<slug>.md` (дата начала инцидента)

```markdown
---
updated: YYYY-MM-DD
severity: low | medium | high | critical
resolved: YYYY-MM-DD
---

# YYYY-MM-DD — <короткое описание>

## Symptom
Что именно сломалось, как проявилось. Конкретные ошибки, логи, метрики.

## Impact
Кого затронуло, на сколько (downtime, потерянные пакеты, и т.д.).

## Root cause
Что на самом деле было причиной. Часто != первоначальной гипотезе.

## Fix
Что изменили. Ссылка на commit/PR.

## Timeline
- `HH:MM` — первый alert / user report
- `HH:MM` — локализовали проблему
- `HH:MM` — rollback / fix deployed
- `HH:MM` — всё вернулось в норму

## How to avoid
Что надо было сделать чтобы это не повторилось:
- Тест который мог бы поймать (и почему не был написан)
- Мониторинг который мог бы alerting'овать раньше
- Code review checklist item
- Архитектурное изменение

## Lessons
Что мы узнали про систему чего не знали.
```

## Когда писать

- Production incident с user impact
- Регрессия которую нашли в стejдже и которая отняла >2 часов
- Дебаг-сессия где root cause оказалась неожиданной (surprise — пишем, чтобы
  в следующий раз шли сразу туда)

## Когда НЕ писать

- Обычный bug который пофиксили за час по первой гипотезе
- "Забыл версию обновить" — commit message достаточно
