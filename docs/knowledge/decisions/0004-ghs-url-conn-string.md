---
updated: 2026-04-17
status: accepted
---

# 0004 — `ghs://` URL conn_string + dynamic admin mTLS

## Context

До v0.19 строка подключения клиента = **base64(JSON)** с полями:

```
server_addr, server_name, insecure,
cert_pem, key_pem, ca_cert_pem,
tun_addr,
admin_url, admin_token
```

Три связанных проблемы:

1. **JSON сложно парсить из строки.** Telegram-бот отдаёт пользователю одну
   длинную строку, пользователь копирует в клиент. Base64-JSON — ровно один
   "полезный" формат, но для Android/iOS парсинга нужно распаковать, распарсить
   JSON, провалидировать все поля. Ошибки при copy-paste (пробелы, обрыв
   строки) трудно диагностировать.
2. **`ca_cert_pem` в conn_string — бюрократия.** Webpki roots уже покрывают
   Let's Encrypt cert'ы сервера фронтенда. Внутренний mTLS использует PhantomVPN
   CA, но эта CA не нужна на клиенте — клиент валидирует server cert
   по fingerprint (TOFU), а свой client cert предъявляет серверу. `ca_cert_pem`
   был нужен только для old flow с custom rustls config.
3. **`admin_token` = shared secret.** Bearer token статический, сложно
   rotate (нужно пересоздать conn_string для всех админов). Если leak — меняем
   всем. При том что mTLS уже даёт аутентификацию по cert'у — зачем второй
   слой?

## Decision

Формат conn_string = **URL**:

```
ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1
```

Явно убраны поля:

- **`ca`** — webpki roots + pinning достаточно.
- **`admin_url`** — admin API слушает по `/api/...` на том же `host:port`.
- **`admin_token`** — заменён на mTLS + `is_admin` флаг в keyring.
- **`insecure`** — не нужен, всегда валидируем server cert.

**Admin auth** = mTLS client cert + `is_admin: true` в keyring на сервере.
Флаг **динамический** — toggle через `POST /api/clients/:name/admin` без
пересоздания cert'а. Bootstrap первого админа — через
`phantom-keygen admin-grant --name <n> --enable` локально на сервере.

**Server admin cert** = self-signed для `10.7.0.1` (tun-адрес сервера),
генерится автоматически при первом старте. **Android клиент** pinn'ит
SHA-256 (TOFU) в `cachedAdminServerCertFp` — повторное подключение проверяет
что отпечаток не изменился.

Внедрено в commit `f4377ca` (v0.19.0, 2026-04-15) — **breaking release**.

## Alternatives considered

1. **Оставить base64-JSON + добавить `version` field.** Отклонено: не решает
   основную проблему (shared `admin_token`). Плюс длина conn_string оставалась
   бы ~2KB, UX в Telegram-боте — плохой.

2. **JWT вместо mTLS для admin API.** Отклонено: требует отдельного сервера
   auth (issue JWT, rotation, revocation list). Когда mTLS уже есть для
   основного tunnel — дублирование. Флаг в keyring проще.

3. **Per-server admin token с refresh endpoint.** Отклонено: complexity
   без benefit'а. Refresh flow нужен для долгоживущих shared secret'ов, а
   mTLS cert per user решает это естественно — cert и так уникальный, и так
   revocable через keyring.

## Consequences

**Плюсы:**
- **conn_string короче** (~300 chars vs ~2KB). Помещается в один Telegram
  message без split.
- **Human-readable parts** — `sni`, `tun`, `host:port` видны в URL, base64
  только для sensitive блоба (cert+key). Easier debugging при copy-paste
  ошибках.
- **Admin dynamic** — включить/выключить админ-доступ клиенту одной командой
  без пересоздания cert'а и conn_string.
- **Single source of truth** для permissions — keyring на сервере
  (см. [../architecture/crypto.md](../architecture/crypto.md)).

**Минусы / tradeoffs:**
- **Breaking change.** Старые conn_string (v0.18 и ранее) не работают.
  Клиенты должны перегенерировать через Telegram-бота / admin API.
- **Backcompat НЕ поддерживается сознательно** — держать два парсера в
  production bloat'ит код и скрывает edge cases. Миграция одним шагом.
- **Bootstrap chicken-and-egg** — первому админу нужен локальный shell access
  на сервере для `phantom-keygen admin-grant`. В обмен на отсутствие shared
  bootstrap token'а.

**Что открывает:**
- **Telegram-бот** для self-service генерации conn_string — короткий URL
  легко отдавать через bot message.
- **Loopback admin listener** (127.0.0.1:8081 + Bearer token) — break-glass
  канал если основной mTLS admin флаг снесли и нужно восстановить доступ.
- Toggle `is_admin` через UI — admin app'ка на Android/iOS может включать
  других клиентов как админов без SSH на сервер.

**Что закрывает:**
- Возврат к base64-JSON ≠ опция.
- Shared bearer token'ов для admin API больше нет — всё через mTLS +
  dynamic flag.

## References

- Commit: `f4377ca` (v0.19.0, 2026-04-15) — "feat: v0.19.0 — ghs:// conn_string + dynamic admin mTLS (breaking)"
- Связанные файлы: `server/server/src/admin.rs` (build_conn_string), `crates/client-common/src/helpers.rs` (parse_conn_string), `apps/android/.../ConnectProfile.kt`
- Связанная архитектура: [../architecture/crypto.md](../architecture/crypto.md),
  [../architecture/admin-api.md](../architecture/admin-api.md)
- Предшествующая работа: ADR [0002](0002-noise-to-mtls.md) — введение mTLS как
  основы аутентификации
