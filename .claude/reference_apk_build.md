---
name: Android APK build pipeline
description: Где собирать .so, APK, и как устанавливать на телефон пользователя
type: reference
originSessionId: 86cd0a63-4677-4164-83d8-fdbac6637377
---
**.so сборка (на vdsina локально):**
```bash
ANDROID_NDK_HOME=/opt/android-ndk cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android
cp target/aarch64-linux-android/release/libphantom_android.so \
   android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
```

**Android SDK на vdsina НЕТ** — APK нельзя собрать локально. Нужно собирать на машине пользователя через SSH тунель:
```bash
ssh -i ~/.ssh/home_tunnel_key -p 22222 spongebob@127.0.0.1
# SDK: ~/Android/Sdk, JDK: /usr/bin/javac (системный)
```

**Workflow:**
1. Собрать .so на vdsina (cargo ndk)
2. Скопировать .so в `android/app/src/main/jniLibs/arm64-v8a/`
3. Rsync android/ на машину пользователя: `rsync -az --delete -e "ssh -i ~/.ssh/home_tunnel_key -p 22222" /opt/github_projects/phantom-vpn/android/ spongebob@127.0.0.1:~/phantom-vpn-build/android/`
4. Собрать APK там: `ssh ... "cd ~/phantom-vpn-build/android && ANDROID_HOME=~/Android/Sdk ./gradlew assembleDebug --no-daemon"`
5. Установить на телефоны (см. ниже)

**SSH тунель до машины пользователя:** `ssh -i ~/.ssh/home_tunnel_key -p 22222 spongebob@127.0.0.1`
**JDK на vdsina:** `/usr/lib/jvm/java-17-openjdk-amd64`
**NDK на vdsina:** `/opt/android-ndk`

**Телефоны пользователя (через adb на его машине):**
- `R5CR102X85M` — Samsung Galaxy S21 (SM_G991B), USB
- `192.168.1.8:38583` — Samsung Galaxy S25 Ultra (SM_S938B), WiFi
- `192.168.1.9:43333` — Samsung Galaxy Z Flip 6 (SM_F741B), WiFi

Проверить подключённые устройства: `ssh ... "adb devices -l"`
