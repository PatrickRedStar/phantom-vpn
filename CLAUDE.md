# CLAUDE.md

Инструкции для Claude Code и агентов при работе с этим репозиторием.

---

## Обзор проекта

**GhostStream / PhantomVPN** — кастомный VPN-протокол, маскирующий трафик под обычный HTTPS для обхода DPI/TSPU. Транспорт — HTTP/2 поверх TLS 1.3 поверх TCP, с мульти-стрим шардингом и mTLS.

### Платформы

| Платформа | Статус | Описание |
|-----------|--------|----------|
| Android | ✅ Production | Compose UI, JNI, Foreground VPN Service |
| Linux | ✅ Production | CLI-клиент (`phantom-client-linux`) |
| Server | ✅ Production | `phantom-server` на VDS `89.110.109.128` |

---

## Структура репозитория

```
ghoststream/
├── crates/
│   ├── core/               # Общая библиотека (wire-формат, TLS, tun_uring, константы)
│   ├── server/             # phantom-server + phantom-keygen
│   ├── client-common/      # H2/TLS handshake + TX/RX циклы (переиспользуется всеми клиентами)
│   ├── client-linux/       # Linux TUN клиент
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
├── config/
│   ├── server.example.toml
│   └── client.example.toml
├── scripts/
│   └── deploy.sh
└── .github/workflows/
    └── release.yml         # CI: Linux + Android APK → GitHub Release
```

---

## Сборка

### Среда разработки

> **Claude Code запущен прямо на сервере vdsina (89.110.109.128).**
> `cargo` установлен локально — сборка server/linux/android выполняется напрямую.
> APK собирается на домашнем ПК через SSH тунель (см. memory/reference_apk_build.md).
> SSH ключ для всех удалённых хостов: `~/.ssh/bot` (алиасы в `~/.ssh/config`).

### Хосты

| Алиас | IP | Роль | DNS |
|-------|-----|------|-----|
| `vdsina` | 89.110.109.128 | NL exit-нода (phantom-server) | `tls.nl2.bikini-bottom.com` |
| — | 193.187.95.128 | RU relay-нода (phantom-relay) | `hostkey.bikini-bottom.com` |

### Rust — Server / Linux клиент (локально)

```bash
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-server
cargo build --release -p phantom-client-linux

# Деплой сервера
install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server
systemctl restart phantom-server.service
```

### Android .so (локально через cargo ndk)

```bash
export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android
cp target/aarch64-linux-android/release/libphantom_android.so \
  android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
```

### Android APK (локально)

```bash
cd android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon
# APK: android/app/build/outputs/apk/debug/app-debug.apk
```

---

## Развёртывание сервера

**Сервер (NL exit):** localhost (vdsina, 89.110.109.128)
**Relay (RU):** `ssh -i ~/.ssh/bot root@193.187.95.128`
**Исходники:** `/opt/github_projects/phantom-vpn/`
**Runtime:** `/opt/phantom-vpn/`
**Сервис:** `phantom-server.service`
**Конфиг:** `/opt/phantom-vpn/config/server.toml`
**Keyring:** `/opt/phantom-vpn/config/clients.json`

```bash
# Сборка + деплой (всё локально на vdsina)
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-server
install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server
systemctl restart phantom-server.service

# Статус и логи
systemctl status phantom-server.service
journalctl -u phantom-server.service -n 50 -f
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
| v0.9.0 | 16 |
| v0.10.0 | 17 |
| v0.18.5 | 48 |
| v0.19.0 | 49 |
| v0.19.1 | 50 |
| v0.19.2 | 51 |
| v0.19.3 | 52 |
| v0.19.4 | 53 |
| v0.20.0 | 54 |
| **v0.21.0** | **55** ← текущий |

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

Встроен в `phantom-server`. **Два listener-а** (v0.19+):

| Listener | Bind | Транспорт | Auth | Назначение |
|----------|------|-----------|------|------------|
| mTLS | `[admin].listen_addr` = `10.7.0.1:8080` | HTTPS + mTLS (наша PhantomVPN CA) | client cert → fingerprint → `is_admin` в keyring | Android/Linux админ-панель через VPN-туннель |
| loopback | `[admin].bot_listen_addr` = `127.0.0.1:8081` | plain HTTP | `Authorization: Bearer <[admin].token>` | Telegram-бот (break-glass канал, same-host только) |

Server cert для mTLS listener-а — self-signed для `10.7.0.1`, генерится при первом
старте в `/opt/phantom-vpn/config/admin-server.{crt,key}`. Android клиент пиннит
SHA-256 сертификата (TOFU) в `VpnProfile.cachedAdminServerCertFp`.

Role-авторизация (`is_admin`) хранится на сервере — в `clients.json` для каждой
записи. Toggle через `POST /api/clients/:name/admin`. Bootstrap первого админа —
через `phantom-keygen admin-grant --name <n> --enable`.

### Endpoints

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/api/status` | Uptime, активные сессии, IP сервера |
| GET | `/api/me` | Self-inspection: `{"name": "...", "is_admin": bool}` (любой client cert) |
| GET | `/api/clients` | Список клиентов (включает `is_admin`) |
| POST | `/api/clients` | Создать клиента `{"name":"alice","expires_days":30,"is_admin":false}` |
| POST | `/api/clients/:name/admin` | Toggle `is_admin`: `{"is_admin": true/false}` |
| DELETE | `/api/clients/:name` | Удалить клиента + файлы сертификатов |
| POST | `/api/clients/:name/enable` | Включить клиента |
| POST | `/api/clients/:name/disable` | Отключить клиента (существующая сессия сохраняется) |
| GET | `/api/clients/:name/conn_string` | Получить строку подключения (`ghs://...`) |
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
  "expires_at": 1780000000,   // Unix timestamp, null = бессрочно
  "is_admin": false
}]
```

---

## Строка подключения (Connection String)

v0.19+ — URL-формат `ghs://`. Используется во всех клиентах (Android, Linux, OpenWrt).

```
ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1
```

- **userinfo** — base64url двух PEM-блоков подряд (cert chain + PKCS8 key); парсер
  сплитит по маркерам `-----BEGIN`.
- **host:port** — адрес phantom-server.
- **query**:
  - `sni` — обязательный (TLS SNI, должен матчить сертификат сервера / LE cert).
  - `tun` — обязательный, CIDR TUN-клиента (URL-encoded `/` → `%2F`).
  - `v=1` — версия формата.

**Нет `ca`, `admin`, `insecure`.** Сервер верифицируется через системный + webpki
root store (LE cert). Админство — динамическое, из `is_admin` в keyring, см.
секцию «Admin HTTP API». Backcompat со старым base64-JSON форматом **не
поддерживается** — старые conn_string после v0.19.0 надо перегенерировать через бота.

Парсинг: `crates/client-common/src/helpers.rs::parse_conn_string` +
`android/app/.../data/ConnStringParser.kt` +
`openwrt/proto/ghoststream.sh` (через `ghoststream --print-tun-addr`).

Генерация: `crates/server/src/admin.rs::build_conn_string`.

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

Единственный режим транспорта — **H2 / TLS поверх TCP с мульти-стрим шардингом** (v0.17.0+, QUIC удалён в v0.19.4):
- Порт `8443` на NL exit (через nginx stream SNI-routing с `443`)
- TLS 1.3 + mTLS (клиентский cert — единственная аутентификация; Noise удалён в v0.18)
- **`n_data_streams()`** = `available_parallelism().clamp(2, 16)` параллельных TLS-соединений на одного клиента. Каждая сторона вычисляет свой `n` локально, handshake обменивается байтами, `effective_n = client_max.clamp(MIN, MAX)` (см. `crates/core/src/wire.rs` + `reference_tx_ceiling.md`).
- **flow_stream_idx** (5-tuple hash src_ip/dst_ip/src_port/dst_port/proto) —
  раскладывает поток по стримам, сохраняя порядок внутри одного TCP-flow
  (нет HoL blocking для несвязанных соединений, нет reordering внутри одного TCP)
- Zero-copy путь через `Bytes`/`BytesMut` (нет `.to_vec()` в горячем пути)
- Handshake (v0.18+): `[1B stream_idx][1B client_max_streams]` атомарно в первом write каждого TLS-стрима

### Handshake (H2 / mTLS)

```
Client: N параллельных TCP connect к tls.nl2.bikini-bottom.com:443
        (каждый сокет защищён VpnService.protect() на Android)
nginx (NL:443) с ssl_preread: SNI=tls.nl2 → passthrough к 127.0.0.1:8443
phantom-server: TLS 1.3 + mTLS (client cert → fingerprint → keyring lookup)
Client → Server: [1B stream_idx][1B client_max_streams]    (атомарно, read_exact)
Server: effective_n = client_max.clamp(MIN=2, MAX=16)
        attach_stream(stream_idx, mpsc::Sender) в SessionCoordinator
        (один SessionCoordinator на fingerprint, Vec<Mutex<Option<Sender>>>)
# Handshake complete
```

**Mimicry warmup** (`crates/server/src/mimicry.rs`): после handshake server на stream_idx==0 шлёт 4 плейсхолдер-батча (2/8/16/24 KB) за ~800ms, имитируя H.264 I-frame pattern. Клиент silently drop'ит non-IPv4 пакеты в `tls_rx_loop`.

**Fakeapp** (`crates/server/src/fakeapp.rs`): fallback H2-сервер для соединений без правильного client cert. Отдаёт `/`, `/favicon.ico`, `/robots.txt`, `/api/v1/{health,status}` с nginx-like headers. Для active-probing резистентности.

### Wire Format (внутри каждого TLS-стрима)

```
[4B frame_len][batch]

Batch:
  [2B pkt1_len][pkt1_bytes]
  [2B pkt2_len][pkt2_bytes]
  ...
  [2B 0x0000]           ← маркер конца батча
  [random padding]      ← до target_size от H264Shaper (по желанию)
```

Константы (`crates/core/src/wire.rs`):
```
BATCH_MAX_PLAINTEXT = 65536        # макс. размер одного фрейма
MIN_N_STREAMS       = 2            # минимум параллельных TLS-стримов
MAX_N_STREAMS       = 16           # жёсткий cap (bounds stream_idx/data_sends)
n_data_streams()    = clamp(2..16) # derive from available_parallelism() per host
QUIC_TUNNEL_MTU     = 1350         # MTU TUN интерфейса (legacy naming)
QUIC_TUNNEL_MSS     = 1310         # TCP MSS clamping (legacy naming)
```

### SNI Passthrough Relay (RU hop, v0.17.0+)

`phantom-relay` на RU-ноде (`hostkey.bikini-bottom.com:443`) больше **не терминирует TLS**.
Вместо этого:
1. Peek первых ~1.5KB TCP — парсит ClientHello, извлекает SNI
2. Если SNI == `expected_sni` (`tls.nl2.bikini-bottom.com`) → raw TCP `copy_bidirectional`
   к upstream (NL:443). TLS handshake идёт end-to-end между phone и phantom-server.
3. Иначе → fallback acceptor с LE cert → HTML-заглушка (выглядит как обычный HTTPS-сайт).

Это убирает двойное шифрование в RU-хоп — relay теперь I/O-bound, не CPU-bound.

### Шифрование

**TLS 1.3 + mTLS** — `rustls 0.23` с `ring` crypto provider. Cipher suites по умолчанию (TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256). Клиентская аутентификация — mTLS через self-signed PhantomVPN CA, fingerprint → `clients.json` keyring lookup. Noise protocol удалён в v0.18 (заменён на mTLS).

Ключи клиентов (серверный CA + client cert/key) — все в `clients.json` и per-client файлах `/opt/phantom-vpn/config/clients/<name>.{crt,key}`. Нет статических Noise keypair'ов — каждый клиент = уникальный x509 сертификат.

### Шейпинг трафика

Padding отключён начиная с v0.17 (модуль `shaper` удалён). Anti-DPI достигается
за счёт H2 mux, nginx SNI-passthrough и natural H.264-like бёрстов от
WebRTC-подобных pattern-ов.

### Сессии (`server/src/vpn_session.rs`)

- `SessionCoordinator` на клиент (индекс по fingerprint в `DashMap<String, Arc<VpnSession>>`)
- `data_sends: Vec<Mutex<Option<mpsc::Sender<Bytes>>>>` (слот на каждый stream_idx)
- `send_frame_rr` — round-robin раскладка батчей по доступным стримам
- `attach_stream` / `detach_stream_if` — при accept нового TLS открываем слот, при EOF закрываем
- Когда все стримы отвалились (`all_streams_down()`) — сессия удаляется из DashMap
- TUN→client: единый `mpsc::Sender<Bytes>` у координатора, распределитель читает batch и шлёт в любой живой стрим

### Пассивный DNS-кэш (`server/src/vpn_session.rs`)

Сервер перехватывает UDP пакеты с src_port=53 (ответы DNS) → парсит A-записи → кэширует IP→hostname в `VpnSession.dns_cache`. Используется в логах `/api/clients/:name/logs` для отображения доменов вместо IP.

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

## CI/CD (GitHub Actions)

Файл: `.github/workflows/release.yml`
Триггер: тег `v*` или `workflow_dispatch`

| Job | Runner | Артефакт |
|-----|--------|---------|
| `build-linux` | ubuntu-latest | `phantom-client-linux` (x86_64) |
| `build-android` | ubuntu-latest | `app-debug.apk` |
| `release` | ubuntu-latest | GitHub Release со всеми артефактами |

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
# Статус сервиса (локально на vdsina)
systemctl status phantom-server
journalctl -u phantom-server -n 50 -f

# Конфиг клиентов
cat /opt/phantom-vpn/config/clients.json

# Admin API (из VPN-туннеля)
curl -H "Authorization: Bearer <token>" http://10.7.0.1:8080/api/status
curl -H "Authorization: Bearer <token>" http://10.7.0.1:8080/api/clients

# SSH на RU relay
ssh -i ~/.ssh/bot root@193.187.95.128
```

---

## Частые ошибки и решения

| Проблема | Решение |
|----------|---------|
| `JAVA_HOME not set` | `JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew ...` |
| `git push github` | Remote называется `origin`, не `github` |
| `adminUrl/adminToken` не сохраняются | Баг исправлен в v0.8.7: `ProfilesStore` теперь сериализует оба поля |
| `adb uninstall` перед install | Нужно при смене подписи или очистке данных |
| versionCode не совпадает | Обновить `build.gradle.kts` перед тегом (см. таблицу выше) |
| Подписка не отображается | Требует `adminUrl` + `adminToken` в профиле (нужна строка подключения v0.7+) |

## Мульти-агентный workflow (REQUIRED для крупных задач)

**При задачах, затрагивающих >5 файлов или ≥3 независимых файловых зон — обязательно запускать параллельных субагентов через `Agent` tool одним сообщением.** Не делать всё инлайн — это медленно и разбазаривает контекст.

### Декомпозиция по зонам (non-overlapping edits)

| Агент | Зона |
|-------|------|
| **Dev-Server** | `crates/server/` |
| **Dev-Android** | `android/`, `crates/client-android/` |
| **Dev-Linux** | `crates/client-linux/` |
| **general-purpose** | `crates/core/`, `crates/client-common/` (по желанию разбить) |
| **general-purpose (docs)** | `*.md`, `config/`, `scripts/` |

### Правила

1. **Запуск** — один tool-call с несколькими `Agent` блоками = параллельное выполнение. Последовательные вызовы = серия (медленнее в N раз).
2. **Non-overlap** — агенты не должны править одни и те же файлы. Иначе merge conflicts в рабочем дереве.
3. **Self-contained prompts** — у агента нет контекста беседы. Каждому давать: цель, затрагиваемые файлы, что-уже-сделано, что-сделать, как валидировать.
4. **Валидация после merge** — главный агент сам прогоняет `cargo check -p <crate>`, `cargo test`, фиксит cross-crate compile errors (агенты их пропускают).
5. **Точечные правки** (1 файл, <50 строк) — субагент не нужен, делать инлайн.

### Sign of task fit

- ≥3 crate'ов/модулей
- Низкая взаимозависимость правок
- Можно сформулировать задачу ≤200 слов на агента

**Пример:** v0.19.4 релиз (удаление QUIC + 4 bug fixes + renaming) → 4 агента × ~20 минут вместо ~80 минут инлайн.

---

## gstack (REQUIRED — global install)

**Before doing ANY work, verify gstack is installed:**

```bash
test -d ~/.claude/skills/gstack/bin && echo "GSTACK_OK" || echo "GSTACK_MISSING"
```

If GSTACK_MISSING: STOP. Do not proceed. Tell the user:

> gstack is required for all AI-assisted work in this repo.
> Install it:
> ```bash
> git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
> cd ~/.claude/skills/gstack && ./setup --team
> ```
> Then restart your AI coding tool.

Do not skip skills, ignore gstack errors, or work around missing gstack.

Using gstack skills: After install, skills like /qa, /ship, /review, /investigate,
and /browse are available. Use /browse for all web browsing.
Use ~/.claude/skills/gstack/... for gstack file paths (the global path).
