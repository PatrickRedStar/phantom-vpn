# CLAUDE.md

Инструкции для Claude Code и агентов при работе с этим репозиторием.

---

## Обзор проекта

**GhostStream / PhantomVPN** — кастомный VPN-протокол, маскирующий трафик под WebRTC/SRTP (имитация видеозвонков) для обхода DPI/TSPU. Трафик выглядит как зашифрованные H.264-видеопотоки поверх QUIC/HTTP3.

### Платформы

| Платформа | Статус | Описание |
|-----------|--------|----------|
| Android | ✅ Production | Compose UI, JNI, Foreground VPN Service |
| Linux | ✅ Production | CLI-клиент (`phantom-client-linux`) |
| macOS | ✅ Beta | SwiftUI menu bar app (`PhantomVPN.app`) |
| Server | ✅ Production | `phantom-server` на VDS `89.110.109.128` |

---

## Структура репозитория

```
ghoststream/
├── crates/
│   ├── core/               # Общая библиотека (крипто, wire-формат, шейпинг)
│   ├── server/             # phantom-server + phantom-keygen
│   ├── client-common/      # QUIC handshake + TX/RX циклы (переиспользуется всеми клиентами)
│   ├── client-linux/       # Linux TUN клиент
│   ├── client-macos/       # macOS utun клиент
│   └── client-android/     # Android JNI библиотека → libphantom_android.so
├── android/                # Android приложение (Kotlin + Compose)
│   └── app/src/main/
│       ├── kotlin/com/ghoststream/vpn/
│       │   ├── data/               # ProfilesStore, PreferencesStore, VpnProfile, ConnStringParser
│       │   ├── service/            # GhostStreamVpnService, VpnStateManager
│       │   ├── ui/
│       │   │   ├── dashboard/      # DashboardScreen + DashboardViewModel
│       │   │   ├── logs/           # LogsScreen + LogsViewModel
│       │   │   ├── settings/       # SettingsScreen + SettingsViewModel
│       │   │   ├── admin/          # AdminScreen + AdminViewModel
│       │   │   ├── components/     # ConnectButton, StatCard, QrScannerScreen
│       │   │   └── theme/          # Color.kt, Theme.kt
│       │   ├── navigation/         # AppNavigation.kt
│       │   └── MainActivity.kt
│       ├── jniLibs/arm64-v8a/      # libphantom_android.so (собирается cargo ndk)
│       └── res/xml/
│           ├── file_paths.xml      # FileProvider пути (logs/, debug/)
│           └── network_security_config.xml
├── phantom-vpn-macos/      # macOS SwiftUI приложение
│   ├── Sources/PhantomVPN/
│   │   ├── Models/         # VpnManager.swift, AdminManager.swift
│   │   └── Views/          # ContentView, ConnectionTab, ProfilesTab, LogsTab, AdminPanelView
│   ├── Package.swift
│   └── build.sh            # swift build → PhantomVPN.app bundle
├── config/
│   ├── server.example.toml
│   └── client.example.toml
├── scripts/
│   └── deploy.sh
└── .github/workflows/
    └── release.yml         # CI: Linux + macOS DMG + Android APK → GitHub Release
```

---

## Сборка

### Важные ограничения

> **На локальной машине (CachyOS) `cargo` НЕ установлен.**
> Rust сборка для server/linux/macos происходит ТОЛЬКО через SSH на сервер vdsina.
> Android `.so` собирается там же через `cargo ndk`.
> APK собирается локально через `gradlew` (JDK 17 установлен: `/usr/lib/jvm/java-17-openjdk`).

### Rust — Server / Linux клиент (через SSH)

```bash
# Синхронизировать исходники на сервер
rsync -avz -e "ssh -i ~/.ssh/personal" crates/ root@89.110.109.128:/opt/phantom-vpn/src/crates/

# Собрать на сервере
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "source ~/.cargo/env && cd /opt/phantom-vpn/src && cargo build --release -p phantom-server"

# Скачать клиент (опционально)
scp -i ~/.ssh/personal root@89.110.109.128:/opt/phantom-vpn/src/target/release/phantom-client-linux \
  /tmp/phantom-client-linux
sudo install -m 0755 /tmp/phantom-client-linux /usr/local/bin/phantom-client-linux
```

### Android .so (через SSH на vdsina)

```bash
rsync -avz -e "ssh -i ~/.ssh/personal" crates/ root@89.110.109.128:/opt/phantom-vpn/src/crates/
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "source ~/.cargo/env && cd /opt/phantom-vpn/src && \
   export ANDROID_NDK_HOME=\$ANDROID_NDK_ROOT && \
   cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android"
scp -i ~/.ssh/personal \
  root@89.110.109.128:/opt/phantom-vpn/src/target/aarch64-linux-android/release/libphantom_android.so \
  android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
```

### Android APK (локально)

```bash
# Сборка debug APK
cd android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon

# APK находится в:
android/app/build/outputs/apk/debug/app-debug.apk

# Установить на телефон
adb uninstall com.ghoststream.vpn 2>/dev/null; adb install android/app/build/outputs/apk/debug/app-debug.apk
```

### macOS App (на машине с macOS)

```bash
cd phantom-vpn-macos
swift build -c release
bash build.sh   # → PhantomVPN.app
```

---

## Развёртывание сервера

**Сервер:** `root@89.110.109.128`
**Директория:** `/opt/phantom-vpn/`
**Сервис:** `phantom-server.service`
**Конфиг:** `/opt/phantom-vpn/config/server.toml`
**Keyring:** `/opt/phantom-vpn/config/clients.json`

```bash
# Полный деплой
bash ./scripts/deploy.sh root@89.110.109.128 ~/.ssh/personal

# Быстрое обновление (только crates)
rsync -avz -e "ssh -i ~/.ssh/personal" crates/ root@89.110.109.128:/opt/phantom-vpn/src/crates/
ssh -i ~/.ssh/personal root@89.110.109.128 \
  "source ~/.cargo/env && cd /opt/phantom-vpn/src && \
   cargo build --release -p phantom-server && \
   install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server && \
   systemctl restart phantom-server.service"

# Статус и логи
ssh -i ~/.ssh/personal root@89.110.109.128 "systemctl status phantom-server.service"
ssh -i ~/.ssh/personal root@89.110.109.128 "journalctl -u phantom-server.service -n 50 -f"
```

---

## Релизный процесс (Android)

При каждом новом релизе **обязательно** обновить `android/app/build.gradle.kts`:

```kotlin
versionCode = <N+1>          // инкремент целого числа
versionName = "X.Y.Z"        // семантическая версия
buildConfigField("String", "GIT_TAG", "\"vX.Y.Z\"")
```

### История версий (для расчёта versionCode)

| Tag | versionCode |
|-----|-------------|
| v0.8.5 | 11 |
| v0.8.6 | 12 |
| v0.8.7 | 13 |
| v0.8.8 | 14 |
| v0.8.9 | 15 |
| **v0.9.0** | **16** ← текущий |

После обновления `build.gradle.kts`:
```bash
# Собрать APK
cd android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon

# Коммит + тег + пуш
git add android/app/build.gradle.kts ...
git commit -m "feat: vX.Y.Z ..."
git tag vX.Y.Z
git push origin master && git push origin vX.Y.Z

# Установить на телефон
adb uninstall com.ghoststream.vpn 2>/dev/null
adb install android/app/build/outputs/apk/debug/app-debug.apk
```

GitHub Actions автоматически создаст Release при пуше тега `v*`.

---

## Admin HTTP API

Встроен в `phantom-server`. Слушает на `[admin].listen_addr` (по умолчанию `10.7.0.1:8080`).
Доступен **только через VPN-туннель**. Все запросы: `Authorization: Bearer <token>`.

### Endpoints

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/api/status` | Uptime, активные сессии, IP сервера |
| GET | `/api/clients` | Список клиентов с онлайн-статусом и expires_at |
| POST | `/api/clients` | Создать клиента `{"name":"alice","expires_days":30}` |
| DELETE | `/api/clients/:name` | Удалить клиента + файлы сертификатов |
| POST | `/api/clients/:name/enable` | Включить клиента |
| POST | `/api/clients/:name/disable` | Отключить клиента (существующая сессия сохраняется) |
| GET | `/api/clients/:name/conn_string` | Получить строку подключения |
| GET | `/api/clients/:name/stats` | Статистика трафика `[{ts,bytes_rx,bytes_tx}]` |
| GET | `/api/clients/:name/logs` | Последние 200 dst-записей `[{ts,dst,port,proto,bytes}]` |
| POST | `/api/clients/:name/subscription` | Управление подпиской (см. ниже) |

### Подписки — POST /api/clients/:name/subscription

```json
{"action": "extend", "days": 30}   // Продлить на N дней
{"action": "set",    "days": 90}   // Установить: now + N дней
{"action": "cancel"}               // Убрать ограничение (бессрочно)
{"action": "revoke"}               // Отключить немедленно + expires_at = now
```

Автоматическая проверка каждые 60 сек в `run_subscription_checker` (server/src/admin.rs).
При истечении: `enabled = false` в keyring, сессия принудительно сбрасывается.

### Формат ответа GET /api/clients

```json
[{
  "name": "alice",
  "fingerprint": "aa:bb:...",
  "tun_addr": "10.7.0.2/24",
  "enabled": true,
  "connected": true,
  "bytes_rx": 1234567,
  "bytes_tx": 654321,
  "created_at": "2025-01-01T00:00:00Z",
  "last_seen_secs": 3,
  "expires_at": 1780000000   // Unix timestamp, null = бессрочно
}]
```

---

## Строка подключения (Connection String)

Base64url-кодированный JSON. Используется во всех клиентах (Android, macOS).

```json
{
  "addr": "89.110.109.128:8443",
  "sni":  "vpn.example.com",
  "tun":  "10.7.0.2/24",
  "cert": "-----BEGIN CERTIFICATE-----\n...",
  "key":  "-----BEGIN PRIVATE KEY-----\n...",
  "ca":   "-----BEGIN CERTIFICATE-----\n...",   // опционально
  "admin": {
    "url":   "http://10.7.0.1:8080",
    "token": "secret-token"
  }
}
```

Парсинг: `android/app/.../data/ConnStringParser.kt`
Генерация: `crates/server/src/admin.rs` → `build_conn_string()`

---

## Конфигурация

### Сервер (`config/server.toml`)

```toml
listen_addr   = "89.110.109.128:8443"
tun_addr      = "10.7.0.1/24"
wan_iface     = "ens3"              # для NAT/iptables
server_private_key = "..."
server_public_key  = "..."
cert_subjects = ["89.110.109.128", "vpn.example.com"]

[admin]
listen_addr = "10.7.0.1:8080"
token       = "secret-token"
clients_path = "/opt/phantom-vpn/config/clients.json"
ca_cert_path = "/opt/phantom-vpn/config/ca.crt"
ca_key_path  = "/opt/phantom-vpn/config/ca.key"
admin_url    = "http://10.7.0.1:8080"
```

### Клиент Linux (`/etc/phantom-vpn/client.toml`)

```toml
server_addr = "89.110.109.128:8443"
server_name = "89.110.109.128"
insecure    = true               # или false если есть CA
tun_addr    = "10.7.0.2/24"
tun_mtu     = 1350
default_gw  = "10.7.0.1"
client_private_key = "..."
client_public_key  = "..."
server_public_key  = "..."
```

---

## Архитектура протокола

### Транспорт

Единственный активный режим — **QUIC streams**:
- ALPN=`h3` (имитирует HTTP/3), порт `8443`
- TLS 1.3 поверх QUIC (self-signed cert)
- Noise IK handshake поверх QUIC control stream (аутентификация клиента)
- Данные — bidirectional QUIC stream (надёжная доставка)

Legacy UDP+SRTP (порт 3478) — код в `wire.rs`, не используется.

### Handshake (`client-common/quic_handshake.rs`)

```
Client → Server: QUIC connect (TLS 1.3 + ALPN h3)
Client → Server: open_bi() → control stream
Client → Server: [4B len][Noise IK msg1]   (→ e, es, s, ss)
Server → Client: [4B len][Noise IK msg2]   (← e, ee, se)
Client → Server: open_bi() → data stream
# Handshake complete — обе стороны имеют NoiseSession
```

### Wire Format

```
[4B total_len][8B nonce u64 BE][Noise ciphertext + AEAD tag]

Plaintext (batch):
  [2B pkt1_len][pkt1_bytes]
  [2B pkt2_len][pkt2_bytes]
  ...
  [2B 0x0000]           ← маркер конца батча
  [random padding]      ← до target_size от H264Shaper
```

Константы:
```
BATCH_MAX_PLAINTEXT = 65536   # макс. размер одного фрейма
QUIC_TUNNEL_MTU     = 1350    # MTU TUN интерфейса
QUIC_TUNNEL_MSS     = 1310    # TCP MSS clamping
```

### Шифрование (`core/src/crypto.rs`)

```
Noise_IK_25519_ChaChaPoly_BLAKE2s
```
- IK: клиент знает pub key сервера → нет лишнего round-trip
- `StatelessTransportState`, nonce = u64 (явный)
- Рекейинг: каждые 100 MB или 600 сек

### Шейпинг трафика (`core/src/shaper.rs`)

H.264 симуляция, 30 fps, GOP=60:
- I-кадр (каждые 60 фреймов): burst 15–50 KB
- P-кадры: LogNormal (μ=7.0, σ=0.8), ~1–4 KB

### Сессии (`core/src/session.rs`)

- `DashMap<IpAddr, Arc<QuicSession>>` — индекс по tunnel IP клиента
- `ReplayWindow` — 64-бит скользящее окно, защита от replay
- QUIC keep-alive: 10 сек; idle timeout: 30 сек
- Cleanup: каждые 60 сек удаляет сессии старше `idle_secs`

### Пассивный DNS-кэш (`server/quic_server.rs`)

Сервер перехватывает UDP пакеты с src_port=53 (ответы DNS) → парсит A-записи → кэширует IP→hostname в `QuicSession.dns_cache`. Используется в логах `/api/clients/:name/logs` для отображения доменов вместо IP.

---

## Android — архитектура

### Стек

- **Kotlin + Jetpack Compose** (Material3, Navigation Compose)
- **ViewModel + StateFlow** (реактивный UI)
- **JNI** → `libphantom_android.so` (Rust)
- **Android VPN Service** → `GhostStreamVpnService`
- **DataStore** (PreferencesStore) + **JSON-файл** (ProfilesStore)

### Экраны и навигация

```
MainActivity
└── AppNavigation
    ├── DashboardScreen    — подключение, таймер, статистика, статус подписки
    ├── LogsScreen         — Rust лог-буфер, уровни TRACE/DEBUG/INFO/WARN/ERROR
    ├── SettingsScreen     — профили + ping, DNS, маршрутизация, per-app, тема, debug share
    ├── AdminScreen        — панель управления сервером (клиенты, подписки, трафик)
    └── QrScannerScreen    — сканирование QR-кода строки подключения
```

### Слой данных

| Класс | Хранилище | Описание |
|-------|-----------|----------|
| `ProfilesStore` | `files/profiles.json` | Синглтон. Список VpnProfile, activeId |
| `PreferencesStore` | DataStore | DNS, routing, per-app, тема |
| `VpnProfile` | — | id, name, serverAddr, serverName, insecure, certPath, keyPath, caCertPath, tunAddr, **adminUrl, adminToken** |
| `ConnStringParser` | — | Base64url JSON → VpnProfile поля |

### JNI методы (`GhostStreamVpnService.kt`)

| Метод | Описание |
|-------|----------|
| `nativeStart(tunFd, serverAddr, serverName, insecure, certPath, keyPath, caCertPath): Int` | Запустить туннель; 0 = OK |
| `nativeStop()` | Остановить туннель |
| `nativeGetStats(): String?` | JSON: bytes_rx, bytes_tx, pkts_rx, pkts_tx, connected |
| `nativeGetLogs(sinceSeq: Long): String?` | JSON-массив лог-записей с seq > sinceSeq; -1 = все |
| `nativeSetLogLevel(level: String)` | "trace"/"debug"/"info" (warn/error → info на Rust стороне) |
| `nativeComputeVpnRoutes(directCidrsPath: String): String?` | Инвертированные CIDR-маршруты для split-routing |

### VPN State Machine (`VpnStateManager.kt`)

```
Disconnected → Connecting → Connected
                    ↑            ↓ (tunnel drop)
                    └── Connecting (watchdog reconnect)
              ↓ (timeout/error)
             Error
             ↓
        Disconnected
```

Watchdog: поллинг `nativeGetStats()` каждые 1 сек. Reconnect: exponential backoff 3s→6s→12s→24s→48s→60s (8 попыток), затем Error.

### Лог-система (Android)

- Rust кольцевой буфер: 10 MB, `nativeGetLogs(sinceSeq)` → JSON
- `LogsViewModel`: поллинг каждые 500ms, `allLogs: MutableList<LogEntry>` (до 50 000)
- Уровни (иерархические): ALL > TRACE > DEBUG > **INFO** (default) > WARN > ERROR
- `applyFilter("INFO")` показывает INFO+WARN+ERROR
- `nativeSetLogLevel`: принимает "trace", "debug", "info" (warn/error оба дают info в Rust)
- Цвета: ERROR=RedError, WARN=YellowWarning, DEBUG=BlueDebug, остальное=TextSecondary

### Профили и подписки (Android)

- `DashboardViewModel.fetchSubscriptionInfo()`: при подключении запрашивает `GET /api/clients` через adminUrl/adminToken, находит себя по `tun_addr`, показывает оставшееся время
- `SettingsViewModel.fetchAllSubscriptions()`: вызывается в init, обновляет `profileSubscriptions` для всех профилей с adminUrl
- Ping: `SettingsViewModel.measureTcpLatency()` — TCP Socket.connect() с таймаутом 3 сек

### Debug Share (`SettingsViewModel.shareDebugReport`)

Собирает: версия приложения + git tag, Android OS + модель, активный профиль (без ключей), VPN state, конфиг (DNS, routing, per-app), последние 500 строк Rust-логов.
FileProvider: `cache/debug/ghoststream-debug.txt` → `ACTION_SEND`.

---

## macOS — архитектура

Путь: `phantom-vpn-macos/`

- **SwiftUI MenuBarExtra** (macOS 13+, `.menuBarExtraStyle(.window)`)
- Запускает `phantom-client-macos --conn-string-file /tmp/phantom-vpn-cs.tmp` через `NSAppleScript` (для root)
- Мониторинг: `pgrep phantom-client-macos`
- Логи: tail `/tmp/phantom-vpn.log`
- `AdminManager.swift` — полный аналог Android AdminViewModel (URLSession async/await)

```
PhantomVPN.app/
└── Contents/MacOS/
    ├── PhantomVPN              ← Swift binary (MenuBarExtra)
    └── phantom-client-macos   ← Rust binary (копируется при сборке)
```

---

## CI/CD (GitHub Actions)

Файл: `.github/workflows/release.yml`
Триггер: тег `v*` или `workflow_dispatch`

| Job | Runner | Артефакт |
|-----|--------|---------|
| `build-linux` | ubuntu-latest | `phantom-client-linux` (x86_64) |
| `build-macos` | macos-14 (arm64) | `PhantomVPN-macOS.dmg` (universal binary) |
| `build-android` | ubuntu-latest | `app-debug.apk` |
| `release` | ubuntu-latest | GitHub Release со всеми артефактами |

macOS: `lipo -create` для universal binary (arm64 + x86_64), `hdiutil` для DMG.

---

## Теневые цвета (Theme)

```kotlin
GreenConnected = Color(0xFF69F0AE)   // подключено, ping < 100ms
RedError       = Color(0xFFFF5252)   // ошибка, истекшая подписка, ping ≥ 300ms
YellowWarning  = Color(0xFFFFD740)   // предупреждение, ping 100–300ms
BlueDebug      = Color(0xFF40C4FF)   // DEBUG логи
TextPrimary    = Color(0xFFE0E0E0)
TextSecondary  = Color(0xFF9E9E9E)
```

---

## Типичные задачи — команды

```bash
# Клиент на телефоне
adb devices
adb uninstall com.ghoststream.vpn
adb install android/app/build/outputs/apk/debug/app-debug.apk

# Логи Android в реальном времени
adb logcat -s GhostStreamVpn

# SSH на сервер
ssh -i ~/.ssh/personal root@89.110.109.128

# Статус сервиса
ssh -i ~/.ssh/personal root@89.110.109.128 "systemctl status phantom-server"

# Проверить конфиг клиентов
ssh -i ~/.ssh/personal root@89.110.109.128 "cat /opt/phantom-vpn/config/clients.json"

# Admin API напрямую (из VPN-туннеля)
curl -H "Authorization: Bearer <token>" http://10.7.0.1:8080/api/status
curl -H "Authorization: Bearer <token>" http://10.7.0.1:8080/api/clients
```

---

## Частые ошибки и решения

| Проблема | Решение |
|----------|---------|
| `cargo not found` | Сборка только через SSH на vdsina |
| `JAVA_HOME not set` | `JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew ...` |
| `git push github` | Remote называется `origin`, не `github` |
| `adminUrl/adminToken` не сохраняются | Баг исправлен в v0.8.7: `ProfilesStore` теперь сериализует оба поля |
| `adb uninstall` перед install | Нужно при смене подписи или очистке данных |
| versionCode не совпадает | Обновить `build.gradle.kts` перед тегом (см. таблицу выше) |
| Подписка не отображается | Требует `adminUrl` + `adminToken` в профиле (нужна строка подключения v0.7+) |
