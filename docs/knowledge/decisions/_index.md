---
updated: 2026-10-26
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
| [0007](0007-macos-statusframe-passthrough.md) | accepted | macOS PacketTunnel должен пробрасывать StatusFrame от runtime | 2026-05-09 |
| [0008](0008-verbose-debug-observability.md) | accepted | Verbose debug observability: structured logging для каждого микро-события | 2026-05-09 |
| [0009](0009-android-honest-state-and-resilience.md) | accepted, частично заменён 0018 | Android honest state + TSPU-resilient reconnect | 2026-05-09 |
| [0009](0009-cert-pem-providerConfiguration.md) | accepted | macOS cert/key через providerConfiguration (не Keychain) | 2026-05-17 |
| [0010](0010-docker-deploy.md) | accepted | Docker pull-and-go деплой server + relay | 2026-06-04 |
| [0011](0011-remove-insecure-always-verify.md) | accepted | Убрать `insecure` TLS: всегда webpki-проверка серверного серта | 2026-06-27 |
| [0012](0012-layered-routing-longest-prefix.md) | accepted | layeredAuto через longest-prefix, без вычитания маршрутов upstream | 2026-07-02 |
| [0013](0013-macos-admin-relay-parity.md) | accepted | Админка и relay на macOS: паритет с Android через PhantomKit | 2026-07-02 |
| [0014](0014-transport-policy-pushable.md) | accepted, частично | Server-pushable Transport Policy (доставки нет) | 2026-08-01 |
| [0015](0015-oneui-live-phosphor-redesign.md) | accepted | Android-редизайн: One UI 8.5 / «живой фосфор» | 2026-08-01 |
| [0016](0016-android-route-budget.md) | accepted | Бюджет маршрутов VPN на Android | 2026-08-01 |
| [0017](0017-android-exclude-routes.md) | accepted | Split-routing на Android через excludeRoute | 2026-08-02 |
| [0018](0018-rust-owns-reconnect.md) | accepted | Rust — единственный владелец переподключения; error = фатально | 2026-10-26 |
| [0019](0019-owner-decisions-audit-2026-10.md) | accepted | Решения владельца по аудиту 2026-10 | 2026-10-26 |

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
