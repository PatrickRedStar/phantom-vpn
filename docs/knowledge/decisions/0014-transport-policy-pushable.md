---
updated: 2026-10-26
---

# ADR 0014 — Server-pushable Transport Policy (все anti-DPI рычаги в конфиге)

**Status:** Accepted, реализован частично: доставки с сервера нет, и канала для неё тоже —
`/api/client-config` удалён; в проде всегда действуют встроенные дефолты (см. «Статус
реализации», 2026-10-26)
**Context-doc:** [architecture/dpi-tspu.md](../architecture/dpi-tspu.md)
**Связано:** ADR [0002 (Noise→mTLS)](0002-noise-to-mtls.md), [0003 (H2/TLS/TCP)](0003-h2-multistream-transport.md), [0011 (server verify)](0011-remove-insecure-always-verify.md)

## Context

Ресёрч + натурные тесты на MegaFon LTE (см. context-doc) показали: ТСПУ **троттлит**
GhostStream (не блокирует) — proxy-классификатор ловит его по (1) стоковому rustls
ClientHello fingerprint, (2) N параллельным TLS-коннектам к одному хосту, (3) ровному
bulk-профилю. Причём **терпимый набор fingerprint'ов инвертируется во времени**
(сегодня firefox ok, chrome подозрителен — завтра наоборот), а freeze-пороги меняются
по регионам/операторам.

Проблема: все эти рычаги сейчас — **компайл-тайм `const`** в `crates/core/src/wire.rs`
(`MAX_N_STREAMS`, heartbeat-интервалы, MTU), в `h2_transport.rs` (ClientHello/ALPN),
в `server/server/src/mimicry.rs` (удалён в v0.29.0). Смена подхода = **пересборка и переустановка каждого
клиента и сервера** на всех платформах. При гонке «cat-and-mouse» с ТСПУ это
неприемлемо — нужно менять fingerprint/топологию/шейпинг **с сервера, без релиза**.

## Decision

Ввести **`TransportPolicy`** — единую структуру со всеми anti-DPI рычагами, которая:

1. **Хранится на сервере** в `server.toml` секции `[policy]` (единый источник истины;
   `deploy.sh` разливает toml без пересборки).
2. **Пушится клиенту** через уже существующий эндпоинт `GET /api/client-config/:tun_addr`
   (поле `transport_policy` в `ClientConfigResponse`). Клиент уже периодически ходит в
   admin-API и кэширует ответ (`cachedExpiresAt` в `profiles.json`) — тот же путь.
3. **Кэшируется клиентом** и применяется на (ре)коннекте; при отсутствии/недоступности —
   fallback на встроенные дефолты (= текущее поведение).

**Вариант b для fingerprint (принято):** policy несёт не только *имя* профиля, но и
**сырой шаблон ClientHello** (`raw` — base64 байтов/спецификации расширений), чтобы
вводить новый браузерный отпечаток **вообще без релиза клиента**. Именованные профили
(`firefox`/`okhttp`/…), вкомпилированные в клиент, остаются как быстрый путь и fallback;
`raw` — динамический путь. Движок, потребляющий шаблон, — uTLS-подобный (BoringSSL через
`boring`, либо генератор ClientHello поверх низкоуровневого TLS). См. Phase 2.

### Схема (сокращённо)

```
TransportPolicy {
  schema_version: u32,
  fingerprint: { kind: default|named|raw, profile?, client_hello_b64? },
  alpn?: [String], tls_min?, tls_max?,
  streams: { topology?: parallel|single_mux, count?: usize },
  mtu?, mss?,
  padding:   { enabled?, min_frame?, target? , pace_ms? },
  heartbeat: { enabled?, interval_min_secs?, interval_max_secs?, start_jitter_*?, pkt_min?, pkt_max? },
  mimicry:   { enabled?, warmup_bytes?, warmup_secs? },
  recycle:   { bytes?, secs? },
  relay:     { mode?: passthrough|terminate_reoriginate, sni? }   // серверная/relay сторона
}
```

Все поля `Option` + `#[serde(default)]`. `ResolvedTransportPolicy` мержит policy поверх
`Default` (= текущие `const`).

## Backward-compat (ОБЯЗАТЕЛЬНО — старые клиенты работают)

- **Отсутствие policy = текущее поведение.** `ResolvedTransportPolicy::default()`
  воспроизводит встроенные const (на момент решения: `MAX_N_STREAMS=16`, heartbeat 15-45с,
  MTU 1300, padding off, ALPN=["h2"], rustls-default fingerprint; актуальные — в «Статусе
  реализации»).
- **Старый клиент ↔ новый сервер:** сервер добавляет `transport_policy` в JSON-ответ;
  старый клиент десериализует `ClientConfigResponse` с `serde` (unknown fields
  игнорируются) → **поле не ломает парсинг**, старый клиент просто его не видит и живёт
  на своих компайл-тайм дефолтах.
- **Новый клиент ↔ старый сервер:** поле отсутствует → `None` → дефолты.
- **`schema_version`:** клиент применяет поля, которые понимает; при major-несовпадении
  откатывается на дефолты. Философия форвард-компата уже в коде (`ghs://`-парсер
  игнорирует незнакомые query-параметры — `helpers.rs`).
- **Wire-affecting рычаги** (число стримов в handshake, схема padding, heartbeat-sentinel,
  MTU/mux-топология) должны совпадать на обоих концах. Источник один — сервер; он пушит
  клиенту И применяет у себя из того же `[policy]` → стороны согласованы by construction.
  Клиент-локальные рычаги (fingerprint, топология сокетов, recycle) могут отличаться.
- **Precedence:** user-override (`gui-ipc::TunnelSettings`) > server policy > built-in default.

## Rollout (фазы, каждая верифицируется device-smoke через adb-стенд)

- **Phase 1 — фундамент (эта итерация):** `core::policy` (struct + resolver + глобал
  `install/current`, дефолты = const); миграция параметрических рычагов (heartbeat,
  streams-count, padding/#3-shaping, MTU) на чтение из policy без смены поведения по
  умолчанию; `[policy]` в server config + `transport_policy` в `ClientConfigResponse`;
  клиентский fetch/cache/apply. Компайл + прогон существующих тестов.
- **Phase 2 — #1 uTLS fingerprint (вариант b):** движок ClientHello (boring/uTLS-подобный),
  потребляющий `fingerprint.raw`/`named`; терпимый дефолт (firefox/okhttp). Blast radius
  высокий (весь TLS-стек, mTLS, cert-verify) → отдельный impact + device-smoke.
- **Phase 3 — #2 single-conn mux:** N логических стримов внутри ОДНОГО TLS-коннекта
  (topology=single_mux), вместо N TCP+TLS. Переписывает TX/RX-loops и server accept.
  «Стримы = ядрам» сохраняется как логические стримы. Device-smoke обязателен.
- **Phase 4 — #4 relay terminate+reoriginate:** relay терминирует TLS на своём RU-домене
  (SNI==домен==IP relay) и реоригинирует relay→exit, вместо raw `copy_bidirectional`
  passthrough. Меняет relay PKI/cert. Device-smoke.

Каждая фаза — самостоятельный, backward-compatible шаг: до Phase 2 policy просто
переносит существующие числа; фичи включаются, только когда сервер их пушит.

## Статус реализации (2026-10-26)

**Сделано:** `core::policy` — типы, резолвер, глобал `install/current`; резолвер зажимает
heartbeat-параметры (интервал 1..60 с, заглушка 20..1200 байт), чтобы кривая policy не
роняла TX-задачу и не переживала детектор мёртвого стрима. Рантайм читает: `heartbeat.*`,
`padding.enabled/target`, `streams.count`, `fingerprint` (`named` → boring-путь; `raw`
пока тоже просто boring — шаблон не применяется), `mtls`.

**Не сделано (Phase 1 доставка):** секции `[policy]` в `server.toml` нет, клиентского
fetch/cache нет. Эндпоинт `GET /api/client-config`, через который планировалась доставка,
никто не вызывал — он удалён вместе с `ClientConfigResponse` (2026-10); подписку и
`enabled` клиенты теперь берут из `/api/me`. При возврате к доставке policy нужен новый
путь — например, поле в ответе `/api/me`. В проде
policy всегда = дефолты; `install()` вызывает только лабораторный харнесс (Android, cargo
feature `lab-overrides`, файл через `adb push`). Phase 3 (single-conn mux) и Phase 4
(relay terminate) не начинались.

**Поля, которые никто не читает:** `alpn`, `tls_min/max`, `streams.topology`, `mtu`,
`mss`, `padding.min_frame/pace_ms`, `mimicry`, `recycle`, `relay`, `schema_version`.
Оставлены в схеме ради совместимости; `mimicry` — пустышка: серверная warmup-мимикрия
удалена ([ADR 0019](0019-owner-decisions-audit-2026-10.md)), начало соединения маскирует
паддинг первых кадров. `heartbeat.enabled` удалён: выключать heartbeat
нельзя — на нём держатся NAT-записи и детектор мёртвого стрима.

**Дефолты сейчас:** heartbeat 30–60 с на стрим (несинхронно), ALPN клиента
`h2, http/1.1`, паддинг первых 10–20 кадров стрима — встроен в код, не через policy.

**Почему доставку не доделали:** эмпирика 2026-07-31 ([dpi-tspu.md](../architecture/dpi-tspu.md),
§0) показала, что наш троттл — лимит оператора на IP реле, и ни один рычаг скорость не
двигал. Возвращаться к доставке, когда появится реальный DPI-кейс, который рычаг лечит.

## Consequences

**+** Смена fingerprint/топологии/шейпинга/порогов — правка `server.toml`, ноль пересборок,
старые клиенты живут. Быстрая итерация против ТСПУ. Единая точка правды.

**−** Сервер становится источником transport-поведения (надо валидировать policy, чтобы
кривой конфиг не положил всех клиентов — отсюда обязательные дефолты-фолбэки и
`schema_version`). Wire-affecting рычаги требуют согласованного rollout сервера раньше
клиентов (сервер толерантен к обеим версиям в переходный период).

## Alternatives rejected

- **Вариант a (только именованные профили) как единственный путь** — не даёт вводить новый
  fingerprint без релиза; отвергнут в пользу b (named оставлены как fallback).
- **Раздать рычаги через `ghs://` URL** — URL это per-client provisioning, разовый; не
  подходит для динамических обновлений и раздувает conn-string. Policy идёт по refresh-каналу.
- **Оставить как есть (const + пересборка)** — неприемлемо для cat-and-mouse темпа.
