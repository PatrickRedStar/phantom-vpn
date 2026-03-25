---
name: Dev-Android
description: GhostStream Android developer — owns android/ and crates/client-android/
type: reference
---

# Разработчик — Android

## Зона ответственности
- `android/` — весь Kotlin/Compose UI
- `crates/client-android/src/lib.rs` — JNI мост

При изменениях JNI — **обязательно согласовать с Архитектором**.

## Package (актуально)
Текущий package: `com.ghoststream.vpn`.
JNI-имена должны соответствовать package:
`Java_com_ghoststream_vpn_*`.

## JNI контракт (текущий)
```kotlin
// GhostStreamVpnService
external fun nativeStart(tunFd: Int, serverAddr: String, serverName: String,
                         insecure: Boolean, certPath: String, keyPath: String, caCertPath: String): Int
@JvmStatic external fun nativeStop()
@JvmStatic external fun nativeGetStats(): String?  // JSON статистики
@JvmStatic external fun nativeGetLogs(sinceSeq: Long): String? // JSON array логов
@JvmStatic external fun nativeSetLogLevel(level: String)
@JvmStatic external fun nativeComputeVpnRoutes(directCidrsPath: String): String?
```

## Строка подключения (формат)
base64url JSON без паддинга:
```json
{"v":1,"addr":"ip:port","sni":"domain","tun":"10.7.0.x/24","cert":"PEM...","key":"PEM..."}
```
- `eyJ` в начале = это base64url JSON
- cert/key сохранять в `filesDir/client.crt` и `filesDir/client.key`

## Способы ввода конфига
1. Ручной ввод base64url строки
2. Вставить из буфера
3. QR-код (CameraX + ML Kit barcode scanner)

## DNS серверы
DNS передаются из DataStore через Intent extras в `GhostStreamVpnService`.
Для UI использовать пресеты:
Пресеты: Google (8.8.8.8/8.8.4.4), Cloudflare (1.1.1.1/1.0.0.1),
         AdGuard (94.140.14.14/94.140.15.15), Quad9 (9.9.9.9)

## Технический стек
- Kotlin + Jetpack Compose + Material 3
- DataStore (Preferences) — вместо SharedPreferences
- CameraX + ML Kit — для QR-сканера
- ViewModel + StateFlow
- compileSdk 34, minSdk 26

## Сборка Android (ВСЁ ЛОКАЛЬНО)
```bash
source ~/.cargo/env
# Rust .so
cargo build --release -p phantom-client-android --target aarch64-linux-android
cp target/aarch64-linux-android/release/libphantom_android.so \
   android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
# APK
cd android && ./gradlew assembleDebug
# Установить на телефон
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Известные баги в текущем коде
- В режиме per-app `allowed` при пустом списке приложений нужен явный fail-fast в UI/Service
- Для split-routing нужен явный UX при пустых/нескачанных правилах
- Тяжёлые операции (import/share/log parse) должны быть в `Dispatchers.IO`

## Запрещено без архитектора
- Менять JNI сигнатуры без обновления Rust
- Менять TUN MTU (должен быть 1350)
- Менять DNS конфиг в Builder без сохранения в DataStore
