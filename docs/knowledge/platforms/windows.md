---
created: 2026-05-17
updated: 2026-05-17
status: in-progress
tags: [platform, windows, slint, wintun]
---

# Windows

Нативный desktop клиент через [Wintun](https://www.wintun.net/) (юзер-mode TUN
драйвер от WireGuard team) + Slint UI на том же rendering стеке, что Linux GUI.
Всё в одном процессе с правами админа — отдельного service в MVP нет.

Зрелость: **in-progress** (v0.1.0 шаблон, ветка `feature/windows-client`).
Активная разработка под Phase 5/6 (UTM smoke + физическая Windows тестовая
машина), squash-merge в master ожидается после прохождения финального gate.

## Стек

| Компонент | Путь | Роль |
|---|---|---|
| `client-windows-core` | [crates/client-windows-core/](../../../crates/client-windows-core/) | Headless Rust core: `WintunBackend` (cfg=windows), `MockBackend` (cfg=not(windows) для тестов), profile load/save |
| `ghoststream-windows` | [apps/windows/gui/](../../../apps/windows/gui/) | GUI бинарь — Slint UI + tokio worker + tray + Wintun wiring |
| `client-core-runtime` | [crates/client-core-runtime/](../../../crates/client-core-runtime/) | Кросс-платформенный — добавлен `TunIo::Backend(Arc<dyn TunBackend>)` variant для Windows + headless тестов (ADR [0005](../decisions/0005-client-core-runtime.md)) |
| Wintun DLL | bundled рядом с .exe | Юзер-mode TUN драйвер, скачивается в CI с wintun.net и кладётся в ZIP artifact |

### TunIo

`TunIo::Backend(Arc<dyn TunBackend>)` — новый variant в `client-core-runtime`,
кросс-платформенный. На Windows wrapper над `wintun::Session`; на Mac/Linux
для тестов — `MockBackend` с in-memory VecDeque очередями.

`TunIo::Uring` остаётся под `cfg(target_os = "linux")`, `TunIo::BlockingThreads`
под `cfg(unix)` — Windows этих вариантов не видит. Это сохраняет нулевой риск
регрессий для Android/iOS/Linux: их code paths не тронуты, только enum
расширен.

## Структура `apps/windows/gui/`

```
apps/windows/gui/
  Cargo.toml                  # slint 1.8 + tray-icon 0.20 + embed-resource 2.5
  build.rs                    # slint_build::compile + embed_resource при TARGET=windows
  app.manifest                # requireAdministrator + DPI awareness PerMonitorV2
  app.rc                      # 1 24 "app.manifest"
  src/
    main.rs                   # Two-thread: Slint event loop + tokio worker
    bridge.rs                 # StatusFrame/LogFrame → UI properties (upgrade_in_event_loop)
    controller.rs             # ActiveTunnel + start_tunnel (real Wintun на Windows, simulator на Mac)
    tray.rs                   # tray-icon: иконка + Show/Connect/Disconnect/Quit
    wintun_loader.rs          # locate_wintun_dll() — рядом с exe / System32 fallback
  ui/
    theme.slint               # 1:1 копия apps/linux/gui/ui/theme.slint
    main.slint                # MainWindow (480×720)
  assets/
    fonts/                    # Instrument Serif + Departure Mono + JetBrains Mono
  design/
    mockup.html               # утверждённый дизайн (warm-black + phosphor-lime)
```

### Two-thread architecture

Как в Linux GUI ([apps/linux/gui/src/main.rs](../../../apps/linux/gui/src/main.rs)):

- **Main thread** — Slint event loop, MainWindow callbacks
- **Worker thread** (`ghoststream-worker`) — tokio current_thread runtime,
  владеет `Option<ActiveTunnel>`, читает `UiCommand` channel

Сообщение из UI → tokio: `tokio::sync::mpsc::UnboundedSender<UiCommand>`.
Сообщение из tokio → UI: `slint::Weak::upgrade_in_event_loop(closure)` — под
капотом invoke_from_event_loop, всё UI mutation в event-loop thread.

В отличие от Linux, нет helper-демона: GUI и runtime в одном процессе. Это
работает потому что UAC manifest требует admin прав при запуске — Wintun
драйвер и `netsh` управление маршрутами доступны из самого GUI. Service-mode
с named pipe IPC откладывается на v2.

## Wintun-специфика

- **MTU 1350** — стандарт GhostStream, явная установка через
  `adapter.set_mtu(1350)`. Wintun дефолт 1500 → фрагментация под TSPU.
- **Address 10.7.0.2/30** — захардкожено в MVP (`WintunConfig` в
  [controller.rs](../../../apps/windows/gui/src/controller.rs)). В следующих
  итерациях выводится из handshake response.
- **IPv6 leak** — Wintun по умолчанию не блокирует IPv6 через physical
  adapter. TODO: `netsh interface ipv6 set route ::/0 <wintun_idx>` после
  successful handshake.
- **wintun.dll** ищется через `locate_wintun_dll()`:
  1. Рядом с `ghoststream.exe` (бандл из CI — стандарт).
  2. `C:\Windows\System32\wintun.dll` (fallback, если установлен системно).

- **Adapter cleanup** — `WintunBackend::shutdown()` → `session.shutdown()`.
  Drop order: session → adapter → Wintun handle. Если процесс убит kill
  -9, adapter может остаться "висящим" — повторный запуск его подхватит
  через `Adapter::open()` (fallback на create).

## UAC и manifest

`apps/windows/gui/app.manifest` декларирует:

- `<requestedExecutionLevel level="requireAdministrator"/>` — пользователь
  видит UAC при запуске. Это блок в v2 заменим на Windows Service.
- `<dpiAwareness>PerMonitorV2</dpiAwareness>` — на 4K мониторах нет blurry
  rendering.
- `<supportedOS>` — Win10 + Win11.

`embed-resource = "2.5"` встраивает manifest и (будущую) icon в .exe через
rc.exe (MSVC) или x86_64-w64-mingw32-windres (MinGW). Кросс-сборка с Mac
работает после `brew install mingw-w64`.

## Тестирование

### На Mac (dev loop)

```bash
cd /Users/p.kurkin/ghoststream-windows
cargo test -p client-windows-core           # MockBackend roundtrip + WouldBlock + dyn dispatch
cargo run -p ghoststream-windows            # окно + симулятор Connect
cargo check --target x86_64-pc-windows-gnu -p ghoststream-windows  # cross-compile
```

Симулятор в `controller.rs` под `cfg(not(windows))` эмулирует Handshaking →
Transmitting → счётчики тикают → Disconnect. Это позволяет визуально тестить
UI без админ-прав и без сервера.

### В CI (windows-latest)

[.github/workflows/windows-ci.yml](../../../.github/workflows/windows-ci.yml):

- `cargo test -p client-windows-core` — те же 3 теста что и на Mac
- `cargo build --release -p ghoststream-windows` → `ghoststream-windows.exe`
- Скачивает `wintun-0.14.1.zip` с wintun.net, копирует `wintun.dll` рядом с .exe
- Artifact: `GhostStream-Windows.zip` (`.exe` + `wintun.dll`, retention 30 дней)
- Триггеры: push в `master`/`feature/windows-client`, PR на Windows-paths

### Smoke на UTM (Phase 5)

Win11 ARM ISO в UTM, x86 эмуляция через Microsoft. Скачать ZIP из CI,
распаковать, ПКМ → "Запуск от имени администратора". Прогнать чек-лист:

1. UAC → принять
2. Profile auto-loaded из `%APPDATA%\GhostStream\config\profile.json`
3. Connect → ждать Connected статус
4. `route print` → маршруты на wintun adapter (0.0.0.0/1 + 128.0.0.0/1)
5. ifconfig.io → IP vdsina
6. nslookup → DNS через VPN (если включён)
7. Disconnect → "Dormant" + маршруты сняты

### Физическая Windows (Phase 6)

Финальный gate — пользователь тестирует на реальной x64 машине. Тот же
чек-лист + расширенные сценарии: 5 минут видео, switch Wi-Fi, sleep / wake,
reboot.

## Релизный процесс

| Шаг | Действие |
|---|---|
| 1 | `git push origin feature/windows-client` → CI собирает .exe + ZIP |
| 2 | Скачать `GhostStream-Windows.zip` из artifacts, smoke на UTM |
| 3 | Прогнать на физической Windows |
| 4 | Из основной директории: `git merge --squash feature/windows-client` |
| 5 | Tag `v0.X.0`, GitHub Release (auto через release.yml) |
| 6 | Создать ADR `decisions/NNNN-windows-client-mvp.md` пост-фактум |

## Pitfalls

- **`register_font_from_memory` убрали в Slint 1.15** — публичного API нет
  на femtovg backend'е. Шрифты в `assets/fonts/` лежат для будущего embed
  через `@font-face` в .slint. Сейчас Slint падает на Segoe UI.
- **Cross-compile через mingw** работает для cargo check, но не для cargo
  build release — для итогового .exe нужен Windows host (CI или VM).
- **Anti-virus false positive** без code-signing certificate — Defender
  может ругаться. В MVP терпим, add-exception инструкция в README. EV /
  OV certificate ($200-500/год) в v2.
- **Phase 4.5 light** — кнопка Change profile открывает `%APPDATA%` через
  Explorer. Полный in-app editor (TextEdit + paste conn_string + валидация)
  отложен.
- **Tray icon state sync** — `tray::Tray::set_state()` определён но пока
  не вызывается из bridge. Подцепится в follow-up.

## Будущие пункты (не в MVP)

- Kill-switch через Windows Filtering Platform
- Windows Service + named pipe IPC между GUI и service (без UAC при каждом
  запуске)
- Autostart (Registry Run key)
- MSI installer через WiX
- Code-signing
- Auto-update (через сравнение GitHub Releases tag)
- Multi-server profiles UI
- Microsoft Store distribution
- ARM64 native build (сейчас только x64)
