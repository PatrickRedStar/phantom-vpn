---
updated: 2026-04-17
---

# Platforms — Index

Пер-платформные страницы: что в стеке, где код, какие pitfalls специфичны
платформе, релизный процесс.

| Страница | Покрывает | Крейт + приложение |
|---|---|---|
| [server.md](server.md) | phantom-server (NL exit) + phantom-relay (RU SNI passthrough) + nginx frontend, файловая раскладка `/opt/phantom-vpn/`, systemd, NAT/iptables, admin API reference | `server/server/`, `server/relay/` |
| [android.md](android.md) | Compose UI + JNI + `VpnService` + watchdog FSM, JNI methods, theme palette, debug share, release process с таблицей versionCode | `crates/client-android/` + `apps/android/` |
| [ios.md](ios.md) | SwiftUI host + `NEPacketTunnelProvider` + PhantomKit Swift package + Apple FFI, App Group shared storage, IPv6 killswitch | `crates/client-apple/` + `apps/ios/` |
| [linux.md](linux.md) | Три независимых приложения — CLI + GUI (Slint) + privileged helper, io_uring TUN с fallback на blocking, gui-ipc wire protocol | `apps/linux/cli/`, `apps/linux/gui/`, `apps/linux/helper/` |
| [openwrt.md](openwrt.md) | phantom-client-openwrt + netifd proto (`ghoststream.sh`) + LuCI, CI cross-compile для MIPS/arm/arm64/x86_64, MIPS build специфика | `apps/openwrt/` |

Общие runtime-штуки (`TunIo` enum, supervise FSM, `StatusFrame` EMA) — в
[../glossary.md](../glossary.md) (раздел "Client runtime"). Unified tunnel
runtime для всех клиентов — ADR [0005](../decisions/0005-client-core-runtime.md).
