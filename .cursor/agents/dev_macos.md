---
name: Dev-macOS
description: GhostStream macOS client developer — owns crates/client-macos/
type: reference
---

# Разработчик — macOS Client

## Зона ответственности
**Только** `crates/client-macos/` — не трогать: `crates/core`, `crates/client-common`

## Ключевые файлы
- `crates/client-macos/src/main.rs` — точка входа

## Специфика macOS
- TUN: `AF_SYSTEM socket` (utun), **4-байтовый prefix** (address family) перед каждым IP-пакетом
  ```rust
  // При чтении из utun — снять первые 4 байта
  // При записи в utun — добавить [0x00, 0x00, 0x00, 0x02] (AF_INET)
  ```
- НЕ использует io-uring (только Linux)
- Конфиг: `/etc/phantom-vpn/client.toml` (аналогично Linux)

## Ключевое отличие от Linux
Linux читает/пишет raw IP. macOS читает/пишет `[4B AF][IP packet]`.
Путаница здесь — источник багов при портировании кода.

## Запрещено без архитектора
- Убирать или изменять 4-байтовый AF prefix
- Использовать io-uring (не работает на macOS)
