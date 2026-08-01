---
updated: 2026-07-05
---

# ADR 0014 — Server-pushable Transport Policy (все anti-DPI рычаги в конфиге)

**Status:** Accepted (реализуется поэтапно)
**Context-doc:** [architecture/dpi-tspu.md](../architecture/dpi-tspu.md)
**Связано:** ADR [0002 (Noise→mTLS)](0002-noise-to-mtls.md), [0003 (H2/TLS/TCP)](0003-h2-tls-tcp.md), [0011 (server verify)](0011-remove-insecure-always-verify.md)

## Context

Ресёрч + натурные тесты на MegaFon LTE (см. context-doc) показали: ТСПУ **троттлит**
GhostStream (не блокирует) — proxy-классификатор ловит его по (1) стоковому rustls
ClientHello fingerprint, (2) N параллельным TLS-коннектам к одному хосту, (3) ровному
bulk-профилю. Причём **терпимый набор fingerprint'ов инвертируется во времени**
(сегодня firefox ok, chrome подозрителен — завтра наоборот), а freeze-пороги меняются
по регионам/операторам.

Проблема: все эти рычаги сейчас — **компайл-тайм `const`** в `crates/core/src/wire.rs`
(`MAX_N_STREAMS`, heartbeat-интервалы, MTU), в `h2_transport.rs` (ClientHello/ALPN),
в `server/server/src/mimicry.rs`. Смена подхода = **пересборка и переустановка каждого
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
  побайтово воспроизводит нынешние const (`MAX_N_STREAMS=16`, heartbeat 15-45с, MTU 1300,
  padding off, ALPN=["h2"], rustls-default fingerprint). Без установленной policy код
  ведёт себя как v0.27.x.
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
