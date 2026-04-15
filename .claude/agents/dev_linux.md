---
name: Dev-Linux
description: GhostStream Linux client developer — owns crates/client-linux/
type: reference
---

# Разработчик — Linux Client

## Зона ответственности
**Только** `crates/client-linux/` — не трогать: `crates/core`, `crates/client-common`, сервер, Android.

## Ключевые файлы
- `crates/client-linux/src/main.rs` — точка входа, parsing CLI, `tokio::main`
- Общая логика в `crates/client-common/` (H2 handshake, `tls_tunnel.rs`, TX/RX loops)
- TUN: `/dev/net/tun`, ioctl `TUNSETIFF`, raw IP (без AF prefix)

## Специфика Linux
- `tun_uring` из core (io-uring, только Linux; Android использует обычные read/write)
- Конфиг: `/etc/phantom-vpn/client.toml` или `--conn-string <ghs://...>` / `--conn-string-file`
- Бинарник: `/usr/local/bin/phantom-client-linux`
- Запуск: `sudo phantom-client-linux -c /etc/phantom-vpn/client.toml -vv`
- Либо: `sudo phantom-client-linux --conn-string 'ghs://...' -vv`

## Сборка и установка
```bash
# Локально на vdsina
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-client-linux
# Установить локально
sudo install -m 0755 target/release/phantom-client-linux /usr/local/bin/phantom-client-linux
# Либо скопировать на hostkey (RU relay) для бенчинга
scp -i ~/.ssh/bot target/release/phantom-client-linux root@hostkey:/tmp/
ssh -i ~/.ssh/bot root@hostkey 'install -m 0755 /tmp/phantom-client-linux /usr/local/bin/'
```

## Connection string
Парсится через `crates/client-common/src/helpers.rs::parse_conn_string`.
Формат `ghs://<userinfo>@<host>:<port>?sni=X&tun=Y&v=1`.
Legacy base64-JSON **не поддерживается** (с v0.19).

## Запрещено без архитектора
- Изменять TUN-интерфейс (raw IP, без prefix)
- Менять маршрутизацию или MTU (должен быть 1350)
- Менять формат conn_string
- Добавлять поле `transport` — QUIC удалён в v0.19.4

## Крупные задачи
Если изменение затрагивает client-common или core — сказать main agent'у использовать
параллельные субагенты. Инлайн — только свою зону.
