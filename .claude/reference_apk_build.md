---
name: Android APK build pipeline
description: Где собирать .so, APK, и как устанавливать на телефон пользователя
type: reference
originSessionId: 86cd0a63-4677-4164-83d8-fdbac6637377
---
**.so сборка:** отдельно не нужна — её делает gradle (`preBuild` → `buildRustAndroid`,
`cargo ndk -t arm64-v8a -t armeabi-v7a ... -o app/src/main/jniLibs`); в git `.so` нет.
Основной путь сборки и установки — `tools/ship-android.sh` на Unix-хосте с NDK
(rustup-таргеты `aarch64-linux-android`, `armv7-linux-androideabi`). Ниже — старый
путь через vdsina, актуален только как запасной.

**Android SDK на vdsina НЕТ** — APK нельзя собрать локально. Нужно собирать на машине пользователя через SSH тунель:
```bash
ssh -i ~/.ssh/home_tunnel_key -p 22222 spongebob@127.0.0.1
# SDK: ~/Android/Sdk, JDK: /usr/bin/javac (системный)
```

**Workflow:**
1. Rsync репо (gradle-сборке нужен весь cargo workspace, не только `apps/android/`) на машину с SDK и NDK
2. Собрать APK там: `cd apps/android && ./gradlew assembleDebug --no-daemon` — `.so` соберётся сам
3. Установить на телефоны (см. ниже)

**SSH тунель до машины пользователя:** `ssh -i ~/.ssh/home_tunnel_key -p 22222 spongebob@127.0.0.1`
**JDK на vdsina:** `/usr/lib/jvm/java-17-openjdk-amd64`
**NDK на vdsina:** `/opt/android-ndk`

**Телефоны пользователя (через adb на его машине):**
- `R5CR102X85M` — Samsung Galaxy S21 (SM_G991B), USB
- `192.168.1.8:38583` — Samsung Galaxy S25 Ultra (SM_S938B), WiFi
- `192.168.1.9:43333` — Samsung Galaxy Z Flip 6 (SM_F741B), WiFi

Проверить подключённые устройства: `ssh ... "adb devices -l"`
