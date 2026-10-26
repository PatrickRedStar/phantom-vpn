---
name: Android APK build pipeline
description: Где собирать .so, APK, и как устанавливать на телефон пользователя
type: reference
originSessionId: 86cd0a63-4677-4164-83d8-fdbac6637377
---
Сборка и установка — только `tools/ship-android.sh` на Unix-хосте (macOS/Linux).
`.so` отдельно не собирается: gradle `preBuild` → `buildRustAndroid`
(`cargo ndk -t arm64-v8a -t armeabi-v7a … -o app/src/main/jniLibs`), в git его нет.
Нужны Android SDK + NDK, `cargo-ndk` и rustup-таргеты `aarch64-linux-android`,
`armv7-linux-androideabi`.

**Телефоны пользователя (adb):**
- `R5CR102X85M` — Samsung Galaxy S21 (SM_G991B), USB
- `192.168.1.8:38583` — Samsung Galaxy S25 Ultra (SM_S938B), WiFi
- `192.168.1.9:43333` — Samsung Galaxy Z Flip 6 (SM_F741B), WiFi

Проверить подключённые устройства: `adb devices -l`
