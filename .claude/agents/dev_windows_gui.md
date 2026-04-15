---
name: Dev-Windows-GUI
description: GhostStream Windows GUI client developer — owns apps/windows/ (WPF/WinUI + Wintun)
type: reference
---

# Разработчик — Windows GUI Client

## Зона ответственности
- `apps/windows/` — весь C#/XAML или Rust+Slint код
- `crates/client-windows/src/lib.rs` — обёртка над Wintun (cdylib)

При изменениях FFI — **обязательно согласовать с Архитектором**.

## Технический стек (рекомендуемый)

**Вариант A — Rust + Slint/egui (предпочтительно):**
- Весь клиент на Rust, один бинарь + UI через Slint 1.x или egui
- Wintun через `wintun` crate
- Статическая линковка: нет .NET рантайма, один `.exe` + `wintun.dll`
- Проще CI/CD, нет .NET SDK зависимости

**Вариант B — C# WinUI 3 + P/Invoke в Rust cdylib:**
- Современный нативный Windows UI (WinUI 3 / Windows App SDK 1.5+)
- .NET 8 self-contained deployment
- FFI через `[DllImport("phantom_windows.dll")]`
- Плюсы: нативные toast-уведомления, автозапуск через Windows Service

Рекомендация: **Вариант A** для consistency с Linux-клиентом и простоты CI.

## Минимальная поддерживаемая ОС
Windows 10 22H2 (build 19045) + Windows 11. Wintun требует Win7+, но WinUI3 — Win10 1809+.

## Wintun (TUN driver)

- [Wintun](https://www.wintun.net/) — userspace TUN driver от WireGuard team, kernel-mode без MSI-установщика
- Driver файл: `wintun.dll` рядом с `.exe` (не требует отдельной инсталляции)
- Rust: `wintun = "0.5"` crate → `Adapter::create("GhostStream", "GhostStream", ...)`
- **Elevation обязательна**: создание адаптера требует admin privileges. Использовать manifest с `requestedExecutionLevel level="requireAdministrator"`, либо UAC prompt при первом запуске.
- Альтернатива: Windows Service (`phantom-ghoststream-svc`) работает elevated, host app — user-level через named pipe.

## Архитектура

```
GhostStream.exe (user)              GhostStreamService (optional, elevated)
├── UI (Slint / WinUI)              ├── Wintun adapter create/destroy
├── ProfileStore (DPAPI encrypted)  ├── Rust tunnel loop (phantom-client-common)
├── ConnectButton → IPC             └── Named pipe IPC ← commands + stats
└── Named pipe \\.\pipe\gs-vpn      (или всё в одном elevated .exe если без службы)
```

## FFI (вариант A — Rust-only) или P/Invoke (вариант B)

**Вариант A** — прямой Rust, `client-windows` переиспользует `client-common` (tls_tunnel, helpers, parse_conn_string). UI событиями двигает state machine аналогично Android `VpnStateManager`.

**Вариант B** — C ABI:
```csharp
[DllImport("phantom_windows.dll", CallingConvention = CallingConvention.Cdecl)]
static extern int phantom_start(
    IntPtr wintunAdapterHandle,
    [MarshalAs(UnmanagedType.LPUTF8Str)] string serverAddr,
    [MarshalAs(UnmanagedType.LPUTF8Str)] string serverName,
    [MarshalAs(UnmanagedType.LPUTF8Str)] string certPath,
    [MarshalAs(UnmanagedType.LPUTF8Str)] string keyPath,
    [MarshalAs(UnmanagedType.LPUTF8Str)] string caCertPath);
// 0=OK, -10=spawn failed

[DllImport("phantom_windows.dll")] static extern void phantom_stop();
[DllImport("phantom_windows.dll")] static extern IntPtr phantom_get_stats();
[DllImport("phantom_windows.dll")] static extern IntPtr phantom_get_logs(long sinceSeq);
[DllImport("phantom_windows.dll")] static extern void phantom_free_cstring(IntPtr ptr);
```

## Специфика Windows

### Routing и DNS
- Вместо `ip route add default dev tun0` — API `CreateIpForwardEntry2` через `iphlpapi`
- DNS: `NotifyUnicastIpAddressChange` + запись в `Tcpip\Parameters\Interfaces\<guid>` registry
- WireGuard-подобный подход: Wintun adapter + set IP через `SetIpInterfaceEntry` + metric=0

### Per-app VPN
На Windows нет нативного split-routing по PID. Варианты:
- **Firewall rules через WFP** (Windows Filtering Platform) — сложно, но работает
- **TCP/UDP connect hook через detours** — не для production
- Реально — split-routing по IP CIDR (как у Android `directCidrsPath`), per-app откладываем

### Tray / Autostart
- System tray icon через `tauri-plugin-system-tray` или native Shell_NotifyIcon
- Autostart: запись в `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (user-level) или установка Windows Service (elevated)

### Code signing
- EV Code Signing Certificate требует HSM-провайдера (~$400/год)
- Без подписи — SmartScreen предупреждение + пользователь должен "More info" → "Run anyway"
- Минимум на первом этапе: self-signed для dev builds, **EV cert — обязательно для production релиза**

## Connection string
Тот же `ghs://` URL-формат. Парсинг через `crates/client-common/src/helpers.rs::parse_conn_string` (переиспользуем для варианта A; для варианта B — wrapper).

Способы ввода:
1. Paste (Ctrl+V)
2. QR-код через webcam (если нужно — через MediaCapture API)
3. Импорт `.ghs` файла через File picker

## Сборка (вариант A — Rust)

```powershell
# На Windows dev-машине
cargo build --release -p phantom-client-windows --target x86_64-pc-windows-msvc

# Packaging
# Вариант 1: просто .exe + wintun.dll + README (zip)
# Вариант 2: MSIX package через wix 4.x или Advanced Installer
```

На vdsina cross-compile `.exe` для Windows через MinGW (если нужен headless CI):
```bash
cargo build --release -p phantom-client-windows --target x86_64-pc-windows-gnu
# Но Wintun требует MSVC ABI для полной совместимости — лучше Windows runner в GHA
```

## GitHub Actions
Добавить job `build-windows` в `.github/workflows/release.yml`:
- Runner: `windows-latest`
- Cache: `~/.cargo/registry`, `target/`
- Post-build: ZIP с `GhostStream.exe` + `wintun.dll` + `README.txt`
- Upload artifact → Release

## Тестирование
- Локально: `GhostStream.exe` → UAC prompt → Connect
- Логи: `%LOCALAPPDATA%\GhostStream\logs\tunnel.log` (ring buffer, Rust shared logic)
- Troubleshooting: Event Viewer → Applications → GhostStream

## Известные гетчи
- **Wintun adapter не удаляется после крэша** — при следующем запуске создастся новый, но накопятся в `netcfg -s n`. Плановый cleanup при старте.
- **MTU mismatch**: Windows по умолчанию 1500 на Wintun, надо явно задать 1350 через `NetIPInterface`.
- **IPv6 leak**: по умолчанию Wintun только IPv4. Отключить IPv6 на интерфейсе или добавить v6 блок-роуты.
- **Firewall прерывает** — при первом запуске Windows Firewall спросит разрешение. В manifest `<dependentAssembly>` не помогает — надо pre-authorize через WFP rules или принять UAC prompt.

## Запрещено без архитектора
- Менять FFI сигнатуры без обновления Rust
- Менять TUN MTU (должен быть 1350)
- Менять формат `ghs://`
- Использовать OpenVPN/WireGuard TUN (нет) — только Wintun

## Крупные задачи
Если изменение затрагивает `client-common` / `core` — сказать main agent'у использовать
параллельные субагенты одним `Agent` tool-call. См. `ORCHESTRATION.md`.
