---
updated: 2026-04-30
---

# Architecture Decision Records (ADR)

Архитектурные решения: **почему** мы выбрали такой подход, какие альтернативы
рассмотрели, какие следствия. Формат — см. [0001-remove-quic.md](0001-remove-quic.md)
как template.

| # | Статус | Заголовок | Дата |
|---|---|---|---|
| [0001](0001-remove-quic.md) | accepted | Удалить QUIC стек, оставить только H2/TLS | 2026-04-15 |
| [0002](0002-noise-to-mtls.md) | accepted | Убрать Noise, перейти на mTLS | 2026-03-15 |
| [0003](0003-h2-multistream-transport.md) | accepted | H2/TLS reliable streams с мульти-стрим шардингом | 2026-03-29 |
| [0004](0004-ghs-url-conn-string.md) | accepted | `ghs://` URL conn_string + dynamic admin mTLS | 2026-04-15 |
| [0005](0005-client-core-runtime.md) | accepted | Унифицированный tunnel runtime через `client-core-runtime` | 2026-04-17 |
| [0006](0006-layered-macos-vpn-routing.md) | accepted | Layered macOS routing для корпоративного VPN + GhostStream | 2026-04-30 |

## Когда писать новый ADR

- Сменили транспорт / wire format / крипто-схему
- Отказались от существующей фичи (deprecation)
- Выбрали одну из нескольких возможных архитектур (и кому-то в будущем это
  будет не очевидно)
- Принципиальная smena layout'а данных / сервисов / процессов

## Когда НЕ писать

- Bug fix — это git commit message, не ADR
- Refactor без смены external behavior — тоже commit message
- Обновление зависимости — commit message (если нет break'ающих последствий)

## Формат

```markdown
---
updated: YYYY-MM-DD
status: proposed | accepted | deprecated | superseded
---

# NNNN — <короткий заголовок в imperative>

## Context
Что происходило, какая проблема, какие constraints.

## Decision
Что решили делать. Одно предложение.

## Alternatives considered
Список отклонённых вариантов + почему каждый не подошёл.

## Consequences
- Плюсы
- Минусы / tradeoffs
- Что это открывает в будущем / что закрывает

## References
- commits, PRs, обсуждения, код
```

Номера монотонные (0001, 0002, ...). `status: superseded` — ссылаться на новый
ADR который это заменяет.
