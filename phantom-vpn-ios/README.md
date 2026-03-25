# GhostStream iOS

Нативный iOS-клиент на SwiftUI + Network Extension.

## Структура

- `PhantomVPN/` — основной iOS app target
- `PacketTunnel/` — `NEPacketTunnelProvider` extension
- `PhantomVPN.xcodeproj` — Xcode project с двумя targets

## Rust

Сначала собрать Rust staticlib:

```bash
bash ../scripts/build-ios-rust.sh
```

Ожидаемые артефакты:

- `target/aarch64-apple-ios/release/libphantom_ios.a`
- `target/aarch64-apple-ios-sim/release/libphantom_ios.a`

## Xcode

1. Открыть `PhantomVPN.xcodeproj`
2. Заполнить `DEVELOPMENT_TEAM`
3. Проверить App Group `group.com.ghoststream.vpn`
4. Убедиться, что Network Extension entitlement включен
5. Схема `PhantomVPN` -> Build/Archive
