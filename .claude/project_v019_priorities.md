---
name: v0.19+ priority list (обновлено 2026-04-15 после v0.19.4)
description: Что уже сделано и что осталось для v0.19/v0.20 — стелс, UX, инфра. Perf items закрыты/disproven.
type: project
originSessionId: 7c766df7-cd9f-4e4e-862b-2fb753f37291
---
Обновлено 2026-04-15 после релиза v0.19.4. Perf-часть плана закрыта (disproven в `reference_v019_perf_tests.md` + cleanup в v0.19.4). Остаток — stealth, UX, infra.

## ✅ Закрыто в v0.19.x (см. project_v019_4_shipped.md)

- QUIC полностью удалён (~870 строк мёртвого кода)
- DNS passive cache fix + 4 unit-теста
- io_uring panic paths → graceful error
- Android thread::spawn graceful error
- admin.rs remove_dir guard
- Renaming QuicConfig → TlsConfig

## Priority 1 — Stealth (для v0.20)

1. **Detection vector 11 — timing jitter** — inter-batch delay LogNormal(mu=3.3, sigma=1.2) только когда `batch.len() < 3` (idle-like traffic). Файлы: `client-common/src/tls_tunnel.rs`, `crates/server/src/h2_server.rs`. Details: `reference_detection_vectors_11_13.md`.

2. **Detection vector 13 — connection migration** — периодическая ротация TLS-стримов (10-30 мин jitter). Сервер уже поддерживает через attach/detach (verified в v0.18 shipped state). Client-only change.

3. **Rotated SNI pool** — клиент выбирает random SNI из пула при каждом connect. Нужна nginx config + client code. Повышает сопротивляемость active-probing.

## Priority 2 — UX/Infra

4. **Android Clone profile** — `ProfilesStore.cloneProfile()`, копирование cert/key, UI button. См. `feedback_profile_ux.md`. Низкая сложность, высокая ценность — пользователь жаловался.

5. **`scripts/keys.py` rewrite** — сейчас legacy base64-JSON генератор, нужно переписать под ghs:// формат. Текущий workaround: conn strings выдаются через `/api/clients/:name/conn_string`.

6. **iperf3 bench script** — автоматизировать hostkey benchmark (рецепт в `reference_server_side_bench.md`).

## Priority 3 — Research / Deferred

7. **Buffer pool (BytesMut slab)** — -30K alloc/s, <5% реальный throughput impact. Низкий приоритет.
8. **Telemetry endpoint** — `/api/perf` с per-stream throughput/latency.
9. **RBT (Randomized Batch Timing)** — deferred в v0.18 plan, всё ещё не реализован. `crates/core/src/rbt.rs` не существует.

## Что НЕ делаем

- Micro-optimize hot path (disproven в `reference_v019_perf_tests.md`)
- Вернуть QUIC (см. `reference_quic_status.md`)
- Ограничить `effective_n` сервером (anti-DPI дизайн, см. v0.18 detection_vectors)
- Заменить DNS parser на `trust-dns-proto` (тянет 200KB, после fix ручной достаточен)

**How to apply:** При next sprint задача — items 1-4. Выполнять через мульти-агентов (см. `feedback_multi_agents.md`). Бенчить на hostkey перед шипингом любых stealth-изменений.
