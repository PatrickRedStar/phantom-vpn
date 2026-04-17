---
updated: 2026-04-17
status: accepted
---

# 0001 — Удалить QUIC стек, оставить только H2/TLS

## Context

До v0.19.4 в `crates/core/` существовал полный QUIC стек (`quic.rs`,
`congestion.rs`, `quic_server.rs`, Android auto-fallback) — ~870 строк кода.
Планировалось использовать QUIC как альтернативный транспорт (мультиплексинг
без HoL blocking на уровне stream, встроенная миграция соединений).

К моменту v0.17.0 реально работающий путь был только один — **H2/TLS поверх
TCP с мульти-стрим шардингом** (см. [../architecture/transport.md](../architecture/transport.md)).
Функция `normalize_transport` принимала только `"h2"`. QUIC-код был unreachable
на каждом клиенте и на сервере.

## Decision

Удалить весь QUIC код и связанные зависимости (`quinn` и попутные пакеты). Оставить
константы `QUIC_TUNNEL_MTU` / `QUIC_TUNNEL_MSS` с legacy naming (переименование
ломало бы cross-crate compat). Структуру `QuicConfig` переименовать в `TlsConfig`
с `serde(alias = "quic")` для обратной совместимости с существующими
`server.toml`.

Принято и внедрено в commit `04913e9` (v0.19.4, 2026-04-15).

## Alternatives considered

1. **Оставить QUIC как опциональный транспорт.** Отклонено: никто им не пользовался,
   тестовых путей нет, код просто болтался и ломал audit/compile time. Плюс от
   DPI-маскировки QUIC хуже чем H2/TLS — UDP сразу выделяется.

2. **Дорелизировать QUIC до working state.** Отклонено: требовало ~2 недели
   работы на функцию которая не даёт user-visible benefit'а. H2/TLS уже
   достаточно (после оптимизаций v0.17.2 — 138→625 Mbit/s download).

3. **Переименовать `QuicConfig` → `TlsConfig` полностью с breaking config.**
   Отклонено: существующие `server.toml` на проде сломались бы. Добавлен
   `serde(alias = "quic")` — transparent upgrade.

## Consequences

**Плюсы:**
- -1357 / +282 строк. Чистый sweep мёртвого кода.
- Упрощение `crates/core/Cargo.toml` — убрали `quinn`, `quinn-udp` и попутные.
- Быстрее компиляция, меньше surface attack, меньше audit warnings.
- Одна ветка транспорта = одна ветка тестов.

**Минусы / tradeoffs:**
- Если когда-нибудь понадобится UDP-transport (например, для обхода нового
  TCP-based DPI) — писать с нуля. Приемлемо, потребность гипотетическая.
- Legacy имена констант `QUIC_TUNNEL_MTU/MSS` остались (см.
  [../glossary.md](../glossary.md)). Новым людям это может путать. Переименовать
  можно в отдельном чистом коммите когда будет повод.

**Что открывает:**
- Можно сконцентрироваться на оптимизации H2/TLS ветки (TX ceiling, congestion
  tuning, parallel streams).

**Что закрывает:**
- Переключение на QUIC без заметных причин ≠ опция. Если вернёмся к
  UDP-transport — нужен новый ADR.

## References

- Commit: `04913e93` (v0.19.4, 2026-04-15)
- Связанные файлы (удалены): `crates/core/src/quic.rs`, `crates/core/src/congestion.rs`
- Связанные файлы (переименованы): `QuicConfig` → `TlsConfig` в `crates/core/src/config.rs`
- Предшествующая работа: v0.17.0 (H2 multi-stream), v0.17.2 (parallel per-stream batch loops)
