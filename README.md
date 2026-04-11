# PhantomVPN / GhostStream 👻

> Версия репозитория: **v0.18.2** · транспорт: **HTTP/2 + TLS 1.3 (primary)** · QUIC/H3 (legacy/fallback)

PhantomVPN (бренд Android-приложения — **GhostStream**) — кастомный VPN-протокол, маскирующий трафик под обычный HTTPS/gRPC, чтобы устойчиво обходить DPI и ТСПУ.

Изначально (`v0.3–v0.14`) протокол строился вокруг QUIC/H3 и шейпинга под H.264 видеозвонок. После того как ТСПУ стал дросселить QUIC/UDP на потребительских каналах до ~80 Mbps, начиная с **v0.15** был добавлен параллельный транспорт на TCP/TLS + HTTP/2, который и стал основным для мобильных клиентов. Текущий дизайн подробно описан в [`other_docs/PLAN_v2_transport.md`](other_docs/PLAN_v2_transport.md) (историческая плановая запись) и актуализирован в [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Что есть сейчас (v0.18.2)

* **Транспорт:** TLS 1.3 + HTTP/2 поверх TCP, мультистрим с flow-affine hash-раскладкой по стримам. На 2+ CPU сервера 8 параллельных стримов работают в параллельных батч-циклах (download с одного клиента 138→625 Mbit/s, v0.17.2). QUIC/H3 сохранён как legacy/fallback транспорт (`transport=quic|h2|auto`).
* **Auth:** **mTLS** (клиентский cert = identity, fingerprint сверяется с сервером). Noise IK был в v0.3–v0.4, удалён в opt-v4 в пользу mTLS.
* **Сессии:** `SessionCoordinator` на клиента (индекс по fingerprint), N открытых TLS-стримов → `attach_stream`/`detach_stream_if`. Multi-stream handshake negotiation + zombie session eviction в v0.18.1.
* **DPI-маскировка:**
  * H.264 шейпинг (I/P-frame padding, LogNormal) поверх batch plaintext (opt-v8)
  * **Mimicry warmup** — первые ~2 секунды сессии пишется staged последовательность «HTML → image → image → bundle» с 50KB бюджетом, чтобы не выглядеть как «TLS handshake → instant VPN hammering» (v0.18.0)
  * **Heartbeat frames (detection vector 12)** — на idle-стримах каждые 20–30 секунд случайный 40–200B фрейм с sentinel-версией `0x0`, имитирует keepalive обычного мобильного клиента (v0.18.2)
  * **REALITY-style fallback** — отсутствующий client cert → отдача реального HTML/HTTP/2 контента (opt-v9)
* **RU relay** — `phantom-relay` на RU-ноде делает SNI-peek без терминации TLS: совпадение SNI → raw `copy_bidirectional` на NL exit, остальное → fallback HTML-заглушка. TLS handshake идёт end-to-end между телефоном и NL-сервером (v0.17.0+).
* **Управление сервером:**
  * HTTP Admin API на `10.7.0.1:8080` (через VPN-тоннель, Bearer token) — CRUD клиентов, подписки, conn_string, stats, live dest-log.
  * **Telegram-бот** (`tools/telegram-bot/`) — single-admin бот над admin API: добавить/удалить клиента, QR-код, подписки, enable/disable. При создании клиента выбирается роль admin/regular: для regular поле `admin` вырезается из conn_string перед отправкой.
* **Платформы:** Android (Kotlin + Compose, JNI через `libphantom_android.so`), Linux CLI, Server, RU-relay. iOS существовал в v0.15.4–v0.15.8 и был удалён из дерева.

### Замеры пропускной способности (v0.17.2, RU→NL hop)

| Сценарий | Download | Upload |
|---|---|---|
| Wired desktop через RU-relay | ~625 Mbit/s | — |
| Samsung Galaxy phone → NL direct | 205 Mbit/s | 75 Mbit/s |
| Samsung Galaxy phone → NL через RU-relay | 222 Mbit/s | 105 Mbit/s |

---

## Структура репозитория

```
phantom-vpn/
├── crates/
│   ├── core/               # общая библиотека (крипто, wire-формат, шейпинг, H.264 shaper)
│   ├── server/             # phantom-server + phantom-keygen
│   ├── relay/              # phantom-relay — RU SNI-passthrough
│   ├── client-common/      # TX/RX циклы, handshake, QUIC+H2 abstractions
│   ├── client-linux/       # Linux TUN CLI клиент
│   └── client-android/     # JNI → libphantom_android.so
├── android/                # Android-приложение (Kotlin + Jetpack Compose)
│   └── app/src/main/
│       ├── kotlin/com/ghoststream/vpn/  # UI, ViewModels, VpnService, парсинг профилей
│       └── jniLibs/arm64-v8a/           # собранный libphantom_android.so
├── tools/
│   └── telegram-bot/       # Python Telegram-бот для управления сервером
├── config/
│   ├── server.example.toml
│   └── client.example.toml
├── scripts/
│   ├── deploy.sh           # one-click деплой server на хост
│   ├── keys.py             # keyring management CLI
│   └── install.py          # первичная провижионка
└── .github/workflows/
    └── release.yml         # CI: Linux + Android APK + Server + phantom-keygen → GitHub Release
```

---

## Платформы и их статус

| Платформа | Статус | Описание |
|-----------|--------|----------|
| Android | ✅ Production | Compose UI, JNI, Foreground VPN Service, admin-панель, QR |
| Linux client | ✅ Production | CLI `phantom-client-linux` |
| Server | ✅ Production | `phantom-server` (vdsina NL exit) |
| RU relay | ✅ Production | `phantom-relay` (SNI passthrough) |
| macOS/iOS | ❌ Removed | Существовали в v0.10–v0.15, удалены из дерева (см. CHANGELOG) |

---

## Быстрый старт — сервер (Linux)

### 1. Сборка из исходников

```bash
git clone https://github.com/PatrickRedStar/phantom-vpn.git
cd phantom-vpn
cargo build --release -p phantom-server -p phantom-keygen
```

### 2. Готовые бинарники из GitHub Releases

Начиная с v0.18.2 в релизе публикуется не только Android APK и Linux client, но и **phantom-server** с **phantom-keygen**:

```
phantom-client-linux          # Linux CLI клиент (x86_64)
phantom-server                # Сервер (x86_64)
phantom-keygen                # Генератор ключей (x86_64)
app-debug.apk                 # Android APK (arm64)
```

### 3. Первый запуск

```bash
# Сгенерировать ключи
./target/release/phantom-keygen

# Отредактировать config/server.toml (см. config/server.example.toml)
sudo ./target/release/phantom-server -c /etc/phantom-vpn/server.toml
```

### 4. One-click deploy (рекомендуется)

```bash
bash ./scripts/deploy.sh root@<server-host> ~/.ssh/personal
```

Деплой собирает `phantom-server` + `phantom-keygen` локально, заливает в `/opt/phantom-vpn/`, ставит systemd-юнит `phantom-server.service` и запускает сервис. Подробности — в `scripts/deploy.sh`.

---

## Быстрый старт — Android клиент

1. Скачать APK из [последнего GitHub Release](https://github.com/PatrickRedStar/phantom-vpn/releases).
2. Установить: `adb install app-debug.apk` или открыть файл на телефоне.
3. Получить строку подключения от админа сервера (см. ниже про бота).
4. В приложении: **Settings → Import profile → Paste** или **Scan QR**.
5. Нажать **Connect**.

Приложение поддерживает:
- Импорт через QR и текстовую строку (base64url JSON)
- Мульти-профиль (несколько серверов)
- Настраиваемый split-routing (per-country/per-CIDR)
- Per-app bypass/include
- Встроенную admin-панель для админских клиентов (ключ передаётся в conn_string)
- Debug share: версия + логи + конфиг в один файл

---

## Быстрый старт — Linux клиент

```bash
# Собрать или скачать phantom-client-linux
cargo build --release -p phantom-client-linux

# Отредактировать config/client.toml (см. client.example.toml)
sudo ./target/release/phantom-client-linux -c /etc/phantom-vpn/client.toml -vv
```

Транспорт задаётся в конфиге: `transport = "h2"` (рекомендуется), `"quic"` или `"auto"`.

---

## Admin HTTP API

Сервер поднимает HTTP API на туннельном интерфейсе (`10.7.0.1:8080` по умолчанию). Доступен **только через активный VPN-тоннель** — извне закрыт. Авторизация: `Authorization: Bearer <token>` из `[admin]` секции `server.toml`.

Полный список эндпоинтов (GET/POST/DELETE), схемы запросов и ответов описаны в [CLAUDE.md](CLAUDE.md). Краткая сводка:

| Путь | Что делает |
|---|---|
| `GET /api/status` | Uptime, активные сессии, exit IP |
| `GET /api/clients` | Список клиентов со статусом и трафиком |
| `POST /api/clients` | Создать клиента (cert + key + conn_string) |
| `DELETE /api/clients/:name` | Удалить клиента |
| `POST /api/clients/:name/enable\|disable` | Временно включить/отключить |
| `POST /api/clients/:name/subscription` | extend / set / cancel / revoke подписки |
| `GET /api/clients/:name/conn_string` | Base64url JSON строка подключения |
| `GET /api/clients/:name/stats` | Time-series трафика |
| `GET /api/clients/:name/logs` | Последние dst-запросы (с DNS-кэшем для hostname) |

---

## Telegram-бот для управления

В `tools/telegram-bot/` лежит Python-бот, обёрнутый в Docker. Работает только с одним Telegram ID (админом), сам ходит в admin API через `network_mode: host`.

**Функциональность:**
- 👥 Список клиентов с онлайн-статусом и днями подписки
- ➕ Добавить клиента (через ConversationHandler): роль Admin/Regular → имя → срок → получить карточку + QR + conn_string
- 📱 Отдельные QR и 🔗 текстовая строка
- ⏯ Enable/Disable
- ⏰ Управление подпиской: `+7д`, `+30д`, `+90д`, `=30/90/365д`, бессрочно, отозвать
- 🗑 Удаление с подтверждением

**Роль Regular:** бот вырезает поле `admin` из conn_string перед отправкой, чтобы телефон не получил admin token сервера. Роли хранятся локально в `data/roles.json`, на сервере никаких изменений не требуется.

**Развёртывание:**

```bash
cd tools/telegram-bot
cp .env.example .env
# отредактировать .env: BOT_TOKEN, ADMIN_TELEGRAM_ID, PHANTOM_ADMIN_TOKEN
chmod 600 .env

docker compose build
docker compose up -d
docker logs -f phantom-telegram-bot
```

Подробнее — `tools/telegram-bot/README.md`.

---

## Connection String

Base64url-кодированный JSON. Формат:

```json
{
  "v": 1,
  "addr": "server.example.com:443",
  "sni":  "server.example.com",
  "tun":  "10.7.0.2/24",
  "cert": "-----BEGIN CERTIFICATE-----\n...",
  "key":  "-----BEGIN PRIVATE KEY-----\n...",
  "ca":   "-----BEGIN CERTIFICATE-----\n...",       // optional
  "transport": "h2",                                  // "h2" | "quic" | "auto"
  "admin": {                                          // только для admin-клиентов
    "url":   "http://10.7.0.1:8080",
    "token": "..."
  }
}
```

Парсер: `android/app/src/main/kotlin/.../data/ConnStringParser.kt`.
Генератор: `crates/server/src/admin.rs::build_conn_string()`.

Поле `admin` — опциональное. Бот для regular-клиентов вырезает его → такой клиент подключится к VPN, но панель управления в приложении будет скрыта.

---

## Конфиги

### Сервер — `config/server.toml`

```toml
listen_addr   = "0.0.0.0:8443"          # H2 TLS listener (часто за nginx SNI-router на 443)
tun_addr      = "10.7.0.1/24"
wan_iface     = "ens3"
server_private_key = "..."
server_public_key  = "..."
cert_subjects = ["89.110.109.128", "vpn.example.com"]

[admin]
listen_addr  = "10.7.0.1:8080"
token        = "<random-32-bytes-hex>"
clients_path = "/opt/phantom-vpn/config/clients.json"
ca_cert_path = "/opt/phantom-vpn/config/ca.crt"
ca_key_path  = "/opt/phantom-vpn/config/ca.key"
admin_url    = "http://10.7.0.1:8080"
```

### Клиент Linux — `/etc/phantom-vpn/client.toml`

```toml
server_addr = "server.example.com:443"
server_name = "server.example.com"
insecure    = true                       # false если есть CA
transport   = "h2"                       # "h2" | "quic" | "auto"
tun_addr    = "10.7.0.2/24"
tun_mtu     = 1350
default_gw  = "10.7.0.1"
client_private_key = "..."
client_public_key  = "..."
server_public_key  = "..."
```

---

## Сборка Android (локально)

```bash
export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android
cp target/aarch64-linux-android/release/libphantom_android.so \
   android/app/src/main/jniLibs/arm64-v8a/

cd android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon
# APK: android/app/build/outputs/apk/debug/app-debug.apk
```

---

## Документация

| Файл | Что там |
|---|---|
| [README.md](README.md) | Этот файл — обзор проекта |
| [CHANGELOG.md](CHANGELOG.md) | История версий v0.3 → v0.18.2 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Текущая архитектура + исторический анализ производительности |
| [ROADMAP.md](ROADMAP.md) | Таблица версий с замерами + план на будущее |
| [CLAUDE.md](CLAUDE.md) | Подробная операционная документация (для контрибьюторов и AI-агентов) |
| [ANALYZE.md](ANALYZE.md) | Исторический внешний аудит (2025, QUIC era) |
| [ANALYZE_RESPONSE.md](ANALYZE_RESPONSE.md) | Ответ на аудит с результатами оптимизаций |
| [other_docs/PLAN_v2_transport.md](other_docs/PLAN_v2_transport.md) | Исторический план миграции с QUIC на HTTP/2 (все фазы выполнены) |
| [tools/telegram-bot/README.md](tools/telegram-bot/README.md) | Telegram-бот |

---

## Лицензия

Проект исследовательский. Используйте на свой страх и риск — DPI-маскировка и обход блокировок могут нарушать ToS провайдера или местное законодательство.
