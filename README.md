# PhantomVPN / GhostStream 👻

> Версия репозитория: последний тег (`git tag --sort=-v:refname | head -1`) и [CHANGELOG.md](CHANGELOG.md) · транспорт: **HTTP/2 + TLS 1.3 over TCP (единственный)**

PhantomVPN (бренд Android-приложения — **GhostStream**) — кастомный VPN-протокол, маскирующий трафик под обычный HTTPS/gRPC, чтобы устойчиво обходить DPI и ТСПУ.

Изначально (`v0.3–v0.14`) протокол строился вокруг QUIC/H3 и шейпинга под H.264 видеозвонок. После того как ТСПУ стал дросселить QUIC/UDP на потребительских каналах до ~80 Mbps, начиная с **v0.15** был добавлен параллельный транспорт на TCP/TLS + HTTP/2, который и стал основным для мобильных клиентов. Историческая плановая запись — [`other_docs/PLAN_v2_transport.md`](other_docs/PLAN_v2_transport.md); актуальная архитектура — [docs/knowledge/](docs/knowledge/README.md).

---

## Что есть сейчас

* **Транспорт:** TLS 1.3 + HTTP/2 поверх TCP, мультистрим с flow-affine hash-раскладкой по стримам. N стримов = числу ядер (2–16), каждый в своём батч-цикле (download с одного клиента 138→625 Mbit/s, v0.17.2). QUIC полностью удалён в v0.19.x (ТСПУ дросселировал UDP до ~80 Mbps).
* **Auth:** **mTLS** (клиентский cert = identity, fingerprint сверяется с allowlist прямо в TLS-рукопожатии; отозванный клиент получает алерт `certificate_revoked` и видит «Доступ отозван»). Noise IK был в v0.3–v0.4, удалён в opt-v4 в пользу mTLS.
* **Переподключение:** ядро ретраит бесконечно, умерший стрим переоткрывается один, ошибка — только когда нужно действие пользователя ([ADR 0018](docs/knowledge/decisions/0018-rust-owns-reconnect.md)).
* **Сессии:** `SessionCoordinator` на клиента (индекс по fingerprint), N открытых TLS-стримов → `attach_stream`/`detach_stream_if`. Multi-stream handshake negotiation + zombie session eviction в v0.18.1.
* **DPI-маскировка:**
  * **Паддинг первых 10–20 кадров** каждого стрима до случайного размера на обеих сторонах — первые записи не повторяют размеры SYN/ClientHello/DNS.
  * **Heartbeat-кадры** на idle-стримах: клиент раз в 30–60 с, сервер раз в 30–40 с, 40–200 B с sentinel-версией `0x0`, несинхронно между стримами.
  * **Fallback без клиентского серта** — сервер отвечает как обычный H2-сайт (fakeapp); `CertificateRequest` не называет CA; клиент предлагает ALPN `h2, http/1.1`, как браузер.
* **RU relay** — `phantom-relay` на RU-ноде читает ClientHello без терминации TLS: совпадение SNI → сырой поток на NL exit `:8443`, остальное → ответ как у nginx. TLS handshake идёт end-to-end между телефоном и NL-сервером (v0.17.0+).
* **Управление сервером:**
  * Admin API: mTLS на `10.7.0.1:8080` (только через туннель, для клиентов с ролью `is_admin`) и plain HTTP + Bearer на `127.0.0.1:8081` (только с самого сервера, для бота) — CRUD клиентов, подписки, conn_string, stats, live dest-log; `/api/me` — свой срок и роль.
  * **Telegram-бот** (`tools/telegram-bot/`) — single-admin бот над admin API: добавить/удалить клиента, QR-код, подписки, enable/disable. Строки подключения и QR удаляются из чата через 10 минут, команды — только в личке.
* **Платформы:** Android (Kotlin + Compose, JNI через `libphantom_android.so`), iOS и macOS (SwiftUI + NEPacketTunnelProvider), Linux (CLI + Slint GUI), OpenWrt, Server, RU-relay. Общее ядро клиентов — `crates/client-core-runtime`.

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
├── crates/                 # Общие Rust-библиотеки
│   ├── core/               # wire-формат, TLS, tun_uring, transport policy
│   ├── client-common/      # TX/RX циклы, H2/TLS handshake
│   ├── client-core-runtime/ # единый tunnel runtime для всех клиентов
│   ├── client-android/     # JNI → libphantom_android.so
│   ├── client-apple/       # FFI для iOS/macOS
│   └── gui-ipc/            # wire-типы GUI ↔ helper (StatusFrame, LogFrame…)
├── server/
│   ├── server/             # phantom-server + phantom-keygen
│   ├── relay/              # phantom-relay — RU SNI-passthrough
│   ├── config/             # server.example.toml
│   └── scripts/            # deploy.sh, deploy-relay.sh, keys.py, check-cert.sh
├── apps/
│   ├── android/            # Kotlin + Jetpack Compose
│   │   └── app/src/main/kotlin/com/ghoststream/vpn   # .so собирает gradle, в git его нет
│   ├── ios/                # SwiftUI + NEPacketTunnelProvider + PhantomKit
│   ├── macos/              # SwiftUI + NEPacketTunnelProvider + system extension
│   ├── linux/              # cli + gui (Slint) + helper
│   ├── openwrt/            # netifd proto + LuCI UI
│   └── windows/            # Slint GUI (полный код — в ветке feature/windows-client)
├── docker/                 # server + relay: pull-and-go (ADR 0010)
├── docs/knowledge/         # ADR, инварианты, платформы, инциденты, глоссарий
├── tools/
│   ├── ship-android.sh     # локальный Android-билд + install (Unix-хост)
│   └── telegram-bot/       # Python Telegram-бот для управления сервером
└── .github/workflows/
    ├── ci.yml              # cargo test + cargo audit на push в master
    └── release.yml         # CI: Linux CLI/GUI + Android + Server + macOS + OpenWrt → GitHub Release
```

---

## Платформы и их статус

| Платформа | Статус | Описание |
|-----------|--------|----------|
| Android | ✅ Production | Compose UI, JNI, Foreground VPN Service, admin-панель, QR |
| iOS | ✅ Production | SwiftUI + NEPacketTunnelProvider, PhantomKit |
| macOS | ✅ Production | SwiftUI + NEPacketTunnelProvider (system extension), .dmg в релизе |
| Linux client | ✅ Production | CLI `phantom-client-linux` + Slint GUI `ghoststream-gui` |
| OpenWrt | ✅ Production | netifd proto + LuCI UI |
| Windows | 🚧 На ветке | Slint GUI `ghoststream-windows` + `crates/client-windows-core` в `feature/windows-client`; в master не влит |
| Server | ✅ Production | `phantom-server` (vdsina NL exit) |
| RU relay | ✅ Production | `phantom-relay` (SNI passthrough) |

---

## Быстрый старт — сервер (Linux)

### 1. Docker (основной путь)

`docker/server/` (exit) и `docker/relay/` (реле) — `cp .env.example .env`, `docker login ghcr.io`, `docker compose up -d`. Exit стартует только с Let's Encrypt-сертом на своё имя и слушает `:8443`. Подробно — [docker/README.md](docker/README.md) и [ADR 0010](docs/knowledge/decisions/0010-docker-deploy.md).

### 2. Сборка из исходников

```bash
git clone https://github.com/PatrickRedStar/phantom-vpn.git
cd phantom-vpn
cargo build --locked --profile release-server -p phantom-server   # phantom-server + phantom-keygen в target/release-server/
```

Серверные бинари собираются профилем `release-server` (`panic = "unwind"`: паника в одном соединении не роняет процесс).

### 3. Готовые бинарники из GitHub Releases

По тегу `v*` CI собирает и публикует:

```
phantom-client-linux                  # Linux CLI клиент (x86_64)
ghoststream-linux-gui-x86_64.tar.gz   # Linux GUI
phantom-server                        # Сервер (x86_64)
phantom-keygen                        # Генератор ключей (x86_64)
app-release.apk                       # Android APK (arm64-v8a + armeabi-v7a)
GhostStream-*-macOS.dmg               # macOS
openwrt-{aarch64,armv7,x86_64,mipsel} # OpenWrt
```

### 4. Bare-metal deploy

```bash
# CA + серверный ключ (существующие файлы не перезаписываются)
phantom-keygen --out /opt/phantom-vpn/config --server-name <SNI>
# server.toml — по server/config/server.example.toml ([h2] :8443, [tls] с LE, allowlist)

bash ./server/scripts/deploy.sh vdsina ~/.ssh/personal
```

`deploy.sh` собирает `--profile release-server`, кладёт бинари в `/opt/phantom-vpn/` рядом с прежними (`.prev`), ставит systemd-юнит с sandboxing, ждёт порт и NAT-правило и сам откатывается при неудаче. Продление LE-серта требует `renew_hook` с рестартом — см. [build.md](docs/knowledge/build.md).

---

## Быстрый старт — Android клиент

1. Скачать APK из [последнего GitHub Release](https://github.com/PatrickRedStar/phantom-vpn/releases).
2. Установить: `adb install app-release.apk` или открыть файл на телефоне.
3. Получить строку подключения от админа сервера (см. ниже про бота).
4. В приложении: **Settings → Import profile → Paste** или **Scan QR**.
5. Нажать **Connect**.

Приложение поддерживает:
- Импорт строки `ghs://` через QR или вставкой
- Мульти-профиль (несколько серверов), реле как отдельная настройка профиля
- Настраиваемый split-routing (per-country/per-CIDR)
- Per-app bypass/include
- Плитку в шторке быстрых настроек и виджеты рабочего стола
- Встроенную admin-панель для клиентов с ролью `is_admin` (роль — на сервере, не в строке)
- Debug share: версия + логи + конфиг в один файл

---

## Быстрый старт — Linux клиент

```bash
# Собрать или скачать phantom-client-linux
cargo build --release -p phantom-client-linux

# Только строка подключения ghs:// (TOML-конфиг рантаймом не поддерживается)
sudo ./target/release/phantom-client-linux --conn-string-file /etc/phantom-vpn/conn_string -vv
```

Транспорт — HTTP/2 over TLS, других вариантов нет.

---

## Admin HTTP API

Сервер поднимает два listener'а: mTLS на туннельном интерфейсе (`10.7.0.1:8080`, **только через активный VPN-тоннель**, доступ — по роли `is_admin` клиентского серта) и plain HTTP на `127.0.0.1:8081` с `Authorization: Bearer <token>` из `[admin]` — только с самого сервера, для бота. Подробно — [admin-api.md](docs/knowledge/architecture/admin-api.md).

Реализация и полный список эндпоинтов — `server/server/src/admin.rs`. Краткая сводка:

| Путь | Что делает |
|---|---|
| `GET /api/me` | Своё имя, `is_admin`, `enabled`, `expires_at` (для любого клиента) |
| `GET /api/status` | Uptime, активные сессии, exit IP |
| `GET /api/clients` | Список клиентов со статусом и трафиком |
| `POST /api/clients` | Создать клиента (cert + key + conn_string) |
| `DELETE /api/clients/:name` | Удалить клиента |
| `POST /api/clients/:name/enable\|disable` | Временно включить/отключить |
| `POST /api/clients/:name/subscription` | extend / set / cancel / revoke подписки |
| `GET /api/clients/:name/conn_string` | Строка подключения `ghs://` |
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

**Безопасность:** в каждой строке подключения лежит бессрочный приватный ключ клиента, поэтому бот удаляет сообщения со строкой и QR через 10 минут и принимает команды только в личке от админа. Роль админа — флаг `is_admin` на сервере, а не поле строки.

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

URL-формат ([ADR 0004](docs/knowledge/decisions/0004-ghs-url-conn-string.md)):

```
ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<server_name>&tun=<cidr>&v=1
```

`host:port` — точка входа (реле или exit), `sni` — имя exit'а. В строке нет CA,
admin-токена и `insecure`: серт сервера проверяется всегда, роль админа и
подписка — на сервере (`/api/me`).

Парсеры: `crates/client-common/src/helpers.rs::parse_conn_string` (Rust) и `ConnStringParser.kt` (Android), общие тестовые векторы.
Генератор: `server/server/src/admin.rs::build_conn_string()`.

---

## Конфиги

### Сервер — `server.toml` (пример: [server/config/server.example.toml](server/config/server.example.toml))

```toml
[network]
tun_name    = "tun1"
tun_addr    = "10.7.0.1/24"
wan_iface   = "eth0"
public_addr = "<реле или exit>:<порт>"     # host:port в ghs:// ссылках
server_name = "tls.nl2.example.com"        # SNI в ghs:// ссылках

[h2]
listen_addr = "0.0.0.0:8443"

[tls]                                      # старое имя [quic] тоже читается
cert_path = "/etc/letsencrypt/live/<SNI>/fullchain.pem"
key_path  = "/etc/letsencrypt/live/<SNI>/privkey.pem"
ca_cert_path         = "/opt/phantom-vpn/config/ca.crt"        # CA клиентских сертов
allowed_clients_path = "/opt/phantom-vpn/config/clients.json"  # allowlist, fail-closed

[admin]
listen_addr     = "10.7.0.1:8080"          # mTLS, только через туннель
bot_listen_addr = "127.0.0.1:8081"         # Bearer, только с loopback
token           = "<openssl rand -hex 32>"
```

Клиентам конфиг-файл не нужен — только строка `ghs://`.

---

## Сборка Android (локально)

Рекомендуемый путь (Unix-хост) — один скрипт собирает Rust + Kotlin и ставит APK на устройство:

```bash
bash ./tools/ship-android.sh
```

Вручную — только gradle: `preBuild` сам вызывает `buildRustAndroid` (`cargo ndk`
под `arm64-v8a` и `armeabi-v7a`), `.so` в git не хранится. Нужны `cargo-ndk`, NDK
и rustup-таргеты `aarch64-linux-android`, `armv7-linux-androideabi`.

```bash
cd apps/android && ./gradlew assembleDebug --no-daemon
# APK: apps/android/app/build/outputs/apk/debug/app-debug.apk
```

---

## Документация

| Файл | Что там |
|---|---|
| [README.md](README.md) | Этот файл — обзор проекта |
| [CHANGELOG.md](CHANGELOG.md) | История версий |
| [docs/knowledge/](docs/knowledge/README.md) | Карта проекта: архитектура, ADR, платформы, инциденты, глоссарий |
| [docs/knowledge/build.md](docs/knowledge/build.md) | Сборка, деплой, релиз |
| [docs/knowledge/troubleshooting.md](docs/knowledge/troubleshooting.md) | Ошибки и странное поведение |
| [CLAUDE.md](CLAUDE.md) | Операционная документация (для контрибьюторов и AI-агентов) |
| [other_docs/PLAN_v2_transport.md](other_docs/PLAN_v2_transport.md) | Исторический план миграции с QUIC на HTTP/2 (QUIC полностью удалён в v0.19.x) |
| [tools/telegram-bot/README.md](tools/telegram-bot/README.md) | Telegram-бот |

---

## Лицензия

Проект исследовательский. Используйте на свой страх и риск — DPI-маскировка и обход блокировок могут нарушать ToS провайдера или местное законодательство.
