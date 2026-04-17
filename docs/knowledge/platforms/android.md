---
updated: 2026-04-17
---

# Android

## Стек

- **Kotlin + Jetpack Compose** (Material3, Navigation Compose)
- **ViewModel + StateFlow** — реактивный UI
- **JNI** → `libphantom_android.so` (из `crates/client-android/`)
- **Android VPN Service** → `GhostStreamVpnService`
- **DataStore** (`PreferencesStore`) + JSON-файл (`ProfilesStore`)
- **CameraX + ML Kit** — сканер QR для conn_string
- **OkHttp** — mTLS HTTP-клиент для admin API

Единый tunnel runtime (с v0.22) идёт через `crates/client-core-runtime/`,
`TunIo::BlockingThreads(RawFd)` на Android.

## Структура `apps/android/app/src/main/kotlin/com/ghoststream/vpn/`

```
MainActivity.kt
navigation/        AppNavigation.kt
data/              ProfilesStore, PreferencesStore, VpnProfile,
                   ConnStringParser, AdminHttpClient, RoutingRulesManager,
                   PairingClient, PairingServer
service/           GhostStreamVpnService, VpnStateManager, BootReceiver
ui/
  dashboard/       DashboardScreen + DashboardViewModel
  logs/            LogsScreen + LogsViewModel
  settings/        SettingsScreen + SettingsViewModel
  admin/           AdminScreen + AdminViewModel
  pairing/         TV pairing via QR
  components/      общие Compose-блоки
  theme/           Color.kt, Theme.kt
util/
```

## Экраны

| Экран | Что показывает |
|---|---|
| **Dashboard** | Подключение, таймер, статистика (bytes_rx/tx, pkts), статус подписки |
| **Logs** | Rust лог-буфер, фильтр по уровням TRACE/DEBUG/INFO/WARN/ERROR |
| **Settings** | Профили + ping, DNS, split-routing, per-app VPN, тема, debug share |
| **Admin** | Управление сервером (клиенты, подписки, трафик) — требует `is_admin` |
| **QrScanner** | Сканирование QR-кода conn_string (`ghs://...`) |
| **Pairing** | TV pairing (QR display + scan) |

## Слой данных

| Класс | Хранилище | Описание |
|---|---|---|
| `ProfilesStore` | `files/profiles.json` | Синглтон. Список `VpnProfile`, `activeId` |
| `PreferencesStore` | DataStore | DNS, routing mode, per-app allow/deny list, тема |
| `VpnProfile` | POJO | `id, name, serverAddr, serverName, insecure, certPath, keyPath, caCertPath, tunAddr, adminUrl, adminToken, cachedAdminServerCertFp` |
| `ConnStringParser` | — | `ghs://...` → `VpnProfile` поля (parse через FFI или Kotlin) |
| `AdminHttpClient` | — | mTLS + TOFU pinning (`cachedAdminServerCertFp`) |
| `RoutingRulesManager` | — | split-routing CIDR list, direct vs tunnel |

## JNI методы

Объявлены в `service/GhostStreamVpnService.kt`:

| Метод | Сигнатура |
|---|---|
| `nativeStart` | `(tunFd: Int, cfgJson: String, settingsJson: String, listener: PhantomListener): Int` — 0 = OK |
| `nativeStop` | `(): Unit` |
| `nativeGetStats` | `(): String?` — JSON `{bytes_rx,bytes_tx,pkts_rx,pkts_tx,connected}` (stub после v0.22, данные приходят push'ем) |
| `nativeGetLogs` | `(sinceSeq: Long): String?` — JSON-массив записей с `seq > sinceSeq`; `-1` = все |
| `nativeSetLogLevel` | `(level: String): Unit` — "trace"/"debug"/"info" |
| `nativeComputeVpnRoutes` | `(directCidrsPath: String): String?` — инвертированные CIDR для split-routing |

`cfgJson` — сериализованный `ConnectProfile` (shape canonical в
`crates/gui-ipc/`). `settingsJson` — `TunnelSettings` (DNS, routing mode,
direct CIDRs, per-app).

Push-based listener (v0.20+):

```kotlin
interface PhantomListener {
    fun onStatusFrame(json: String)   // StatusFrame
    fun onLogFrame(json: String)      // LogFrame
}
```

Rust вызывает callback'и из runtime'а напрямую — поллинг `nativeGetStats()`/`nativeGetLogs()` заменён pushем.
Точные сигнатуры смотреть через gitnexus или в
[GhostStreamVpnService.kt](../../../apps/android/app/src/main/kotlin/com/ghoststream/vpn/service/GhostStreamVpnService.kt).

## VPN State Machine (`VpnStateManager.kt`)

```
Disconnected → Connecting → Connected
                    ↑            ↓ (tunnel drop)
                    └── Connecting (watchdog reconnect)
              ↓ (timeout/error)
             Error → Disconnected
```

- **Watchdog** — поллинг `nativeGetStats()` раз в секунду, проверяет что туннель
  жив; при `connected=false` → Reconnect.
- **Reconnect backoff** — exponential: `3s → 6s → 12s → 24s → 48s → 60s → 60s → 60s`,
  8 попыток. После — `Error`.
- Runtime FSM идентичная на всех платформах живёт в `client-core-runtime` (см.
  [ADR 0005](../decisions/0005-client-core-runtime.md)). Android остался с watchdog'ом
  на Kotlin-стороне как дополнительный страховочный слой к runtime'овскому supervise.

## Лог-система

- **Rust ring-buffer** — 10 MB в runtime, записи с монотонным `seq`.
- **Push-based** (v0.22+): `PhantomListener.onLogFrame(json)` — вызывается из Rust, в UI приходит напрямую.
- **Legacy поллинг**: `LogsViewModel` опрашивает `nativeGetLogs(sinceSeq)` каждые 500ms,
  хранит до 50 000 записей в `allLogs: MutableList<LogEntry>`.
- **Иерархия уровней** (фильтр): `ALL > TRACE > DEBUG > INFO (default) > WARN > ERROR`.
  `applyFilter("INFO")` показывает INFO+WARN+ERROR.
- **`nativeSetLogLevel`** принимает `trace`/`debug`/`info` (warn/error → info на Rust-стороне).
- **Цвета**:
  - `ERROR` → `RedError` (`0xFFFF4A3D` в тёмной теме)
  - `WARN`  → `YellowWarning` (`0xFFFF7A3D`)
  - `DEBUG` → `BlueDebug` (`0xFF6C8BA8`)
  - прочее → `TextSecondary`

## Профили и подписки

- `DashboardViewModel.fetchSubscriptionInfo()` — при подключении запрашивает
  `GET /api/clients` через `adminUrl`/`adminToken`, находит себя по `tun_addr`,
  показывает оставшееся время подписки.
- `SettingsViewModel.fetchAllSubscriptions()` — в `init` обновляет
  `profileSubscriptions` для всех профилей, у которых прописан `adminUrl`.
- **Ping** — `SettingsViewModel.measureTcpLatency()` через `Socket.connect()` с
  таймаутом 3 сек (TCP handshake RTT, а не ICMP).

## Debug Share (`SettingsViewModel.shareDebugReport`)

FileProvider пишет `cache/debug/ghoststream-debug.txt` → intent `ACTION_SEND`.
Отчёт содержит:
- Версия приложения + `BuildConfig.GIT_TAG`
- Android OS + модель устройства
- Активный профиль (без ключей / сертов)
- Текущее VPN state
- Конфиг (DNS, routing mode, per-app)
- Последние 500 строк Rust-логов

## Theme (палитра)

`apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/theme/Color.kt`:

```kotlin
// Dark "phosphor-lime"
GsBg       = 0xFF0A0908   // warm near-black
GsBone     = 0xFFE8E2D0   // primary text
GsSignal   = 0xFFC4FF3E   // phosphor lime (== GreenConnected)
GsWarn     = 0xFFFF7A3D   // cathode orange (== YellowWarning)
GsDanger   = 0xFFFF4A3D   // (== RedError)
BlueDebug  = 0xFF6C8BA8   // DEBUG log rows

// Light "Daylight" — paper + ink + moss-green
GsLightBg     = 0xFFF1ECDC
GsLightInk    = 0xFF16130C
GsLightSignal = 0xFF4A6010
GsLightWarn   = 0xFFD4600A
GsLightDanger = 0xFFCC3322
```

Семантические алиасы `GreenConnected`/`RedError`/`YellowWarning`/`BlueDebug`
экспортируются и используются в UI-коде.

## Архитектурные особенности

- **`TunIo::BlockingThreads`** — Android не даёт io_uring, используем два
  thread'а: один на `read(tun_fd)`, один на `write`. Pure blocking I/O, Tokio не
  помогает — tun на Android не селектится portable'ным способом.
- **`VpnService.protect(socket)`** — все outbound сокеты (TLS к NL/RU) **обязательно**
  защищаются, иначе будет routing loop (сокет пойдёт внутрь туннеля).
- **Push-based listener** (v0.20+) — JNI больше не поллится. `PhantomListener`
  получает `onStatusFrame(json)` / `onLogFrame(json)` прямо из Rust runtime'а.
- **Foreground service** — VPN всегда foreground-service (`FOREGROUND_SERVICE_TYPE_SPECIAL_USE`),
  иначе OS убьёт при doze / memory pressure. Нотификация обязательна.
- **Pre-resolve DNS server hostname** (v0.19.3) — через underlying network, до
  создания TUN'а; иначе имя сервера не резолвится после активации туннеля.

## Критичные pitfalls

- **`adminUrl`/`adminToken`** сериализуются в `ProfilesStore` — был баг в v0.8.7,
  сейчас оба поля сохраняются.
- **`adb uninstall` перед install** — нужен при смене подписи или очистке данных.
- **`versionCode`** инкрементить **ПЕРЕД** тегом в `build.gradle.kts` (монотонно).
- **Split routing (per-app VPN)** — только Android 5.0+, через
  `VpnService.Builder.addDisallowedApplication()`.
- **`MAX_SPLIT_ROUTES = 8000`** — больше маршрутов переполняет Binder-транзакцию в
  `VpnService.Builder.establish()` → `TransactionTooLargeException`.
- **Fd TUN'а закрывать ДО `nativeStop`** — иначе native-код висит на `read(fd)` и
  `nativeStop` не возвращается (watchdog ждёт до 3 сек, потом логирует и
  проходит дальше).
- **`cachedAdminServerCertFp` (TOFU)** — при смене admin-server.crt на сервере
  клиент откажется соединяться; чистить руками или regenerate conn_string.

## Релизный процесс

Перед тегом обновить в [apps/android/app/build.gradle.kts](../../../apps/android/app/build.gradle.kts):

```kotlin
versionCode = <N+1>                       // монотонный инкремент
versionName = "X.Y.Z"                     // семвер
buildConfigField("String", "GIT_TAG", "\"vX.Y.Z\"")
```

Сборка APK (локально — JDK17 обязателен):

```bash
cd apps/android
JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon
# APK: apps/android/app/build/outputs/apk/debug/app-debug.apk
```

Native `.so` перед APK-сборкой (если правили Rust):

```bash
export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android
cp target/aarch64-linux-android/release/libphantom_android.so \
   apps/android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
```

Install на устройство:

```bash
adb uninstall com.ghoststream.vpn 2>/dev/null
adb install apps/android/app/build/outputs/apk/debug/app-debug.apk
```

Коммит + тег + пуш:

```bash
git add apps/android/app/build.gradle.kts CHANGELOG.md docs/knowledge/history/timeline.md
git commit -m "feat(android): vX.Y.Z ..."
git tag vX.Y.Z
git push origin master && git push origin vX.Y.Z
```

GitHub Actions (`.github/workflows/release.yml`) автоматически соберёт Release
при пуше тега `v*`.

### Таблица versionCode ↔ tag

| Tag | versionCode |
|---|---|
| v0.8.5 | 11 |
| v0.8.6 | 12 |
| v0.8.7 | 13 |
| v0.8.8 | 14 |
| v0.8.9 | 15 |
| v0.9.0 | 16 |
| v0.10.0 | 17 |
| v0.18.5 | 48 |
| v0.19.0 | 49 |
| v0.19.1 | 50 |
| v0.19.2 | 51 |
| v0.19.3 | 52 |
| v0.19.4 | 53 |
| v0.20.0 | 54 |
| v0.21.0 | 55 |
| **v0.22.0** | **56** ← текущий |

Монотонность versionCode критична: Google Play и `adb install` откажутся ставить
APK с versionCode ≤ уже установленному.

## Sources

- **Android app:** [apps/android/app/src/main/kotlin/com/ghoststream/vpn/](../../../apps/android/app/src/main/kotlin/com/ghoststream/vpn/)
- **Build config:** [apps/android/app/build.gradle.kts](../../../apps/android/app/build.gradle.kts)
- **JNI crate:** [crates/client-android/](../../../crates/client-android/)
- **Runtime (shared):** [crates/client-core-runtime/](../../../crates/client-core-runtime/)
- **ConnectProfile / StatusFrame / LogFrame канонические типы:** [crates/gui-ipc/](../../../crates/gui-ipc/)
- **Release CI:** [.github/workflows/release.yml](../../../.github/workflows/release.yml)
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md)
- **gitnexus:** `gitnexus_query({query: "android jni native start"})`, `gitnexus_impact({target: "nativeStart", direction: "upstream"})`
- **Build + deploy общее:** [../build.md](../build.md)
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
