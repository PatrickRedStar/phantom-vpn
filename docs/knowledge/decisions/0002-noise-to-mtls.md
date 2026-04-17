---
updated: 2026-04-17
status: accepted
---

# 0002 — Убрать Noise, перейти на mTLS

## Context

В ранней версии (до commit `c908d5e`, 2026-03-15) транспорт имел **двойное
шифрование**: Noise handshake поверх QUIC, затем встроенное QUIC/TLS. Noise
использовался как дополнительный layer аутентификации — клиенты держали
статический Noise keypair, сервер — список публичных ключей.

Проблемы такой схемы:

- **Overhead без benefit.** Два шифрованных слоя — дважды CPU, дважды
  handshake RTT. При этом TLS 1.3 сам по себе даёт authenticated encryption.
- **DPI-сигнатура.** Noise handshake отличается от обычного TLS ClientHello —
  DPI может scan'ить именно эти байты. Цель проекта — выглядеть как обычный
  HTTPS, а не как "HTTPS + что-то сверху".
- **Нет revocation.** Скомпрометированный Noise keypair нельзя отозвать иначе
  как пересборкой сервера. Нет стандартной PKI под это.
- **Shared secret distribution.** Keypair надо было передавать через side-channel,
  никакой стандартной упаковки не было.

К этому моменту H2/TLS уже был основным транспортом (см.
[0003-h2-multistream-transport.md](0003-h2-multistream-transport.md)), и
Noise стал третьим лишним.

## Decision

Удалить весь Noise-слой. Аутентификация = **mTLS client cert + fingerprint → keyring
lookup** в `clients.json` на сервере. CA — self-signed PhantomVPN CA. Один клиент =
уникальный x509 cert, не shared secret. Сервер при каждом connect сверяет SHA-256
fingerprint client cert'а с keyring'ом, смотрит флаг `enable` и дополнительные
атрибуты (`is_admin` для админов — см.
[0004-ghs-url-conn-string.md](0004-ghs-url-conn-string.md)).

Внедрено в commit `c908d5e` (2026-03-15).

## Alternatives considered

1. **Оставить Noise как optional layer поверх mTLS.** Отклонено: overhead без
   benefit'а. TLS 1.3 уже aead-crypto. Noise handshake — отдельная DPI-сигнатура,
   которую обход DPI как раз должен избегать.

2. **Только mTLS без CA (self-signed per-client).** Отклонено: невозможно
   массово revoke ("выключить всех клиентов у которых expired subscription").
   С CA достаточно поменять keyring entry — cert на клиенте остаётся, но сервер
   перестаёт его принимать.

3. **TLS PSK (pre-shared key) вместо mTLS.** Отклонено: PSK rotation — pain
   (каждое обновление secret требует side-channel доставки нового PSK всем
   клиентам). mTLS cert per client — наоборот, каждый клиент независимо.

## Consequences

**Плюсы:**
- Убрали ~1000 строк Noise-специфичного кода (handshake state machine, keystore,
  serialization).
- Double encryption gone — один TLS 1.3 слой, меньше CPU, меньше RTT.
- Стандартная PKI — revocation через `enable=false` в
  [keyring](../architecture/crypto.md), знакомо ops-инженерам.
- Меньше surface attack — нет custom crypto protocol.
- Fingerprint в keyring = **single source of truth для role** клиента (позже
  через это же поле появился `is_admin`).

**Минусы / tradeoffs:**
- Cert distribution теперь нужен через conn_string. Изначально это был
  base64(JSON) с полями `cert_pem`, `key_pem` — длинно и неудобно. Позже это
  привело к `ghs://` URL format (ADR
  [0004](0004-ghs-url-conn-string.md)).
- Self-signed CA — webpki клиенты не доверяют cert'у сервера без custom CA
  bundle. Ожидаемо для custom VPN, но для новых платформ нужно помнить.

**Что открывает:**
- Динамический admin role через `is_admin` в keyring (ADR
  [0004](0004-ghs-url-conn-string.md)).
- Fakeapp fallback при неправильном client cert — сервер проксирует в
  реальный upstream (например, `google.com`), DPI видит обычный HTTPS.

**Что закрывает:**
- Возврат к двойному шифрованию ≠ опция. Если когда-либо понадобится post-quantum
  layer поверх TLS — писать новый ADR с явной мотивацией.

## References

- Commit: `c908d5e` (2026-03-15) — "feat: remove Noise encryption layer, switch to mTLS + probe fix"
- Связанные файлы: `server/server/src/admin.rs` (keyring lookup), `server/server/src/main.rs` (clients.json load), `crates/core/src/tls.rs`
- Связанная архитектура: [../architecture/crypto.md](../architecture/crypto.md),
  [../architecture/transport.md](../architecture/transport.md)
- Последующая работа: `ghs://` URL + dynamic admin (ADR
  [0004](0004-ghs-url-conn-string.md))
