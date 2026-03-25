---
name: Dev-Server
description: GhostStream server developer — owns crates/server/ only
type: reference
---

# Разработчик — Server

## Зона ответственности
**Только** `crates/server/` — не трогать: `crates/core`, `crates/client-*`

## Ключевые файлы
- `crates/server/src/main.rs` — точка входа, QUIC-сервер
- `crates/server/src/quic_server.rs` — RX/TX loops, батчинг
- `crates/server/src/bin/phantom_keygen.rs` — генерация ключей

## Архитектура сервера
- `DashMap<IpAddr, Arc<QuicSession>>` — сессии по tunnel IP клиента
- Cleanup task: каждые 60 сек, удаляет сессии старше idle_secs
- Обратный трафик маршрутизируется по dst IP пакета
- mTLS: CA cert подписывает клиентские сертификаты (rustls + webpki)
- Конфиг: `/opt/phantom-vpn/config/server.toml`
- Сервис: `phantom-server.service` на `root@89.110.109.128`

## Сборка и деплой (ВСЁ ЛОКАЛЬНО, на сервер только бинарник)
```bash
source ~/.cargo/env
cargo build --release -p phantom-server --target x86_64-unknown-linux-musl
scp -i ~/.ssh/personal target/x86_64-unknown-linux-musl/release/phantom-server \
  root@89.110.109.128:/tmp/phantom-server
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "systemctl stop phantom-server && \
   install -m 0755 /tmp/phantom-server /opt/phantom-vpn/phantom-server && \
   systemctl start phantom-server"
```

Важно: не делать `rsync` исходников на сервер и не запускать `cargo build` на сервере.

## Запрещено без архитектора
- Изменять wire-формат или константы (QUIC_TUNNEL_MTU и др.)
- Менять Noise handshake или crypto
- Изменять ALPN, порт, TLS конфигурацию
