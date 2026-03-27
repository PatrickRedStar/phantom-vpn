---
name: Dev-Linux
description: GhostStream Linux client developer — owns crates/client-linux/
type: reference
---

# Разработчик — Linux Client

## Зона ответственности
**Только** `crates/client-linux/` — не трогать: `crates/core`, `crates/client-common`

## Ключевые файлы
- `crates/client-linux/src/main.rs` — точка входа
- TUN: `/dev/net/tun`, ioctl `TUNSETIFF`, raw IP (без AF prefix)

## Специфика Linux
- Использует `tun_uring` из core (io-uring, только Linux)
- Конфиг: `/etc/phantom-vpn/client.toml`
- Бинарник: `/usr/local/bin/phantom-client-linux`
- Запуск: `sudo phantom-client-linux -c /etc/phantom-vpn/client.toml -vv`

## Установка бинарника
```bash
scp -i ~/.ssh/personal root@89.110.109.128:/opt/phantom-vpn/src/target/release/phantom-client-linux \
  /tmp/phantom-client-linux
sudo install -m 0755 /tmp/phantom-client-linux /usr/local/bin/phantom-client-linux
```

## Запрещено без архитектора
- Изменять TUN-интерфейс (raw IP, без prefix)
- Менять маршрутизацию или MTU
