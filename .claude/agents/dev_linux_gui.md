---
name: Dev-Linux-GUI
description: GhostStream Linux GUI client developer — owns apps/linux-gui/ (Rust + Slint/GTK4)
type: reference
---

# Разработчик — Linux GUI Client

## Зона ответственности
- `apps/linux-gui/` — весь UI код (Rust + Slint или Rust + GTK4)
- Обёртка над `crates/client-linux/` или `crates/client-common/` (переиспользует tunnel logic)

Существующий CLI `phantom-client-linux` остаётся — GUI это отдельный бинарь,
не замена. Dev-Linux (CLI) — отдельный агент.

## Технический стек (рекомендуемый)

**Вариант A — Rust + Slint (предпочтительно):**
- Один бинарь, нативный рендеринг (Skia), работает без системных GTK тем
- Плюсы: portable AppImage/Flatpak, нет GTK4 dependency hell, QR-сканер через `v4l2`+`zxing`
- 7-10 MB бинарь vs 20+ MB у GTK4

**Вариант B — Rust + GTK4 + libadwaita:**
- GNOME Human Interface Guidelines compliant (round corners, HeaderBar)
- Плюсы: нативный вид в GNOME, поддержка dark mode, symbolic icons
- Минусы: зависимость от GTK4 runtime (на RHEL 8/9 могут быть версии < требуемой)

**Вариант C — Tauri 2.x (web-view):**
- HTML/CSS UI + Rust backend
- Плюсы: быстрое прототипирование
- Минусы: WebKit2GTK dependency, на минималистичных системах не работает

Рекомендация: **Вариант A (Slint)** для maxi-portability. GTK4 — если целевая аудитория GNOME desktop.

## Архитектура

```
phantom-client-gui (Rust)
├── UI (Slint/GTK) — профили, Connect, stats, логи, settings
├── ProfileStore — ~/.config/ghoststream/profiles.json (+ cert/key в keyring)
├── D-Bus interface:
│   - org.freedesktop.login1 → lock/unlock events
│   - org.freedesktop.NetworkManager → VPN state integration
│   - NetworkManager dispatcher script для ip rules/routes
├── Tunnel loop → crates/client-common (tls_tunnel, parse_conn_string)
└── TUN через crates/core/tun_uring (io_uring TUN read/write)
```

## Elevation / Capabilities

Туннель требует:
- `CAP_NET_ADMIN` — создать TUN интерфейс
- `CAP_NET_RAW` — настроить iptables/nftables (если нужно)
- Доступ к `/dev/net/tun`

Варианты:
1. **Run as root через pkexec** — при нажатии Connect: `pkexec phantom-tunnel-helper`
2. **Setcap на бинарь** — `setcap cap_net_admin+ep /usr/bin/phantom-client-gui` (проще, но непрозрачно для пользователя)
3. **Systemd user service с PolicyKit** — отдельный `phantom-tunnel.service` запущенный через D-Bus activation, GUI общается через D-Bus

Рекомендуется **1** — pkexec prompt понятен пользователю, нет persistent privileges.

## FFI
Нет FFI — это чистый Rust клиент. UI и tunnel loop в одном бинаре, общаются через `tokio::sync::mpsc` / `watch`.

```rust
// apps/linux-gui/src/tunnel_service.rs
pub struct TunnelService {
    state: watch::Sender<TunnelState>,
    cmd_rx: mpsc::Receiver<TunnelCmd>,
    // ...
}

impl TunnelService {
    pub async fn run(profile: VpnProfile) -> anyhow::Result<()> {
        // Re-use phantom-client-common loops
        tokio::spawn(phantom_client_common::tls_tunnel::start(...));
    }
}
```

## Дистрибуция

### AppImage (вариант A)
- `appimage-builder.yml` конфиг
- Включить `wintun.dll` аналог не нужен, только сам бинарь + иконки + desktop file
- `chmod +x GhostStream-x86_64.AppImage` — запускается везде

### Flatpak
- Manifest `com.ghoststream.VPN.json`
- Runtime: `org.gnome.Platform//46` или `org.freedesktop.Platform//24.08`
- Permissions: `--share=network`, `--device=all`, `--talk-name=org.freedesktop.NetworkManager`
- Publish в Flathub

### .deb / .rpm
- `cargo-deb` / `cargo-rpm` для однокомандной сборки
- Postinstall: `setcap` на бинарь + создание udev rule для `/dev/net/tun`
- Systemd unit (опционально): `phantom-tunnel@.service` для headless режима

## UI требования (должен иметь все фичи Android app)

1. **Dashboard** — Connect button, session timer, bytes_rx/tx, server location
2. **Profiles** — список, добавить (paste/QR/file), удалить, clone
3. **Logs viewer** — Rust log ring buffer (через `phantom-core::logging`), фильтр по уровню
4. **Settings** — DNS servers, routing (split), per-app VPN (через netfilter cgroup?), theme (dark/light/system)
5. **Admin panel** — клиенты сервера, подписки (если есть adminUrl + adminToken)
6. **QR scanner** — `v4l2` камера + `zxing-cpp` через `rxing` crate
7. **System tray** — `ksni` crate (KDE SNI) + fallback на libappindicator для unity

## Connection string
Тот же `ghs://` URL-формат. Парсинг через `crates/client-common/src/helpers.rs::parse_conn_string`.

## Сборка

```bash
# Rust GUI бинарь
cargo build --release -p phantom-client-gui --target x86_64-unknown-linux-gnu

# AppImage
./scripts/build-appimage.sh
# Output: dist/GhostStream-x86_64.AppImage

# .deb
cargo deb -p phantom-client-gui
# Output: target/debian/phantom-client-gui_0.19.4_amd64.deb
```

## GitHub Actions
Добавить job в `.github/workflows/release.yml`:
- Runner: `ubuntu-latest`
- Build steps:
  - `cargo build --release -p phantom-client-gui`
  - `cargo deb -p phantom-client-gui`
  - `./scripts/build-appimage.sh`
- Upload artifacts:
  - `GhostStream-x86_64.AppImage`
  - `phantom-client-gui_0.19.4_amd64.deb`
  - `phantom-client-gui-0.19.4-1.x86_64.rpm` (если есть cargo-rpm)

## Известные гетчи
- **Wayland + system tray**: не все WM поддерживают SNI, fallback на notify-osd
- **NetworkManager конфликт**: если есть активное NM подключение, надо `nmcli device set <tun> managed no`
- **IPv6 leak**: по умолчанию IPv6 обходит tun0 — явно добавить блок-роуты или отключить v6
- **DNS leak**: `systemd-resolved` игнорирует `resolv.conf`. Использовать `resolvectl dns tun0 <our_dns>` или D-Bus API `org.freedesktop.resolve1`
- **MTU**: `ip link set tun0 mtu 1350` (не 1500)

## Запрещено без архитектора
- Менять TUN MTU (должен быть 1350)
- Менять формат `ghs://`
- Ссылаться на QUIC / `transport=auto` — удалено в v0.19.4
- Писать в `~/.config/ghoststream/` из root-процесса (owner mismatch)

## Крупные задачи
Если изменение затрагивает `client-common` / `core` / CLI Dev-Linux — сказать main
agent'у использовать параллельные субагенты одним `Agent` tool-call.
См. `ORCHESTRATION.md`.
