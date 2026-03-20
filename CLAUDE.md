# CLAUDE.md

Этот файл содержит рекомендации для Claude Code (claude.ai/code) при работе с кодом в данном репозитории.

## Обзор проекта

PhantomVPN — пользовательский VPN-протокол, маскирующий трафик под WebRTC/SRTP (видеозвонки) для обхода DPI. Трафик выглядит как зашифрованные H.264-видеопотоки поверх QUIC/HTTP3.

## Сборка

**На локальной машине (CachyOS) cargo не установлен.** Сборка происходит на сервере vdsina через SSH:

```bash
# Синхронизировать изменённые файлы на сервер и собрать там
rsync -avz -e "ssh -i ~/.ssh/personal" crates/ root@89.110.109.128:/opt/phantom-vpn/src/crates/
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "source ~/.cargo/env && cd /opt/phantom-vpn/src && cargo build --release -p phantom-server"

# Скачать готовый бинарник клиента
scp -i ~/.ssh/personal root@89.110.109.128:/opt/phantom-vpn/src/target/release/phantom-client-linux \
  /tmp/phantom-client-linux
sudo install -m 0755 /tmp/phantom-client-linux /usr/local/bin/phantom-client-linux
```

Если нужно собрать на машине с cargo:

```bash
cargo build --release -p phantom-server
cargo build --release -p phantom-client-linux
cargo build --release -p phantom-client-macos
cargo run --release --bin phantom-keygen
cargo check && cargo clippy && cargo test
```

## Развёртывание сервера

Сервер: `root@89.110.109.128`, директория `/opt/phantom-vpn/`, сервис `phantom-server.service`.

```bash
# Полный деплой (rsync source → remote build → перезапуск)
bash ./scripts/deploy.sh root@89.110.109.128 ~/.ssh/personal

# Быстрое обновление (только изменённые файлы)
rsync -avz -e "ssh -i ~/.ssh/personal" crates/ root@89.110.109.128:/opt/phantom-vpn/src/crates/
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "source ~/.cargo/env && cd /opt/phantom-vpn/src && \
   cargo build --release -p phantom-server && \
   install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server && \
   systemctl restart phantom-server.service"

# Управление клиентскими ключами
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "python3 /opt/phantom-vpn/keys.py \
   --server-config /opt/phantom-vpn/config/server.toml \
   --keyring /opt/phantom-vpn/config/clients.json"
```

## Клиент на локальной машине (CachyOS)

```bash
# Запуск
sudo phantom-client-linux -c /etc/phantom-vpn/client.toml -vv

# Конфиг
/etc/phantom-vpn/client.toml
```

## Структура Workspace

| Крейт | Назначение |
|-------|------------|
| `crates/core` | Общая библиотека: криптография, wire-формат, H264-shaping, сессии, конфигурация |
| `crates/server` | Серверный бинарник (Linux) + `phantom-keygen` |
| `crates/client-common` | Платформонезависимый QUIC-handshake + stream TX/RX циклы |
| `crates/client-linux` | Клиент Linux (TUN через `/dev/net/tun`) |
| `crates/client-macos` | Клиент macOS (utun через `AF_SYSTEM`) |

## Архитектура

### Транспорт

Единственный активный режим — **QUIC streams**:
- ALPN=`h3` (имитирует HTTP/3), порт `8443`
- TLS поверх QUIC (self-signed cert, `insecure=true` на клиенте)
- Noise IK поверх QUIC control stream для аутентификации и согласования ключей
- Данные туннеля передаются через **bidirectional QUIC stream** (надёжная доставка)

Legacy UDP+SRTP (порт 3478) — код сохранён в `wire.rs`, но не используется.

### Handshake (client-common/quic_handshake.rs)

```
Client → Server: QUIC connect (TLS 1.3 + ALPN h3)
Client → Server: open_bi() control stream
Client → Server: [4B len][Noise IK msg1]   (→ e, es, s, ss)
Server → Client: [4B len][Noise IK msg2]   (← e, ee, se)
Client → Server: open_bi() data stream
# Handshake complete, both sides have NoiseSession
```

### Wire Format — Stream Frame

Каждый фрейм в data stream:

```
[4B total_len][8B nonce (u64 BE)][Noise ciphertext + AEAD tag]
```

Plaintext внутри Noise AEAD — **batch формат**:

```
[2B pkt1_len][pkt1_bytes]
[2B pkt2_len][pkt2_bytes]
...
[2B 0x0000]      ← end-of-batch marker
[random padding до target_size]
```

`target_size` задаётся `H264Shaper` (имитация I/P кадров H.264).

Константы:
```
BATCH_MAX_PLAINTEXT = 65536   # максимальный размер одного фрейма
QUIC_TUNNEL_MTU     = 1350    # MTU TUN интерфейса в QUIC режиме
QUIC_TUNNEL_MSS     = 1310    # TCP MSS clamping
```

### Шифрование (core/src/crypto.rs)

```
Noise_IK_25519_ChaChaPoly_BLAKE2s
```

- **IK**: клиент знает публичный ключ сервера → нет round-trip для auth
- `StatelessTransportState` — nonce передаётся явно как u64
- Рекейинг: каждые 100 MB или 600 секунд (`REKEY_BYTES` / `REKEY_SECS`)

### Батчинг и шейпинг (client-common/quic_tunnel.rs, server/quic_server.rs)

**TX loop (оба клиент и сервер):**
1. Ждать первый пакет из TUN
2. Дренировать канал с `try_recv` до 64 пакетов (или пока `batch_data_bytes + 2 + pkt_len > BATCH_MAX_PLAINTEXT`)
3. Запросить `target_size` у `H264Shaper`
4. Упаковать в batch plaintext, зашифровать, отправить фрейм в stream

**RX loop:**
1. Читать `[4B len]`, затем `[nonce + ciphertext]`
2. Расшифровать → `extract_batch_packets` → каждый IP-пакет в TUN

### Шейпинг трафика (core/src/shaper.rs)

H.264 симуляция, 30 fps, GOP=60:
- I-кадр (каждые 60 кадров): burst 15–50 KB
- P-кадры: LogNormal (μ=7.0, σ=0.8), ~1–4 KB
- «Строгая фаза» первые 5 сек, затем «фаза простоя»

### Управление сессиями (core/src/session.rs)

- `ReplayWindow` — 64-битное скользящее окно, защита от replay-атак
- `NonceCounter` — монотонный u64
- QUIC keep-alive: 10 сек; idle timeout: 30 сек (core/src/quic.rs)
- Сессии на сервере: `DashMap<IpAddr, Arc<QuicSession>>` по tunnel IP клиента
- Cleanup task: каждые 60 сек удаляет сессии старше idle_secs

### Поток данных

```
[TUN]  ←read──  tun_reader_loop  ──→ mpsc::channel ──→  tun_to_quic_loop
                                                              │ batch + encrypt
                                                        quinn SendStream
                                                              │
[TUN]  ──write→  quic_stream_rx_loop  ←── quinn RecvStream  ─┘
                      │ decrypt + extract_batch
                      └→ tun_tx.send(ip_pkt)
```

### Маршрутизация на сервере

Обратный трафик (server→client) маршрутизируется по destination IP пакета:

```
DashMap<IpAddr, Arc<QuicSession>>
```

Сессия регистрируется при первом IPv4-пакете из клиентской tunnel-подсети.

### Различия TUN между платформами

**Linux** — `/dev/net/tun`, ioctl `TUNSETIFF`, raw IP
**macOS** — `AF_SYSTEM socket`, 4-байтовый prefix address-family + IP

## Конфигурация

```
config/server.example.toml → config/server.toml
config/client.example.toml → config/client.toml
```

### Сервер

- `listen_addr` — адрес:порт (напр. `89.110.109.128:8443`)
- `tun_addr` — `10.7.0.1/24`
- `wan_iface` — интерфейс для NAT (напр. `ens3`)
- `server_private_key`, `server_public_key`
- `cert_subjects` — SAN для self-signed TLS cert

### Клиент

- `server_addr` — `89.110.109.128:8443`
- `server_name` — SNI (можно IP, если `insecure=true`)
- `insecure` — `true` для self-signed cert
- `tun_addr` — `10.7.0.x/24`
- `tun_mtu` — `1350`
- `default_gw` — `10.7.0.1` (полный туннель)
- `client_private_key`, `client_public_key`, `server_public_key`
