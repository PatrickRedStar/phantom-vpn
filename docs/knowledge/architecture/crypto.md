---
updated: 2026-04-17
---

# Crypto — TLS 1.3 + mTLS

## Overview

Весь трафик между клиентом и phantom-server защищён **TLS 1.3 с взаимной
аутентификацией** (mTLS). Сервер доказывает identity через публичный
LE cert (webpki-root chain); клиент — через per-client x509 сертификат,
подписанный self-signed PhantomVPN CA. Шифрование — `rustls 0.23` с
`ring` crypto provider, cipher suites TLS 1.3 по умолчанию. Noise protocol
удалён в v0.18 (см. [ADR 0002](../decisions/0002-noise-to-mtls.md)) — mTLS
стал единственным слоем аутентификации и шифрования.

Admin API использует отдельный TLS-пайплайн: self-signed cert для `10.7.0.1`
с TOFU-pinning на клиенте (см. [admin API](./admin-api.md)).

## TLS 1.3 параметры

- **Стек:** `rustls 0.23` + `ring`. Никаких custom crypto, никаких native-tls
  / openssl-bridge.
- **Cipher suites:** rustls дефолт для TLS 1.3 — `TLS_AES_256_GCM_SHA384`,
  `TLS_CHACHA20_POLY1305_SHA256`, `TLS_AES_128_GCM_SHA256`.
- **ALPN:** `h2` (только). См. [transport](./transport.md).
- **Session resumption:** включено через TLS 1.3 tickets, ускоряет reconnect
  после разрыва сети — но не 0-RTT (tradeoff vs anti-DPI).

## Server identity (публичный TLS)

phantom-server на NL exit'е предъявляет **Let's Encrypt cert для
`tls.nl2.bikini-bottom.com`**. Он же виден на nginx/443 (через ssl_preread
passthrough), он же — за счёт SNI-passthrough — виден на RU relay. Полный
chain (`fullchain.pem`) + private key лежат на vdsina, монтируются в
phantom-server и nginx.

Клиент верифицирует серверный cert через **webpki-roots + системный root store**:

```rust
roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
// + platform-specific native roots
```

Это значит: серверный cert должен быть выдан публичным CA — LE достаточно.
Никакого custom CA bundle клиенту не нужно, никакого `insecure=true` в
production profile'е быть не должно. Конфиг-флаг `insecure` оставлен для
local dev.

## Client identity (mTLS — PhantomVPN CA)

Клиентская аутентификация — self-signed PhantomVPN CA (существует только
на сервере, для выдачи client-cert'ов). CA:

- CA cert + private key: `/opt/phantom-vpn/config/ca.{crt,key}`.
- Генерится один раз при `setup-server.sh` (CommonName =
  "PhantomVPN Root CA"). Не ротируется автоматически.

На каждого клиента (по имени) генерится отдельный cert+key:

- `/opt/phantom-vpn/config/clients/<name>.crt`
- `/opt/phantom-vpn/config/clients/<name>.key`
- `ExtendedKeyUsage = ClientAuth`, CN = client name.

Генерация выполняется через `phantom-keygen` CLI при `setup-server.sh` или
динамически — админом через Admin API (`POST /api/clients`) — см.
[admin API](./admin-api.md) и `generate_client_cert` в
[admin.rs](../../../server/server/src/admin.rs).

## Keyring (`clients.json`)

Канонический индекс клиентов: `/opt/phantom-vpn/config/clients.json`.

```json
{
  "clients": {
    "alice": {
      "fingerprint": "aa:bb:…",
      "tun_addr": "10.7.0.2/24",
      "enabled": true,
      "created_at": "2025-01-01T00:00:00Z",
      "expires_at": 1780000000,
      "is_admin": false,
      "bytes_rx": 0, "bytes_tx": 0
    }
  }
}
```

Ключевые аспекты:

- **`fingerprint` = SHA-256 от DER client-cert'а.** Identity клиента. Rename
  записи в keyring fingerprint НЕ меняет.
- **`enabled`** — переключатель "принимать TLS от этого fp". Allow-list
  фильтр в `h2_server.rs` первым делом проверяет его; `false` ⇒ TCP drop
  без ответа, клиент увидит TLS-alert-less reset.
- **`is_admin`** — динамический флаг, проверяется per-request в admin-mTLS
  middleware. Toggle через `POST /api/clients/:name/admin` без перевыпуска
  cert'а.
- **`expires_at`** — unix timestamp. `run_subscription_checker` раз в 60 с
  переводит `enabled=false` на истёкших и закрывает их сессии (см.
  [admin API](./admin-api.md)).

Reload — hot, через SIGHUP или после каждой admin-mutation. Mutex
(`keyring_lock`) сериализует read-modify-write операции — защита от
TOCTOU между handlers и `run_subscription_checker`.

## Admin listener TLS

Admin API использует **второй TLS pipeline** — не тот, что на NL:443:

- Cert: self-signed для `10.7.0.1` (TUN-интерфейс сервера).
  Генерируется автоматически при первом старте phantom-server в
  `/opt/phantom-vpn/config/admin-server.{crt,key}`
  (`ensure_admin_server_cert` в
  [admin_tls.rs](../../../server/server/src/admin_tls.rs)).
- Client auth: mTLS (тот же PhantomVPN CA).
- Клиент (Android/iOS/Linux UI) пиннит SHA-256 сертификата сервера **TOFU**
  на первый успешный коннект (`VpnProfile.cachedAdminServerCertFp`).
- Loopback listener (`127.0.0.1:8081`) — plain HTTP с Bearer-token'ом,
  без TLS. Для Telegram-бота / break-glass — см. [admin API](./admin-api.md).

## Ключевой материал — где что

| Файл | Что |
|---|---|
| `/opt/phantom-vpn/config/ca.crt` | PhantomVPN CA (self-signed). Trust anchor для client cert'ов. |
| `/opt/phantom-vpn/config/ca.key` | CA private key. **Root-only, не бэкапить в git.** |
| `/opt/phantom-vpn/config/clients/<name>.{crt,key}` | Per-client identity. Key — 1 раз, cert — перевыпускаемый. |
| `/opt/phantom-vpn/config/clients.json` | Keyring (enable, is_admin, expires_at, stats). |
| `/opt/phantom-vpn/config/admin-server.{crt,key}` | Admin listener TLS cert (self-signed, auto-gen). |
| LE cert (`/etc/letsencrypt/live/tls.nl2…/`) | Публичный server cert. Renewed certbot-ом. |

Связь client-identity ↔ conn-string (`ghs://…`) — см.
[admin API](./admin-api.md) раздел Connection string и
[ADR 0004](../decisions/0004-ghs-url-conn-string.md).

## Invariants

- **TLS 1.3 only.** Ни TLS 1.2, ни downgrade. `rustls` конфиг не предусматривает.
- **Server cert public (LE), client cert private (PhantomVPN CA).** Два
  независимых trust chain'а. Перепутать их = TLS handshake provably failed.
- **Fingerprint (SHA-256) = identity клиента.** Любое поле в keyring
  (`name`, `tun_addr`, `is_admin`, `expires_at`) — metadata; fingerprint
  unique и immutable.
- **Никаких статических shared secrets.** Каждый клиент — уникальный x509.
  Noise keypair больше не существует (см. [ADR 0002](../decisions/0002-noise-to-mtls.md)).
- **Webpki roots + native roots оба включены в client trust store.** Fix
  коммита `c722d0e` — без native roots некоторые Android-устройства с
  custom CA store'ом ломали LE chain. В коде: `with_native_roots().and(webpki_roots)`.
- **Admin role ≠ cert.** `is_admin` в keyring, toggleable без перевыпуска.
  Если в будущем появится cert extension для admin — это будет breaking
  change и потребует нового ADR.
- **`admin-server.{crt,key}` генерится один раз и не ротируется** — TOFU
  pin'ы на клиентах не переживут ротацию. Если пришлось ротировать, всем
  клиентам нужно заново принять новый fingerprint.

## Sources

- Server TLS config: [server/server/src/main.rs](../../../server/server/src/main.rs),
  [core/src/tls.rs](../../../crates/core/src/tls.rs).
- Admin TLS:
  [server/server/src/admin_tls.rs](../../../server/server/src/admin_tls.rs)
  (`ensure_admin_server_cert`, `ClientIdentity`, `run_mtls`, `run_plain`).
- Client TLS dial:
  [client-common/src/tls_handshake.rs](../../../crates/client-common/src/tls_handshake.rs).
- Keyring load / fingerprint: [vpn_session.rs](../../../server/server/src/vpn_session.rs)
  (`load_allow_list`, `cert_fingerprint`).
- Client cert gen: [admin.rs](../../../server/server/src/admin.rs)
  (`generate_client_cert` — rcgen-based).
- gitnexus: `gitnexus_query({query: "tls mtls client cert"})`,
  `gitnexus_context({name: "generate_client_cert"})`.
- Связанные страницы: [handshake](./handshake.md), [admin API](./admin-api.md),
  [transport](./transport.md), [glossary](../glossary.md).
- Related ADRs: [0002-noise-to-mtls](../decisions/0002-noise-to-mtls.md) (мотивация
  перехода от Noise + QUIC к TLS 1.3 + mTLS),
  [0004-ghs-url-conn-string](../decisions/0004-ghs-url-conn-string.md) (cert
  distribution).
