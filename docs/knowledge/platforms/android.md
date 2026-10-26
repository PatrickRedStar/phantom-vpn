---
updated: 2026-10-27
---

# Android

## Стек

- **Kotlin + Jetpack Compose** (Material3, Navigation Compose)
- **ViewModel + StateFlow** — реактивный UI
- **JNI** → `libphantom_android.so` (из `crates/client-android/`)
- **Android VPN Service** → `GhostStreamVpnService`
- **DataStore** (`PreferencesStore`) + JSON-файл (`ProfilesStore`)
- **CameraX + ML Kit** — сканер QR для conn_string (телеметрия ML Kit в Google
  отрезана: снят `TransportBackendDiscovery`)
- **OkHttp** — mTLS HTTP-клиент для admin API
- **Glance** — 5 виджетов рабочего стола + плитка Quick Settings (`VpnTileService`)

Единый tunnel runtime (с v0.22) идёт через `crates/client-core-runtime/`,
`TunIo::BlockingThreads(RawFd)` на Android. Ядро собирается под `arm64-v8a` и
`armeabi-v7a` (32-битные ТВ-приставки).

## Структура `apps/android/app/src/main/kotlin/com/ghoststream/vpn/`

```
MainActivity.kt
navigation/        AppNavigation.kt
data/              ProfilesStore, PreferencesStore, VpnProfile, VpnConfig,
                   ConnStringParser, AdminHttpClient, RoutingRulesManager
service/           GhostStreamVpnService, VpnStateManager, BootReceiver,
                   DnsHealthMonitor, LogPersister
widget/            5 Glance-виджетов, VpnTileService, WidgetActions, WidgetState
ui/
  dashboard/       DashboardScreen + DashboardViewModel
  logs/            LogsScreen + LogsViewModel
  settings/        SettingsScreen + SettingsViewModel
  admin/           AdminScreen + AdminViewModel
  components/      общие Compose-блоки (в т.ч. QrScannerScreen)
  theme/           Color.kt, Theme.kt
util/
```

## Экраны

| Экран | Что показывает |
|---|---|
| **Dashboard** | Подключение, таймер, статистика, срок подписки (из `/api/me`), «живы k из n стримов» при деградации, причина фатальной ошибки |
| **Logs** | Rust лог-буфер, фильтр по уровням TRACE/DEBUG/INFO/WARN/ERROR |
| **Settings** | Профили + ping, DNS, split-routing, per-app VPN, «Автозапуск при загрузке», переход в системный «Постоянный VPN», тема, debug share |
| **Admin** | Управление сервером (клиенты, подписки, трафик) — требует `is_admin` |
| **QrScanner** | Сканирование QR-кода conn_string — принимает только `ghs://` |

Передача профиля на TV (Pairing) удалена в v0.29.0 — [ADR 0019](../decisions/0019-owner-decisions-audit-2026-10.md).
Вне приложения: плитка в шторке быстрых настроек и виджеты — общий путь
`WidgetActions.toggleVpn`; тап во время подключения/переподключения отменяет его.

## Слой данных

| Класс | Хранилище | Описание |
|---|---|---|
| `ProfilesStore` | `files/profiles.json` + `files/profiles/<id>/client.{crt,key}` | Синглтон. Список `VpnProfile`, `activeId`. Приватный ключ — в одной копии, в файле профиля |
| `PreferencesStore` | DataStore | DNS, routing mode, per-app allow/deny list, тема, автозапуск |
| `VpnProfile` | data class | `id, name, serverAddr, serverName, certPath, keyPath, tunAddr`, per-profile DNS/split/per-app, `relayEnabled, relayAddr`, кэш из `/api/me`: `cachedExpiresAt, cachedEnabled, cachedIsAdmin`, TOFU-пин `cachedAdminServerCertFp` |
| `ConnStringParser` | — | `ghs://...` → поля `VpnProfile`; `java.util.Base64`, padding необязателен — как в Rust, тесты на общих векторах |
| `AdminHttpClient` | — | mTLS + TOFU pinning (`cachedAdminServerCertFp`) |
| `RoutingRulesManager` | — | split-routing CIDR list, direct vs tunnel |

## JNI методы

Объявлены в `service/GhostStreamVpnService.kt`:

| Метод | Сигнатура |
|---|---|
| `nativeStart` | `(tunFd: Int, cfgJson: String, listener: PhantomListener): Int` — 0 = OK, -1 = кривой конфиг, -2 = адрес сервера не IP, -10 = не запустился |
| `nativeStop` | `(): Unit` |
| `nativeSetLogLevel` | `(level: String): Unit` — "trace"/"debug"/"info" |
| `nativeComputeVpnRoutes` | `(directCidrsPath: String): String?` — инвертированные CIDR для split-routing |

`cfgJson` — сериализованный `ConnectProfile` (shape canonical в
`crates/gui-ipc/`), `TunnelSettings` едут внутри него. Адрес сервера Kotlin
резолвит сам (через физическую сеть, см. ниже) и передаёт IP — имя в Rust не
уходит. `nativeGetStats`/`nativeGetLogs` и отдельный `settingsJson` удалены.

Push-based listener (v0.20+):

```kotlin
interface PhantomListener {
    fun onStatusFrame(json: String)   // StatusFrame
    fun onLogFrame(json: String)      // LogFrame
}
```

Rust вызывает callback'и из runtime'а напрямую, на daemon-потоках JVM; каждая
строка — в своём local frame, Java-исключения сбрасываются (иначе local refs
копились до OOM).
Точные сигнатуры смотреть через gitnexus или в
[GhostStreamVpnService.kt](../../../apps/android/app/src/main/kotlin/com/ghoststream/vpn/service/GhostStreamVpnService.kt).

## VPN State Machine (`VpnStateManager.kt`)

```
Disconnected → Connecting → Connected ⇄ Stale / Throttled
                                ↓ (обрыв — переподключает Rust)
                           Reconnecting → Connected
                                ↓ (фатальная причина от ядра)
                              Error → Disconnected
```

**Переподключением владеет Rust** ([ADR 0018](../decisions/0018-rust-owns-reconnect.md)).
Kotlin-сторожа больше нет: сервис реагирует только на `state=error` ядра и на
действия пользователя.

- **Error** — только фатальные причины ядра («Доступ отозван», «Срок действия
  доступа истёк», «проверьте дату и время на устройстве», кривой профиль). Текст
  на дашборде и в уведомлении, туннель снимается.
- **Kill switch.** При потере связи TUN не снимается — трафик блокируется, ядро
  ретраит бесконечно. Через 25 с без связи уведомление «Нет связи» с кнопкой
  «Отключить»; heads-up — один раз, если туннель до этого был поднят. TUN
  снимается только по Disconnect, onRevoke или фатальной ошибке.
- **Throttled** — только при `bandwidth_class = throttled`; умершие стримы без
  троттлинга оставляют Connected с «живы k из n».
- **Адрес сервера** резолвится через физическую сеть из колбэка (VALIDATED, а
  если такой нет — любая, кроме captive portal), с кешем последнего удачного IP.
  Когда сеть получает VALIDATED (и через 25 с без связи), адрес перерезолвится;
  ядро перезапускается, только если его IP среди ответов больше нет. При
  captive portal — подсказка «Wi-Fi требует входа».
- **Старт** не из UI (виджет, плитка, загрузка, always-on) сразу публикует
  Connecting; повторный START при живом туннеле — no-op. Смена активного профиля
  при живом туннеле — stop + start.

## Лог-система

- **Rust ring-buffer** — 10 MB в runtime, записи с монотонным `seq`.
- **Push-based** (v0.22+): `PhantomListener.onLogFrame(json)` — вызывается из Rust, в UI приходит напрямую.
- **`LogsViewModel`** — `ArrayDeque` на 10 000 строк, всё меняется на главном
  потоке, перефильтровка не чаще раза в 250 мс. История с диска (`LogPersister`)
  парсится на IO. «Очистить» стирает и файлы журнала.
- Подробный уровень ядра включается, только пока вкладка журнала на экране и
  приложение на переднем плане; иначе — штатный фильтр.
- **Иерархия уровней** (фильтр): `ALL > TRACE > DEBUG > INFO (default) > WARN > ERROR`.
  `applyFilter("INFO")` показывает INFO+WARN+ERROR.
- **`nativeSetLogLevel`** принимает `trace`/`debug`/`info` (warn/error → info на Rust-стороне).
- **Цвета**:
  - `ERROR` → `RedError` (`0xFFFF4A3D` в тёмной теме)
  - `WARN`  → `YellowWarning` (`0xFFFF7A3D`)
  - `DEBUG` → `BlueDebug` (`0xFF6C8BA8`)
  - прочее → `TextSecondary`

## Профили и подписки

- Подписка и флаг админа — только из `GET /api/me` (`expires_at`, `enabled`,
  `is_admin`), один запрос на сессию и только при живом туннеле активного
  профиля. Профиль перечитывается перед записью, меняются только `cached*`-поля;
  TOFU-пин сохраняется после успешного ответа, 4xx снимает флаг админа.
- Предстартового отказа по кешу подписки нет: кеш обновляется только через
  туннель, и устаревшее «истекла» запирало пользователя.
- **Ping** — `SettingsViewModel.measureTcpLatency()` через `Socket.connect()` с
  таймаутом 3 сек (TCP handshake RTT, а не ICMP); при включённом реле целится в
  реле. У неактивных профилей — прочерк.

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
  защищаются, иначе будет routing loop (сокет пойдёт внутрь туннеля). Сокеты
  создаёт ядро и зовёт `protect()` до connect.
- **Маршруты.** Полный туннель пропускает LAN, link-local и multicast (решение
  владельца, [ADR 0019](../decisions/0019-owner-decisions-audit-2026-10.md)).
  IPv6 не объявляется вовсе — ни адреса, ни `::/0`, ни IPv6-DNS: VpnService сам
  блокирует семейство, приложения уходят на IPv4. Прежний `addRoute(::/0)` без
  адреса включал IPv6 в туннель, который его не везёт, и строгий Private DNS
  (DoT по IPv6) убивал резолв целиком. В split-режиме каждый DNS-сервер
  заворачивается в туннель `/32`; в excludeRoute-ветке префикс короче `/8`
  включает полный туннель. `setUnderlyingNetworks` не вызывается — система
  сама следует за сетью по умолчанию.
- **`setMetered(false)`** — без него VPN при targetSdk 29+ считается платным, и
  «только по Wi-Fi» задачи (бэкап фото, автообновления) не шли.
- **Push-based listener** (v0.20+) — JNI больше не поллится. `PhantomListener`
  получает `onStatusFrame(json)` / `onLogFrame(json)` прямо из Rust runtime'а.
- **Foreground service** — VPN всегда foreground-service (`FOREGROUND_SERVICE_TYPE_SPECIAL_USE`),
  иначе OS убьёт при doze / memory pressure. Нотификация обязательна.
- **Автозапуск.** «Автозапуск при загрузке» — наш `BootReceiver` (без
  действующего согласия `VpnService.prepare` не стартует). После обновления
  приложения туннель поднимается по `was_running` независимо от автозапуска.
  Системный «Постоянный VPN» / «Блокировать без VPN» — настройки Android; строка
  в настройках ведёт туда (его состояние приложению при targetSdk 36 не видно).
- **Батарея.** Разрешения `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` больше нет
  (Play-политика) — в настройках ссылка на системный список оптимизации.
  `PARTIAL_WAKE_LOCK` пока держится всё время работы туннеля — до замера.
- **Резервные копии.** `dataExtractionRules` исключают `profiles.json`,
  `profiles/`, `datastore/` и `logs/` и из облачного бэкапа, и из переноса на
  новый телефон.

## Критичные pitfalls

- **`adb uninstall` перед install** — нужен при смене подписи или очистке данных.
- **`versionCode`** инкрементить **ПЕРЕД** тегом в `build.gradle.kts` (монотонно).
- **Split routing (per-app VPN)** — только Android 5.0+, через
  `VpnService.Builder.addDisallowedApplication()`.
- **`MAX_SPLIT_ROUTES = 8000`** — больше маршрутов переполняет Binder-транзакцию в
  `VpnService.Builder.establish()` → `TransactionTooLargeException`.
- **Поток чтения TUN владеет fd сам** (poll + флаг остановки) — `nativeStop`
  не висит на `read(fd)`.
- **`cachedAdminServerCertFp` (TOFU)** — при смене admin-server.crt на сервере
  клиент откажется соединяться; чистить руками или regenerate conn_string.

## Релизный процесс

Тестовая сборка и установка — только [`tools/ship-android.sh`](../../../tools/ship-android.sh)
(Unix-хост). Rust-ядро собирает сам gradle: `preBuild` → `buildRustAndroid`
(`cargo ndk -t arm64-v8a -t armeabi-v7a ... -o app/src/main/jniLibs`); `.so` в
git не лежит. Нужны `cargo-ndk`, NDK и rustup-таргеты `aarch64-linux-android`,
`armv7-linux-androideabi`.

Перед релизом в [apps/android/app/build.gradle.kts](../../../apps/android/app/build.gradle.kts)
— `versionCode` +1 и `versionName = "X.Y.Z"`, в `CHANGELOG.md` — секция
`## [Android X.Y.Z]`: из неё берётся «Что нового» для Play (первые 500 символов),
без неё или при теге ≠ `vX.Y.Z` Android-джоба CI падает. `ship-android.sh --tag`
проверяет это до сборки, требует чистое дерево и подтверждение «Проверил на
устройстве?». Тег `v*` → GitHub Actions (`release.yml`) собирает Release и
публикует в Play production. Подробно — [build.md](../build.md).

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
| v0.22.1 | 56 |
| v0.22.2 | 57 |
| v0.22.4 | 59 |
| v0.23.0 (Android 0.22.6) | 61 |
| v0.23.1 | 62 |
| … | … |
| v0.28.5 | 123 |
| v0.29.0 | 124 (текущий) |

Текущее значение — всегда в `build.gradle.kts`; таблица — исторические точки.

Монотонность versionCode критична: Google Play и `adb install` откажутся ставить
APK с versionCode ≤ уже установленному.

## Sources

- **Android app:** [apps/android/app/src/main/kotlin/com/ghoststream/vpn/](../../../apps/android/app/src/main/kotlin/com/ghoststream/vpn/)
- **Build config:** [apps/android/app/build.gradle.kts](../../../apps/android/app/build.gradle.kts)
- **JNI crate:** [crates/client-android/](../../../crates/client-android/)
- **Runtime (shared):** [crates/client-core-runtime/](../../../crates/client-core-runtime/)
- **ConnectProfile / StatusFrame / LogFrame канонические типы:** [crates/gui-ipc/](../../../crates/gui-ipc/)
- **Release CI:** [.github/workflows/release.yml](../../../.github/workflows/release.yml)
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md), [0016](../decisions/0016-android-route-budget.md) и [0017](../decisions/0017-android-exclude-routes.md) (маршруты), [0018 переподключение](../decisions/0018-rust-owns-reconnect.md), [0019 решения по аудиту](../decisions/0019-owner-decisions-audit-2026-10.md)
- **gitnexus:** `gitnexus_query({query: "android jni native start"})`, `gitnexus_impact({target: "nativeStart", direction: "upstream"})`
- **Build + deploy общее:** [../build.md](../build.md)
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
