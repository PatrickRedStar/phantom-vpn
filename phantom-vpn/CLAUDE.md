# CLAUDE.md

Этот файл содержит рекомендации для Claude Code (claude.ai/code) при работе с кодом в данном репозитории.

## Обзор проекта

PhantomVPN — это пользовательский VPN-протокол, который маскирует трафик под WebRTC/SRTP (видеозвонки), чтобы обходить системы DPI (Deep Packet Inspection). Трафик выглядит как зашифрованные видеопотоки H.264, передаваемые по UDP/QUIC.

## Команды сборки

```bash
# Собрать всё
cargo build --release

# Собрать отдельные крейты
cargo build --release -p phantom-server
cargo build --release -p phantom-client-linux
cargo build --release -p phantom-client-macos
cargo run --release --bin phantom-keygen

# Проверка / линтинг
cargo check
cargo clippy

# Запуск тестов
cargo test
cargo test -p phantom-core   # тестировать конкретный крейт
```

**Бинарные файлы выводятся в:** `target/release/`

**Сервер требует root** (создаёт TUN-интерфейс + iptables NAT):

```bash
sudo ./target/release/phantom-server -c config/server.toml -v
sudo ./target/release/phantom-client-linux -c config/client.toml -vv
sudo ./target/release/phantom-client-macos -c config/client.toml -vv
```

## Развёртывание

```bash
# Развернуть/обновить сервер (локальная сборка, синхронизация бинарников через SSH)
bash ./scripts/deploy.sh root@<server-host> ~/.ssh/personal [--dry-run]

# Управление клиентскими ключами на сервере
ssh root@<server-host> "python3 /opt/phantom-vpn/keys.py \
  --server-config /opt/phantom-vpn/config/server.toml \
  --keyring /opt/phantom-vpn/config/clients.json"
```

## Структура Workspace

Это Cargo workspace со следующими крейтами:

| Крейт | Назначение |
|------|-------------|
| `crates/core` | Общая библиотека: криптография, wire-формат, shaping трафика, сессии, конфигурация |
| `crates/server` | Серверный бинарник только для Linux + бинарник `phantom-keygen` |
| `crates/client-common` | Платформонезависимый QUIC-handshake + циклы туннеля |
| `crates/client-linux` | Клиент для Linux (TUN через `/dev/net/tun`) |
| `crates/client-macos` | Клиент для macOS (utun через сокет `AF_SYSTEM`) |

## Архитектура

### Транспортные уровни

Проект имеет два режима транспорта:

- **Legacy UDP+SRTP** — пакеты оборачиваются в поддельные SRTP-заголовки на порту 3478
- **Текущий QUIC** — ALPN="h3" (имитирует HTTP/3), порт 443, с шифрованием Noise поверх QUIC-датаграмм

### Шифрование

Шаблон протокола Noise:

```
Noise_IK_25519_ChaChaPoly_BLAKE2s
```

- **IK (Initiator Knows)**: клиент знает публичный ключ сервера → handshake с 0-RTT
- Используется `StatelessTransportState` — nonce передаётся явно, без изменения внутреннего состояния
- Реключение ключей после 100 MB или 600 секунд (`REKEY_BYTES` / `REKEY_SECS` в `crypto.rs`)

### Wire Format (`core/src/wire.rs`)

Открытый текст внутри AEAD:

```
[0-1]  inner_ip_len (u16 BE)
[2..]  IP пакет
[..]   случайный padding
```

Перед nonce добавляется 8 байт (u64 LE).  
Заголовок SRTP (12 байт) используется только в legacy UDP-режиме.

Поле SSRC в SRTP:

```
HMAC-SHA256(shared_secret, client_public_key)[0..4]
```

Позволяет идентифицировать клиента без полной расшифровки.

### Шейпинг трафика (`core/src/shaper.rs`)

Симуляция кодека H.264 на 30 fps, GOP = 60 кадров:

- I-кадр каждые 60 кадров (burst 15–50 KB)
- P-кадры: распределение LogNormal (μ=7.0, σ=0.8)
- «Строгая фаза» первые 5 секунд, затем «фаза простоя»

### Управление сессиями (`core/src/session.rs`)

- `ReplayWindow` — 64-битное скользящее окно предотвращает replay-атаки; отклоняет пакеты с номером последовательности более чем на 64 назад
- `NonceCounter` — монотонный u64; младшие 16 бит используются как SRTP `seq_num` в UDP-режиме

### Поток данных (режим QUIC)

```
TUN interface ←→ [IP пакет] ←→ TX/RX loops (client-common/quic_tunnel.rs)
                              ↕ Noise encrypt/decrypt
                     QUIC datagrams ←→ quinn::Endpoint
```

Сервер маршрутизирует возвращаемые пакеты по TUN IP клиента через:

```
DashMap<IpAddr, QuicSession>
```

в `sessions.rs`.

### Различия TUN между платформами

**Linux**

```
/dev/net/tun
```

- используется ioctl `TUNSETIFF`
- формат пакета = raw IP

**macOS**

```
AF_SYSTEM socket
```

- формат пакета = 4-байтовый префикс address-family + IP пакет

## Конфигурация

Скопируйте:

```
config/server.example.toml → config/server.toml
config/client.example.toml → config/client.toml
```

Ключевые поля:

### Сервер

- `listen_addr`
- `tun_addr` (10.7.0.1/24)
- `wan_iface` (для NAT)
- `server_private_key`
- `server_public_key`
- `cert_subjects` (SAN для self-signed TLS)

### Клиент

- `server_addr`
- `server_name` (SNI)
- `insecure` (пропустить проверку сертификата для self-signed)
- `tun_addr` (10.7.0.x/24)
- `default_gw` (10.7.0.1 для полного туннеля)
- все три ключа

## Константы MTU (`core/src/wire.rs`, `core/src/mtu.rs`)

```
TUNNEL_MTU = 1380     # режим UDP
QUIC_TUNNEL_MTU = 1350  # режим QUIC
```

TCP MSS ограничивается (clamped) для пакетов, выходящих из TUN-интерфейса.

