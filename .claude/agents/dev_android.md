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

## Package (ВАЖНО: после ребрендинга)
Текущий: `com.phantom.vpn`
Целевой: `com.ghoststream.vpn`
При переименовании — JNI функции меняют имя:
`Java_com_phantom_vpn_*` → `Java_com_ghoststream_vpn_*`

## JNI контракт (текущий)
```kotlin
// PhantomVpnService / GhostStreamVpnService
external fun nativeStart(tunFd: Int, serverAddr: String, serverName: String,
                         insecure: Boolean, certPath: String, keyPath: String): Int
@JvmStatic external fun nativeStop()
// TODO: добавить:
@JvmStatic external fun nativeGetStats(): String   // JSON статистики
@JvmStatic external fun nativeGetLogs(): String    // JSON array логов
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
Сейчас захардкожены в PhantomVpnService.kt:
```kotlin
.addDnsServer("8.8.8.8")
.addDnsServer("1.1.1.1")
```
Нужно: читать из DataStore, передавать через Intent extras.
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
- `vpnInterface?.close()` после `detachFd()` — fd уже передан в Rust, close вызывается на невалидном PFD
- Статус UI не обновляется из Service (нет BroadcastReceiver / StateFlow)
- Нет обработки ошибок из nativeStart (только return code, нет сообщения)
- DNS серверы захардкожены
- Нет таймера сессии
- Нет статистики трафика
- `foregroundServiceType` в манифесте: нужен `<meta-data android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE">`

## Запрещено без архитектора
- Менять JNI сигнатуры без обновления Rust
- Менять TUN MTU (должен быть 1350)
- Менять DNS конфиг в Builder без сохранения в DataStore
