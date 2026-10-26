---
updated: 2026-10-27
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
sudo phantom-client-linux --conn-string 'ghs://...'
# или из файла (так запускается headless-клиент на vps_balancer):
sudo phantom-client-linux --conn-string-file /etc/phantom-vpn/conn_string
```

Переподключением владеет ядро ([ADR 0018](../decisions/0018-rust-owns-reconnect.md)):
CLI запускает его с настройками по умолчанию (`auto_reconnect = true`), сетевые
обрывы ретраятся бесконечно, без выхода процесса. CLI завершается только по
SIGINT/SIGTERM или на фатальной ошибке (отзыв, истёкший доступ, часы, закрытый
TUN) — с причиной в stderr и кодом ≠ 0. `Restart=` у systemd нужен только на
этот случай. GUI/helper берут `auto_reconnect` из настроек; helper на
Disconnect сначала отменяет ядро, потом снимает TUN, так что ручное отключение
не выглядит фатальной ошибкой.

Требует root: создание TUN + манипуляция routing table / `ip rule` / iptables
(для split-routing и policy-based сохранения SSH-коннектов во full-tunnel).

## GUI — `ghoststream-gui` + `ghoststream-helper`

Split GUI ↔ helper (не один бинарь):

- **GUI** бежит в юзерском контексте под X/Wayland (Slint требует desktop
  session; не должен работать от root — security hygiene + AppArmor/SELinux нормы).
- **Helper** — минимальный privileged демон. Делает: открывает TUN fd, настраивает
  routing, запускает `client-core-runtime`, шлёт `StatusFrame`/`LogFrame` в GUI.
- **Админка** (экран Admin) ходит в admin API (`10.7.0.1:8080`, только через
  поднятый туннель) по mTLS с сертом и ключом активного профиля, как Android и
  Apple; admin-серт пинится при первом ответе
  ([admin_api.rs](../../../apps/linux/gui/src/admin_api.rs)). Bearer сервер
  принимает только со своего loopback, поэтому поле «Admin token» в редакторе
  профиля больше не используется (значение хранится, но не отправляется).

Канал между ними — **`gui-ipc`** ([crates/gui-ipc/](../../../crates/gui-ipc/)):
Unix socket + canonical serde_json wire types (`StatusFrame`, `TunnelSettings`,
`ConnectProfile`, `LogFrame`, `ConnState`). Те же самые типы используются iOS
(PhantomKit Codable mirrors) и Android (JNI JSON-strings).

## Конфиг (CLI)

Единственный рабочий формат — строка подключения `ghs://` (cert и key
закодированы base64url в userinfo, см. [ADR 0004](../decisions/0004-ghs-url-conn-string.md)).
TOML-конфиг рантаймом не поддерживается: CLI с ним завершается с ошибкой
«use --conn-string or --conn-string-file» (реликтовый `client.example.toml`
удалён).
`PHANTOM_NO_DEFAULT_ROUTE=1` — не ставить глобальный default route (headless-боксы,
см. [server.md](server.md)).

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
  `client-core-runtime`: одинаковая FSM (supervise: бесконечный ретрай с паузой
  до 30 с при `auto_reconnect`, `error` — только фатальные причины), одинаковая
  telemetry (`StatusFrame` раз в 250ms, EMA α=0.35), одинаковая log-структура.
- **io_uring-потоки поднимаются один раз на `run()`**, а не на каждый реконнект
  (раньше старый читатель съедал пакеты нового).
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
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md)
- **gitnexus:** `gitnexus_query({query: "linux cli client runtime"})`, `gitnexus_query({query: "tun uring fallback"})`
- **Build общий:** [../build.md](../build.md)
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
