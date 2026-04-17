---
updated: 2026-04-17
---

# Admin API

## Overview

HTTP API для управления сервером — клиенты, подписки, статистика, логи.
Встроен в `phantom-server` (отдельного бинаря нет). Два независимых
listener'а: **mTLS** через VPN-туннель (для Android/iOS/Linux UI) и
**loopback** на plain HTTP для Telegram-бота / break-glass. Оба listener'а
роутят в общий набор handler'ов; разница — только в auth-middleware.

Endpoint'ы минимальны и read-heavy; state — канонический `clients.json`
(keyring, см. [crypto](./crypto.md)) + живые `VpnSessionMap` для connected/
bytes_rx/tx/last_seen.

## Два listener'а (v0.19+)

| | mTLS listener | Loopback listener |
|---|---|---|
| Конфиг | `[admin].listen_addr` = `10.7.0.1:8080` | `[admin].bot_listen_addr` = `127.0.0.1:8081` |
| Транспорт | HTTPS + mTLS (self-signed для `10.7.0.1`) | Plain HTTP |
| Auth | Client cert → fingerprint → `is_admin=true` в keyring | `Authorization: Bearer <[admin].token>` |
| Доступ | Через VPN туннель (клиент уже на `10.7.0.0/24`) | Same-host only (bind `127.0.0.1`) |
| Для кого | Android/iOS/Linux админ-панели | Telegram-бот, ручной break-glass |
| Middleware | `require_admin` проверяет `ClientIdentity` extension + keyring | `require_admin` проверяет Bearer token |

**Почему два:**

- **mTLS listener** — primary канал. Клиент уже имеет cert'ом для VPN, тот же
  cert используется для admin auth. `is_admin` динамический (не в cert'e),
  toggle через admin endpoint без перевыпуска — см. [crypto](./crypto.md).
- **Loopback listener** — bot/break-glass. Telegram-бот живёт на том же хосте,
  ему mTLS chain не нужен; статический Bearer token проще. Bind на `127.0.0.1`
  делает external access невозможным.

Admin listener cert — self-signed для `10.7.0.1`, auto-gen при первом старте
в `/opt/phantom-vpn/config/admin-server.{crt,key}`. Android клиент хранит
`cachedAdminServerCertFp` — TOFU pin SHA-256 сертификата. При ротации cert'а
клиентам придётся заново принять новый fingerprint.

Bootstrap первого админа: `phantom-keygen admin-grant --name <name> --enable`
(прямая правка keyring'а; обычный API не даст, потому что нужен уже-админ).

## Auth middleware

```rust
// require_admin:
//   нет ClientIdentity  + Bearer совпал  → loopback+bot   → OK
//   ClientIdentity есть + is_admin=true  → admin client   → OK
//   иначе                                                  → 401 / 403

// require_valid_client (для /api/me):
//   любой валидный client cert (mTLS) ИЛИ loopback Bearer → OK
```

`ClientIdentity` — extension, injected в request admin-TLS accept-layer'ом
(`admin_tls::run_mtls`). Содержит `fingerprint` из peer-cert'а. Keyring
lookup — на каждый request (с READ-only блокировкой).

## Endpoints

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/api/status` | Uptime, active sessions count, server addr, exit IP |
| GET | `/api/me` | Self-inspection: `{name, is_admin}` (нужен только valid client cert) |
| GET | `/api/clients` | Полный список клиентов с live-метриками |
| POST | `/api/clients` | Создать: `{name, expires_days?, is_admin?}` → cert+key gen |
| POST | `/api/clients/:name/admin` | Toggle admin: `{is_admin: bool}` |
| DELETE | `/api/clients/:name` | Удалить: keyring entry + cert/key файлы |
| POST | `/api/clients/:name/enable` | `enabled=true` |
| POST | `/api/clients/:name/disable` | `enabled=false` (текущая сессия живёт до expire/idle) |
| GET | `/api/clients/:name/conn_string` | Regenerate `ghs://…` |
| GET | `/api/clients/:name/stats` | Time-series `[{ts,bytes_rx,bytes_tx}]` |
| GET | `/api/clients/:name/logs` | Последние 200 dst: `[{ts,dst,port,proto,bytes}]` |
| POST | `/api/clients/:name/subscription` | Управление expires_at (см. ниже) |
| GET | `/api/client-config/:tun_addr` | DNS / split-routing / subscription — для клиента по TUN IP |

`/api/me` — единственный endpoint с `require_valid_client`; остальные —
`require_admin`.

Subscriptions — POST body:

```json
{"action": "extend", "days": 30}   // expires_at += N дней
{"action": "set",    "days": 90}   // expires_at = now + N дней
{"action": "cancel"}               // expires_at = null (бессрочно)
{"action": "revoke"}               // enabled=false + expires_at=now (kick now)
```

`run_subscription_checker` (server/server/src/admin.rs:791) раз в 60 секунд
сканирует keyring: все `expires_at <= now && enabled` → `enabled=false` +
удаление сессии из `VpnSessionMap`. Lock (`keyring_lock`) общий с admin
handlers — no TOCTOU.

## GET /api/clients — формат ответа

```json
[{
  "name": "alice",
  "fingerprint": "aa:bb:…",           // SHA-256 DER client cert
  "tun_addr": "10.7.0.2/24",
  "enabled": true,
  "connected": true,                  // есть ли live session в VpnSessionMap
  "bytes_rx": 1234567,                // из VpnSession.bytes_rx (live), 0 если disconnected
  "bytes_tx": 654321,
  "created_at": "2025-01-01T00:00:00Z",
  "last_seen_secs": 3,                // now - session.last_seen, 0 если disconnected
  "expires_at": 1780000000,           // unix ts, null = бессрочно
  "is_admin": false
}]
```

Sort by `name` (stable order в UI). Live-метрики (`connected`,
`bytes_rx/tx`, `last_seen_secs`) мержатся из `VpnSessionMap` через lookup по
TUN IP. Если сессии нет — нули.

## Connection String (`ghs://…`)

Формат, который выдаёт `GET /api/clients/:name/conn_string`. Используется
всеми клиентами (Android, iOS, Linux, OpenWrt). Полный ADR — [ADR 0004](../decisions/0004-ghs-url-conn-string.md).

```
ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1
```

Структура:

- **userinfo** — base64url **двух PEM блоков подряд** (cert chain + PKCS8 key),
  разделённых `\n`. Парсер сплитит по `-----BEGIN` маркеру — не зависит от
  длины каждого PEM. Порядок блоков определяется по подстрокам
  `CERTIFICATE` / `PRIVATE KEY` (cert может идти первым или вторым).
- **host:port** — адрес phantom-server (или RU relay для RU абонентов).
- **sni** (обязателен) — TLS SNI; должен матчить LE cert сервера.
- **tun** (обязателен) — CIDR клиента (URL-encoded: `/` → `%2F`).
- **v=1** — версия формата. Unknown v → error.

**Чего в ghs://… нет (намеренно):**

- `ca` — CA не передаётся. Серверный cert верифицируется через системный +
  webpki root store (LE достаточно).
- `admin=true` — роль динамическая, из `is_admin` в keyring.
- `insecure` — production всегда `insecure=false`; для dev используется
  config-файл.
- Backcompat со старым base64(JSON) — отсутствует. Старые conn_string'и
  после v0.19.0 нужно regenerate через бота или admin UI.

Build/parse:

- Генерация: [admin.rs:build_conn_string](../../../server/server/src/admin.rs).
- Парсинг (Rust): [client-common/src/helpers.rs:parse_conn_string](../../../crates/client-common/src/helpers.rs).
- Парсинг (Android Kotlin): `apps/android/app/src/main/kotlin/com/ghoststream/vpn/data/ConnStringParser.kt`.
- Парсинг (OpenWrt shell): `apps/openwrt/proto/ghoststream.sh` — через
  `ghoststream --print-tun-addr`.

## Invariants

- **Mutating operations идут через `keyring_lock`.** Admin handlers +
  `run_subscription_checker` оба берут `tokio::sync::Mutex<()>` перед
  read-modify-write на `clients.json`. Параллельные мутации без этого
  lock'а ⇒ lost write.
- **`is_admin` проверяется per-request.** Toggle `/api/clients/:name/admin`
  вступает в силу на следующем запросе, без reconnect.
- **Revoke кикает сессию немедленно**: `enabled=false` + eviction из
  `VpnSessionMap` + `session.close()`. Клиент получит TCP reset на всех
  стримах, handshake-reconnect провалится на allow-list check.
- **Loopback token — secret**. Попадание `[admin].token` в git / логи =
  total compromise (bot-listener не проверяет client IP кроме bind'а).
- **Conn-string parser strict**: два PEM блока, оба маркера присутствуют,
  sni + tun query-params required, v == 1. Все нарушения ⇒ parse error,
  НЕ graceful defaults.
- **Нет audit log**. Кто и когда что делал — только в journald. Если
  понадобится per-action log — новый endpoint + storage.

## Sources

- Основной код: [server/server/src/admin.rs](../../../server/server/src/admin.rs)
  (handlers, `require_admin`, `build_conn_string`, `generate_client_cert`,
  `run_subscription_checker`).
- TLS pipeline: [admin_tls.rs](../../../server/server/src/admin_tls.rs)
  (`run_mtls`, `run_plain`, `ensure_admin_server_cert`, `ClientIdentity`).
- Conn-string parsing:
  [client-common/src/helpers.rs](../../../crates/client-common/src/helpers.rs)
  (`parse_conn_string`).
- gitnexus: `gitnexus_query({query: "admin api endpoint"})`,
  `gitnexus_context({name: "run_subscription_checker"})`,
  `gitnexus_context({name: "build_conn_string"})`.
- Связанные страницы: [crypto](./crypto.md) (mTLS / keyring / cert gen),
  [sessions](./sessions.md) (live metrics), [glossary](../glossary.md).
- Related ADRs: [0002-noise-to-mtls](../decisions/0002-noise-to-mtls.md)
  (mTLS как identity), [0004-ghs-url-conn-string](../decisions/0004-ghs-url-conn-string.md)
  (`ghs://` format).
