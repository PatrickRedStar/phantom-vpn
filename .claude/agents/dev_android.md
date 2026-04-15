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

## Package
`com.ghoststream.vpn` (ребрендинг с `com.phantom.vpn` завершён).
JNI функции: `Java_com_ghoststream_vpn_service_GhostStreamVpnService_*`.

## JNI контракт (актуальный v0.19.4)
```kotlin
// GhostStreamVpnService.kt
external fun nativeStart(tunFd: Int, serverAddr: String, serverName: String,
                         insecure: Boolean, certPath: String, keyPath: String,
                         caCertPath: String): Int
// Error codes: 0=OK, -10=spawn failed (OOM/EAGAIN), остальные в VpnStateManager.nativeStartErrorMessage

@JvmStatic external fun nativeStop()
@JvmStatic external fun nativeGetStats(): String?        // JSON: bytes_rx/tx, pkts_rx/tx, connected
@JvmStatic external fun nativeGetLogs(sinceSeq: Long): String?  // JSON array, -1 = все
@JvmStatic external fun nativeSetLogLevel(level: String) // trace/debug/info
@JvmStatic external fun nativeComputeVpnRoutes(directCidrsPath: String): String?
```

## Строка подключения (v0.19+, формат `ghs://`)
```
ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1
```
- userinfo — base64url двух PEM-блоков подряд (cert chain + PKCS8 key)
- Парсер сплитит по маркерам `-----BEGIN`
- cert/key сохраняются в `filesDir/profiles/<uuid>/client.{crt,key}`
- Legacy base64-JSON **не поддерживается** (отвергается парсером)
- Поле `transport` удалено в v0.19.4 (QUIC мёртв)

## Способы ввода конфига
1. Ручной ввод base64url строки
2. Вставить из буфера
3. QR-код (CameraX + ML Kit barcode scanner)

## DNS серверы
Читается из DataStore (PreferencesStore), пресеты:
- Google (8.8.8.8/8.8.4.4)
- Cloudflare (1.1.1.1/1.0.0.1)
- AdGuard (94.140.14.14/94.140.15.15)
- Quad9 (9.9.9.9)

## Технический стек
- Kotlin + Jetpack Compose + Material 3
- Navigation Compose, ViewModel + StateFlow
- DataStore (Preferences) — для пользовательских настроек
- JSON-файл `files/profiles.json` (ProfilesStore) — список VpnProfile
- CameraX + ML Kit — для QR-сканера
- OkHttp — для admin API (с mTLS)
- compileSdk 34, minSdk 26, versionCode см. таблицу в CLAUDE.md

## Сборка Android (ВСЁ ЛОКАЛЬНО на vdsina)
```bash
# Rust .so (требует ANDROID_NDK_ROOT)
export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android
cp target/aarch64-linux-android/release/libphantom_android.so \
   android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so

# APK — собирается на машине пользователя (Android SDK не на vdsina)
# Через SSH тунель port 22222
cd android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon
# APK: android/app/build/outputs/apk/debug/app-debug.apk
```

## Релизный чеклист
- [ ] `build.gradle.kts`: `versionCode` инкрементирован, `versionName` обновлён, `GIT_TAG` обновлён
- [ ] `.so` пересобран через `cargo ndk` если менялся Rust-код
- [ ] Тег вида `v0.X.Y` → GitHub Actions сделает release автоматически

## Запрещено без архитектора
- Менять JNI сигнатуры без обновления Rust (и наоборот)
- Менять TUN MTU (должен быть 1350)
- Менять формат `ghs://` conn_string
- Ссылаться на QUIC / `runtimeTransport` / `transport=auto` — удалено в v0.19.4

## Крупные задачи
Если изменение затрагивает не только Android, но и сервер/core — сказать main agent'у
использовать параллельные субагенты одним `Agent` tool-call. Инлайн — только свою зону.
