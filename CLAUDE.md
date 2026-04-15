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
> APK собирается тоже на сервере через `gradlew` (JDK 17: `/usr/lib/jvm/java-17-openjdk`).
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
| **v0.19.0** | **49** ← текущий |

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

Активный режим — **H2 / TLS поверх TCP с мульти-стрим шардингом** (v0.17.0+):
- Порт `8443` на NL exit (через nginx stream SNI-routing с `443`)
- TLS 1.3 + mTLS (клиентский cert используется как аутентификация вместо Noise)
- **N_DATA_STREAMS = 4** параллельных TLS-соединений на одного клиента
  — каждый TLS занимает свой CPU core (шифрование single-threaded per stream)
- **flow_stream_idx** (5-tuple hash src_ip/dst_ip/src_port/dst_port/proto) —
  раскладывает поток по стримам, сохраняя порядок внутри одного TCP-flow
  (нет HoL blocking для несвязанных соединений, нет reordering внутри одного TCP)
- Zero-copy путь через `Bytes`/`BytesMut` (нет `.to_vec()` в горячем пути)
- Первый байт каждого TLS-стрима после handshake — `stream_idx: u8` (0..N_DATA_STREAMS)

Legacy режимы: QUIC + Noise (не используется), UDP+SRTP (не используется).

### Handshake (H2 / mTLS)

```
Client: N параллельных TCP connect к tls.nl2.bikini-bottom.com:443
        (каждый сокет защищён VpnService.protect() на Android)
nginx (NL:443) с ssl_preread: SNI=tls.nl2 → passthrough к 127.0.0.1:8443
phantom-server: TLS 1.3 + mTLS (client cert → fingerprint → keyring lookup)
Client → Server: [1B stream_idx]   (0, 1, 2, 3)
Server: attach_stream(stream_idx, mpsc::Sender) в SessionCoordinator
        (один SessionCoordinator на fingerprint, Vec<Mutex<Option<Sender>>>)
# Handshake complete
```

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
N_DATA_STREAMS      = 4            # кол-во параллельных TLS-стримов
QUIC_TUNNEL_MTU     = 1350         # MTU TUN интерфейса
QUIC_TUNNEL_MSS     = 1310         # TCP MSS clamping
```

### SNI Passthrough Relay (RU hop, v0.17.0+)

`phantom-relay` на RU-ноде (`hostkey.bikini-bottom.com:443`) больше **не терминирует TLS**.
Вместо этого:
1. Peek первых ~1.5KB TCP — парсит ClientHello, извлекает SNI
2. Если SNI == `expected_sni` (`tls.nl2.bikini-bottom.com`) → raw TCP `copy_bidirectional`
   к upstream (NL:443). TLS handshake идёт end-to-end между phone и phantom-server.
3. Иначе → fallback acceptor с LE cert → HTML-заглушка (выглядит как обычный HTTPS-сайт).

Это убирает двойное шифрование в RU-хоп — relay теперь I/O-bound, не CPU-bound.

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

### Сессии (`server/src/vpn_session.rs`)

- `SessionCoordinator` на клиент (индекс по fingerprint в `DashMap<String, Arc<VpnSession>>`)
- `data_sends: Vec<Mutex<Option<mpsc::Sender<Bytes>>>>` (слот на каждый stream_idx)
- `send_frame_rr` — round-robin раскладка батчей по доступным стримам
- `attach_stream` / `detach_stream_if` — при accept нового TLS открываем слот, при EOF закрываем
- Когда все стримы отвалились (`all_streams_down()`) — сессия удаляется из DashMap
- TUN→client: единый `mpsc::Sender<Bytes>` у координатора, распределитель читает batch и шлёт в любой живой стрим

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
