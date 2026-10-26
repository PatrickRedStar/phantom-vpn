---
updated: 2026-10-26
---

# Architecture — Index

Reference-страницы по архитектуре протокола и серверной стороны. Каждая
страница сочетает "что" (wire-layout, endpoint table, state machine) и
"почему / инварианты", но не дублирует call-graph — для него gitnexus.

| Страница | Покрывает |
|---|---|
| [wire-format.md](wire-format.md) | Frame + batch layout, heartbeat frames, константы `wire.rs` |
| [handshake.md](handshake.md) | TCP → TLS → mTLS → `[stream_idx, max_streams]` handshake, отказ в доступе (`certificate_revoked`), fakeapp fallback |
| [transport.md](transport.md) | H2/TLS поверх TCP, N параллельных стримов, живучесть стримов и переподключение, RU relay (SNI passthrough без терминации) |
| [dpi-tspu.md](dpi-tspu.md) | Модель детекта ТСПУ, что видно на проводе, какие рычаги реально работают |
| [sessions.md](sessions.md) | `VpnSession`/SessionCoordinator, attach/detach_stream, per-stream batch loops, passive DNS cache, cleanup task |
| [crypto.md](crypto.md) | TLS 1.3 + mTLS, PhantomVPN CA, LE server cert, admin-server TOFU, keyring (`clients.json`) |
| [admin-api.md](admin-api.md) | Два admin listener'а (mTLS + loopback), endpoints, subscriptions, connection string `ghs://` |

---

## Что покрывает gitnexus (НЕ дублировать в vault)

- Call graph: "функция X вызывает Y" → `gitnexus_context({name: "X"})`
- Blast radius: "что сломается если я изменю X" → `gitnexus_impact`
- Execution flows: 262 процесса → `READ gitnexus://repo/ghoststream/process/<name>`

Vault дополняет: "почему мы так спроектировали", "какие invariants держатся",
"почему отказались от предыдущего подхода".
