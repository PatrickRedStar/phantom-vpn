---
updated: 2026-04-17
---

# Linux

Три независимых приложения в [apps/linux/](../../../apps/linux/), все работают
через unified `crates/client-core-runtime/` (ADR [0005](../decisions/0005-client-core-runtime.md)).

## Стек

| Компонент | Путь | Роль |
|---|---|---|
| `phantom-client-linux` (CLI) | [apps/linux/cli/](../../../apps/linux/cli/) | TUN CLI для headless/server-like сценариев |
| `ghoststream-gui` | [apps/linux/gui/](../../../apps/linux/gui/) | Desktop GUI (Rust + Slint) |
| `ghoststream-helper` | [apps/linux/helper/](../../../apps/linux/helper/) | Privileged демон, управляет TUN+routing; общается с GUI через `gui-ipc` |

### TunIo

- **CLI** и **helper** → `TunIo::Uring(RawFd)` — io_uring через
  [`phantom_core::tun_uring`](../../../crates/core/src/tun_uring.rs), zero-copy.
- Fallback на `tun_simple` (blocking read/write) если ядро без io_uring —
  актуально для старых дистров и OpenWrt-подобных сборок (см. коммит `1e1233d`,
  обработка отсутствующего `IORING_REGISTER_FILES`).

## CLI — `phantom-client-linux`

```bash
sudo phantom-client-linux --config /etc/phantom-vpn/client.toml
# или (после v0.19) — из conn_string:
sudo phantom-client-linux --conn-string 'ghs://...'
```

Требует root: создание TUN + манипуляция routing table / `ip rule` / iptables
(для split-routing и policy-based сохранения SSH-коннектов во full-tunnel).

## GUI — `ghoststream-gui` + `ghoststream-helper`

Split GUI ↔ helper (не один бинарь):

- **GUI** бежит в юзерском контексте под X/Wayland (Slint требует desktop
  session; не должен работать от root — security hygiene + AppArmor/SELinux нормы).
- **Helper** — минимальный privileged демон. Делает: открывает TUN fd, настраивает
  routing, запускает `client-core-runtime`, шлёт `StatusFrame`/`LogFrame` в GUI.

Канал между ними — **`gui-ipc`** ([crates/gui-ipc/](../../../crates/gui-ipc/)):
Unix socket + canonical serde_json wire types (`StatusFrame`, `TunnelSettings`,
`ConnectProfile`, `LogFrame`, `ConnState`). Те же самые типы используются iOS
(PhantomKit Codable mirrors) и Android (JNI JSON-strings).

## Конфиг (CLI)

`/etc/phantom-vpn/client.toml` — пример в [server/config/client.example.toml](../../../server/config/client.example.toml):

```toml
[network]
server_addr = "SERVER_PUBLIC_IP:443"
server_name = "tls.nl2.bikini-bottom.com"   # TLS SNI
insecure    = true
tun_name    = "tun0"
tun_addr    = "10.7.0.2/24"
tun_mtu     = 1350
default_gw  = "10.7.0.1"    # закомментировать для split-tunnel

[keys]
client_private_key = "..."
client_public_key  = "..."
server_public_key  = "..."
```

Пути ключей / сертификатов — абсолютные, проверяются при старте. В conn_string
(`ghs://`) cert и key закодированы base64url в userinfo — conn_string
альтернативен toml'у.

## Сборка

```bash
# Из корня репо
cargo build --release -p phantom-client-linux
# GUI + helper
cargo build --release -p ghoststream-gui -p ghoststream-helper
```

Слинт-ассеты и `build.rs` — в `apps/linux/gui/`. Для packaging —
`apps/linux/gui/packaging/`.

## Архитектурные особенности

- **Unified runtime** — CLI, helper и GUI (через helper) все делят
  `client-core-runtime`: одинаковая FSM (supervise с backoff `[3,6,12,24,48,60,60,60]`,
  8 попыток), одинаковая telemetry (`StatusFrame` раз в 250ms, EMA α=0.35),
  одинаковая log-структура.
- **io_uring TUN** — Linux единственная платформа с zero-copy I/O; на других
  платформах fallback variants (`BlockingThreads` на Android, `Callback` на iOS).
- **Policy-based routing** — при full-tunnel (`default_gw` прописан) SSH-коннекты
  к самому хосту сохраняются через `ip rule` (WireGuard-style). См. эпоху 1 в
  [timeline.md](../history/timeline.md) (коммиты `6f0e521`, `3f5697d`, `4e691fb`).
- **GUI bone-structure** — GUI не хранит секретов, не делает сетевых запросов
  сам; всё через helper по IPC. Reboot GUI не рвёт туннель (helper продолжает
  работать).

## Критичные pitfalls

- **Root нужен для CLI и helper** — TUN creation без `CAP_NET_ADMIN` невозможен.
- **Конфликт `tun0`** — если в системе стоит WireGuard с `wg0` или openvpn с `tun0`,
  задать явно `tun_name = "tun1"` в конфиге.
- **io_uring на старых ядрах** — `IORING_REGISTER_FILES` появился в 5.1, но
  feature-gate всё равно нужен: runtime детектит и падает обратно на
  `tun_simple` blocking I/O (`1e1233d`).
- **`default_gw` without policy-rule** — при full-tunnel без `ip rule` для SSH
  ты закрываешь себе доступ на хост. Проверять перед applying.
- **GUI ↔ helper версионирование** — тип `StatusFrame` в `gui-ipc` должен быть
  bin-compatible между GUI и helper (deploy'ятся разными пакетами). При breaking
  changes синхронно обновлять оба.

## Релизный процесс

Linux бинари релизятся через общий тег `v*` — CI
[`.github/workflows/release.yml`](../../../.github/workflows/release.yml) собирает
`phantom-client-linux` для `x86_64-unknown-linux-gnu` и кладёт в GitHub Release.
GUI/helper packaging — ручной (systemd unit templates в `apps/linux/gui/packaging/`,
helper устанавливается как systemd service с privilegde dropping после открытия TUN).

## Sources

- **CLI:** [apps/linux/cli/](../../../apps/linux/cli/)
- **GUI (Slint):** [apps/linux/gui/](../../../apps/linux/gui/)
- **Helper:** [apps/linux/helper/](../../../apps/linux/helper/)
- **Runtime:** [crates/client-core-runtime/](../../../crates/client-core-runtime/)
- **gui-ipc wire types:** [crates/gui-ipc/](../../../crates/gui-ipc/)
- **io_uring TUN:** [crates/core/src/tun_uring.rs](../../../crates/core/src/tun_uring.rs)
- **Client config:** [server/config/client.example.toml](../../../server/config/client.example.toml)
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md)
- **gitnexus:** `gitnexus_query({query: "linux cli client runtime"})`, `gitnexus_query({query: "tun uring fallback"})`
- **Build общий:** [../build.md](../build.md)
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
