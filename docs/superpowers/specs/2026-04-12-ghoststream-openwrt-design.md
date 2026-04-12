# GhostStream OpenWrt Client — Design Spec

**Дата:** 2026-04-12
**Статус:** Утверждён

---

## Обзор

Клиент GhostStream для OpenWrt роутеров. Интегрируется как netifd protocol handler с полноценной LuCI страницей. Установка через one-liner скрипт, который определяет архитектуру роутера и скачивает нужный бинарник.

## Целевые архитектуры

| Таргет | Rust target | OpenWrt arch | Примеры устройств |
|--------|-------------|-------------|-------------------|
| mipsel | `mipsel-unknown-linux-musl` | ramips/mt7621, mt76x8 | TP-Link Archer AX23, Xiaomi Mi Router 4A |
| aarch64 | `aarch64-unknown-linux-musl` | mediatek/filogic, qualcommax, rockchip | Xiaomi AX3000T, GL.iNet MT6000 |
| arm32 | `armv7-unknown-linux-musleabihf` | ipq40xx, mvebu/cortexa9 | Linksys EA8300, ZyXEL Armor Z2 |
| x86_64 | `x86_64-unknown-linux-musl` | x86/64 | Soft routers, VMs |

Все бинарники статически слинкованы с musl — zero runtime dependencies.

## Ограничения

- Бинарник ≤ 5 MB (цель ≤ 1 MB со сжатием UPX)
- 128 MB RAM — экономный runtime
- Нет io_uring на MIPS/ARM32 — fallback на plain read()/write()
- OpenWrt 24.10+ (ядро 6.6.73)

## Компоненты

### 1. Rust crate: `crates/client-openwrt/`

Минимальный VPN-демон. Переиспользует `phantom-client-common` (TLS connect, TX/RX loops) и `phantom-core` (wire format, crypto, MSS clamping).

**Отличия от client-linux:**
- TUN I/O через plain `read()`/`write()` (новый модуль `tun_simple` в phantom-core)
- Нет clap — аргументы через простой argv парсинг
- Минимальный logging (stderr)
- Принимает connection string как аргумент: `ghoststream --conn-string <base64>`
- Выводит в stdout JSON с параметрами для netifd при старте
- Слушает SIGTERM/SIGINT для graceful shutdown

**Оптимизация размера (profile.release):**
- `opt-level = "z"` — минимум размера
- `lto = true` — link-time optimization
- `strip = true` — убрать debug symbols
- `codegen-units = 1` — лучшая оптимизация
- `panic = "abort"` — убрать unwind таблицы

Ожидаемый размер: ~1.5-2.5 MB stripped, ~1 MB с UPX.

### 2. TUN fallback модуль: `phantom-core/src/tun_simple.rs`

Plain read/write TUN I/O без io_uring. Совместим с любым ядром Linux ≥ 3.x.

```rust
pub fn spawn_simple(tun_fd: RawFd, channel_size: usize)
    -> Result<(Receiver<Bytes>, Sender<Bytes>)>
```

Один reader thread + один writer thread. Такой же API как `tun_uring::spawn()`.

Feature flag в `phantom-core/Cargo.toml`:
```toml
[features]
default = ["io-uring-tun"]
io-uring-tun = ["dep:io-uring"]
```

`client-openwrt` подключает `phantom-core` с `default-features = false`.

### 3. netifd protocol handler: `/lib/netifd/proto/ghoststream.sh`

Shell-скрипт, регистрирующий протокол "ghoststream" в netifd.

**Конфигурация:**
- `connection_string` — base64 blob (обязательное)
- `mtu` — MTU TUN интерфейса (default 1350)

**Lifecycle:**
1. `proto_ghoststream_setup()` → запуск `/usr/bin/ghoststream` через `proto_run_command`
2. Демон создаёт TUN, подключается к серверу
3. `proto_ghoststream_teardown()` → `proto_kill_command` (SIGTERM)

UCI конфиг (`/etc/config/network`):
```
config interface 'ghoststream0'
    option proto 'ghoststream'
    option connection_string 'eyJhZGRyIjoi...'
    option mtu '1350'
```

### 4. LuCI proto page: `luci-proto-ghoststream/`

JS-модуль, наследующий `L.network.Protocol`.

**UI поля:**
- Connection String — textarea для вставки base64 строки
- MTU — число, default 1350

**Статус (в Interfaces overview):**
- Connected / Disconnected
- Uptime
- IP-адрес туннеля
- Bytes RX/TX

Файл: `htdocs/luci-static/resources/protocol/ghoststream.js`

### 5. Firewall интеграция (fw4)

Инсталлятор создаёт зону `ghoststream` через UCI:
- zone: input=REJECT, output=ACCEPT, forward=REJECT, masq=1, mtu_fix=1
- forwarding: src=lan, dest=ghoststream

Весь LAN-трафик маршрутизируется через VPN.

### 6. Install скрипт: `ghoststream-install.sh`

One-liner: `sh <(wget -O - https://raw.githubusercontent.com/PatrickRedStar/phantom-vpn/refs/heads/master/ghoststream-install.sh)`

**Шаги:**
1. Определить архитектуру (`uname -m`)
2. Скачать бинарник из GitHub Releases (`/usr/bin/ghoststream`)
3. Установить proto handler (`/lib/netifd/proto/ghoststream.sh`)
4. Установить LuCI файлы
5. Запросить connection string интерактивно
6. Создать UCI interface + firewall zone
7. Перезагрузить network + firewall
8. Вывести инструкцию "Откройте LuCI → Network → Interfaces"

### 7. CI/CD

В `.github/workflows/release.yml` — job `build-openwrt` с matrix strategy:
- 4 таргета (mipsel, aarch64, armv7, x86_64)
- Сборка через `cross`
- Strip + UPX сжатие
- Артефакты в GitHub Release: 4 бинарника + shell/LuCI файлы

## Файловая структура на роутере после установки

```
/usr/bin/ghoststream              # бинарник
/lib/netifd/proto/ghoststream.sh  # netifd proto handler
/www/luci-static/resources/protocol/ghoststream.js  # LuCI proto
/etc/config/network               # UCI: interface ghoststream0
/etc/config/firewall              # UCI: zone + forwarding
```
