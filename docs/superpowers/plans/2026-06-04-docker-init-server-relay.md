# GhostStream Docker Init — phantom-server + phantom-relay

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать pull-and-go развёртывание server и relay через Docker — `docker compose up -d` на чистом хосте поднимает работающий узел; если в volume `./config` есть готовый бэкап — новый сервер обслуживает старых клиентов с новым IP.

**Architecture:** Два независимых compose-проекта (`docker/server/` и `docker/relay/` — разные физические хосты). Каждый образ multi-stage: `rust:1.83-bookworm` builder → `debian:bookworm-slim` runtime. State полностью в bind-mount `./config`. Entrypoint при первом старте делает self-bootstrap (вызывает `phantom-keygen`, генерирует `server.toml` из env-vars, пишет пустой `clients.json`); при последующих запусках просто стартует бинарь. User management остаётся через `keys.py`, доступен как `docker exec -it phantom-server keys`. Server использует `network_mode: host` (обязательно для iptables NAT, который бинарь делает сам); relay в bridge с пробросом порта.

**Tech Stack:** Docker, docker-compose v2, Bash, multi-stage Rust builds, GitHub Actions buildx (multi-arch amd64+arm64), ghcr.io.

---

## File Structure

```
docker/
  server/
    Dockerfile               # multi-stage rust→debian-slim
    entrypoint.sh            # self-bootstrap + exec phantom-server
    compose.example.yml      # network_mode: host, /dev/net/tun, /config volume
    .env.example             # SERVER_NAME, WAN_IFACE, ADMIN_TOKEN
    README.md                # pull-and-go + restore-from-backup
  relay/
    Dockerfile               # multi-stage, без caps
    entrypoint.sh            # копирует example→relay.toml если нет, exec phantom-relay
    compose.example.yml      # bridge, :443:443
    .env.example             # UPSTREAM_ADDR, EXPECTED_SNI
    README.md
  README.md                  # обзор docker/, ссылки на server/ и relay/
.dockerignore                 # exclude target/, .git/, apps/, mobile artifacts
.github/workflows/docker.yml  # build & push на ghcr.io по тэгу v*
```

**Что не создаём (YAGNI):**
- Никаких backup-sidecar контейнеров (бэкап — tar+scp руками, см. README).
- Никаких health-check sidecar'ов (есть `restart: unless-stopped`).
- Не трогаем `server/scripts/install.py` (он legacy QUIC, для bare-metal случая остаётся как есть).
- Не пишем native Rust CLI `phantom-server users` — это отдельная будущая задача (гибрид: keys.py остаётся в образе).

---

## Task 1: Скаффолд `docker/` и `.dockerignore`

**Files:**
- Create: `docker/README.md`
- Create: `.dockerignore`

- [ ] **Step 1: Создать корневой `docker/README.md`**

Файл `/Users/p.kurkin/ghoststream/docker/README.md`:

```markdown
# GhostStream Docker

Два образа для быстрого развёртывания узлов GhostStream.

| Роль | Каталог | Назначение |
|---|---|---|
| **server** | [server/](server/) | NL exit: H2/TLS listener :443 + TUN + NAT. Требует root caps. |
| **relay** | [relay/](relay/) | RU SNI-passthrough :443. Никаких caps, чистый TCP. |

Pull-and-go на новом хосте:

```sh
git clone https://github.com/<org>/ghoststream.git
cd ghoststream/docker/server   # или docker/relay
cp .env.example .env
$EDITOR .env                    # выставить SERVER_NAME / UPSTREAM_ADDR
docker compose up -d
```

Восстановление из бэкапа (тот же docker compose, но с готовым state):

```sh
mkdir -p ./config
tar xzf phantom-state-backup.tar.gz -C ./config --strip-components=1
docker compose up -d            # подхватит существующие ca.crt / clients.json
```

Подробности в [server/README.md](server/README.md) и [relay/README.md](relay/README.md).
```

- [ ] **Step 2: Создать `.dockerignore` в корне репо**

Файл `/Users/p.kurkin/ghoststream/.dockerignore`:

```
target/
.git/
.github/
apps/
docs/
crates/client-android/
crates/client-apple/
crates/client-linux/
crates/client-core-runtime/
crates/gui-ipc/
tools/
**/*.md
**/.DS_Store
```

Это уменьшает build context до минимума: Docker build будет видеть только то что нужно для компиляции server+relay (`crates/core`, `crates/client-common`, `server/server`, `server/relay`).

- [ ] **Step 3: Проверить что build context разумного размера**

Команда:
```sh
cd /Users/p.kurkin/ghoststream
tar --exclude-from=.dockerignore -czf /tmp/ctx.tgz . 2>/dev/null
ls -lh /tmp/ctx.tgz
rm /tmp/ctx.tgz
```

Ожидаемо: < 5 МБ. Если больше — проверить `.dockerignore`, скорее всего что-то пропущено.

- [ ] **Step 4: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/README.md .dockerignore
git commit -m "docker: scaffold docker/ + .dockerignore"
```

---

## Task 2: Dockerfile для phantom-server (multi-stage)

**Files:**
- Create: `docker/server/Dockerfile`

- [ ] **Step 1: Написать `docker/server/Dockerfile`**

Файл `/Users/p.kurkin/ghoststream/docker/server/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.6

# ─── Builder ──────────────────────────────────────────────────────────────────
FROM rust:1.83-bookworm AS builder

WORKDIR /src

# Системные зависимости для сборки (rustls/ring чистый, openssl-sys не нужен)
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        clang \
        cmake \
    && rm -rf /var/lib/apt/lists/*

# Скопировать только то что нужно для server-сборки.
# crates/client-* и apps/ исключены через .dockerignore, но дублируем для надёжности.
COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY server/ server/

# Сборка только server crate, без всего workspace.
RUN cargo build --release \
        -p phantom-server \
        --bin phantom-server \
        --bin phantom-keygen

# ─── Runtime ──────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# iptables/ip — phantom-server вызывает их сам (sysctl ip_forward + MASQUERADE + FORWARD).
# python3 — для keys.py (управление пользователями через `docker exec`).
# tini — корректный PID 1 + reaping.
RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables \
        iproute2 \
        procps \
        python3-minimal \
        tini \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Установка бинарей
COPY --from=builder /src/target/release/phantom-server /usr/local/bin/phantom-server
COPY --from=builder /src/target/release/phantom-keygen /usr/local/bin/phantom-keygen

# keys.py + alias для docker exec
COPY server/scripts/keys.py /opt/phantom-vpn/keys.py
RUN chmod +x /opt/phantom-vpn/keys.py \
    && ln -s /opt/phantom-vpn/keys.py /usr/local/bin/keys

# Стандартный пример конфига внутри образа — entrypoint скопирует если /config пуст
COPY server/config/server.example.toml /opt/phantom-vpn/server.example.toml

# Entrypoint c self-bootstrap
COPY docker/server/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /config — bind-mount point для state
VOLUME ["/config"]

EXPOSE 443/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: Тестовая локальная сборка (без push) на linux/amd64**

> На macOS: `docker buildx build --platform linux/amd64 ...` (заходит в QEMU, медленно — ~10 мин первая сборка, в следующих кэшируется).
> На самом Linux-хосте: `docker build .` работает напрямую.

Команда:
```sh
cd /Users/p.kurkin/ghoststream
docker buildx build --platform linux/amd64 \
    -f docker/server/Dockerfile \
    -t ghoststream-server:dev \
    --load \
    .
```

Ожидаемо: успешный билд, на выходе `ghoststream-server:dev` в локальном docker. Размер runtime-стадии: ~150-200 МБ.

Если падает на `cargo build`: проверить что .dockerignore не отрезал нужный crate. Если падает в runtime stage на `apt-get` — проверить порядок строк.

- [ ] **Step 3: Проверить что бинари внутри образа работают**

```sh
docker run --rm ghoststream-server:dev phantom-server --help
docker run --rm ghoststream-server:dev phantom-keygen --help
docker run --rm ghoststream-server:dev keys --help
```

Ожидаемо: каждая команда печатает usage без ошибок.

- [ ] **Step 4: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/server/Dockerfile
git commit -m "docker(server): multi-stage Dockerfile with phantom-server + keys.py"
```

---

## Task 3: Entrypoint для server с self-bootstrap

**Files:**
- Create: `docker/server/entrypoint.sh`

- [ ] **Step 1: Написать `docker/server/entrypoint.sh`**

Файл `/Users/p.kurkin/ghoststream/docker/server/entrypoint.sh`:

```sh
#!/bin/sh
# phantom-server entrypoint
#
# Bootstrap policy:
#   - Если /config/server.toml существует — стартуем как есть (восстановление из бэкапа).
#   - Если /config/server.toml нет — генерируем fresh state: CA + server-cert,
#     рендерим server.toml из шаблона с подстановкой ENV (SERVER_NAME, WAN_IFACE,
#     ADMIN_TOKEN), пишем пустой clients.json.

set -eu

CONFIG_DIR="${CONFIG_DIR:-/config}"
SERVER_TOML="${CONFIG_DIR}/server.toml"
CA_CRT="${CONFIG_DIR}/ca.crt"
CLIENTS_JSON="${CONFIG_DIR}/clients.json"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$SERVER_TOML" ]; then
    echo "[bootstrap] $SERVER_TOML missing — running first-boot setup"

    if [ -z "${SERVER_NAME:-}" ]; then
        echo "[bootstrap] FATAL: SERVER_NAME env var must be set on first boot (TLS SNI / cert CN)" >&2
        echo "[bootstrap]        Either set it in .env or place a prepared server.toml into ./config/" >&2
        exit 1
    fi

    WAN_IFACE="${WAN_IFACE:-eth0}"
    TUN_NAME="${TUN_NAME:-tun1}"
    TUN_ADDR="${TUN_ADDR:-10.7.0.1/24}"
    LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:443}"
    ADMIN_LISTEN="${ADMIN_LISTEN:-10.7.0.1:8080}"

    if [ -z "${ADMIN_TOKEN:-}" ]; then
        ADMIN_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        echo "[bootstrap] Generated ADMIN_TOKEN: $ADMIN_TOKEN"
        echo "[bootstrap] Save it — it lets you call the admin API via VPN tunnel."
    fi

    if [ ! -f "$CA_CRT" ]; then
        echo "[bootstrap] Generating CA + server certificate via phantom-keygen"
        phantom-keygen --out "$CONFIG_DIR" --server-name "$SERVER_NAME"
    else
        echo "[bootstrap] CA already in $CONFIG_DIR — keeping it, only regenerating server.toml"
    fi

    if [ ! -f "$CLIENTS_JSON" ]; then
        echo '{"clients":{}}' > "$CLIENTS_JSON"
        echo "[bootstrap] Wrote empty $CLIENTS_JSON"
    fi

    cat > "$SERVER_TOML" <<EOF
# Generated by docker entrypoint on first boot.
# Safe to edit; container will not overwrite once this file exists.

[network]
listen_addr = "${LISTEN_ADDR}"
tun_name    = "${TUN_NAME}"
tun_addr    = "${TUN_ADDR}"
tun_mtu     = 1350
wan_iface   = "${WAN_IFACE}"

[timeouts]
idle_timeout_secs = 300
hard_timeout_secs = 86400

[quic]
cert_subjects        = ["${SERVER_NAME}"]
ca_cert_path         = "${CA_CRT}"
allowed_clients_path = "${CLIENTS_JSON}"
idle_timeout_secs    = 30

[admin]
listen_addr  = "${ADMIN_LISTEN}"
token        = "${ADMIN_TOKEN}"
ca_cert_path = "${CA_CRT}"
ca_key_path  = "${CONFIG_DIR}/ca.key"
EOF

    echo "[bootstrap] Wrote $SERVER_TOML"
    echo "[bootstrap] First client: docker exec -it phantom-server keys"
else
    echo "[entrypoint] Found existing $SERVER_TOML — skipping bootstrap"
fi

exec phantom-server -c "$SERVER_TOML"
```

- [ ] **Step 2: Локальный smoke-тест bootstrap (без TUN, ожидаем падение на TUN-стадии)**

```sh
mkdir -p /tmp/gs-test/config
docker run --rm \
    -e SERVER_NAME=test.example.com \
    -v /tmp/gs-test/config:/config \
    ghoststream-server:dev 2>&1 | head -30
```

Ожидаемо: видим строки `[bootstrap] Generating CA...`, `[bootstrap] Wrote /config/server.toml`, потом phantom-server упадёт на попытке открыть TUN (это нормально — мы не дали ему `--cap-add NET_ADMIN`). Главное: bootstrap отработал.

Проверить state:
```sh
ls /tmp/gs-test/config
```

Ожидаемо: `ca.crt`, `ca.key`, `server.crt`, `server.key`, `server.toml`, `clients.json`.

- [ ] **Step 3: Второй запуск — должен пропустить bootstrap**

```sh
docker run --rm \
    -v /tmp/gs-test/config:/config \
    ghoststream-server:dev 2>&1 | head -5
```

Ожидаемо: `[entrypoint] Found existing /config/server.toml — skipping bootstrap` и попытка стартовать сервер (опять падение на TUN — нормально).

Cleanup:
```sh
rm -rf /tmp/gs-test
```

- [ ] **Step 4: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/server/entrypoint.sh
git commit -m "docker(server): entrypoint with first-boot bootstrap (CA + server.toml)"
```

---

## Task 4: compose.example.yml + .env.example для server

**Files:**
- Create: `docker/server/compose.example.yml`
- Create: `docker/server/.env.example`

- [ ] **Step 1: Написать `docker/server/compose.example.yml`**

Файл `/Users/p.kurkin/ghoststream/docker/server/compose.example.yml`:

```yaml
# phantom-server compose
#
# Usage:
#   cp compose.example.yml compose.yml
#   cp .env.example .env
#   $EDITOR .env                # set SERVER_NAME
#   docker compose up -d
#
# Restore from backup:
#   mkdir -p ./config
#   tar xzf phantom-state.tar.gz -C ./config --strip-components=1
#   docker compose up -d        # entrypoint detects existing server.toml, skips bootstrap

services:
  phantom-server:
    # ghcr.io image by default; switch to build: ../.. when iterating locally.
    image: ghcr.io/${GHCR_OWNER:-ghoststream}/ghoststream-server:${TAG:-latest}
    # build:
    #   context: ../..
    #   dockerfile: docker/server/Dockerfile
    container_name: phantom-server
    restart: unless-stopped

    # NB: host network is required — phantom-server runs `iptables -t nat ... MASQUERADE`
    # against wan_iface, which must be a real host interface. Bridge networking would
    # write rules into a docker-private namespace that no outside traffic ever touches.
    network_mode: host

    # privileged + /dev/net/tun: tun_uring uses io_uring; iptables/sysctl need NET_ADMIN.
    # Можно сузить до cap_add: [NET_ADMIN, NET_RAW, SYS_ADMIN], но privileged проще
    # и эквивалентно для одного-процесса контейнера на dedicated VPS.
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun

    # State полностью в bind-mount. Бэкап: tar czf state.tgz ./config
    volumes:
      - ./config:/config

    environment:
      SERVER_NAME: ${SERVER_NAME}
      WAN_IFACE:   ${WAN_IFACE:-eth0}
      TUN_NAME:    ${TUN_NAME:-tun1}
      TUN_ADDR:    ${TUN_ADDR:-10.7.0.1/24}
      LISTEN_ADDR: ${LISTEN_ADDR:-0.0.0.0:443}
      ADMIN_TOKEN: ${ADMIN_TOKEN:-}

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **Step 2: Написать `docker/server/.env.example`**

Файл `/Users/p.kurkin/ghoststream/docker/server/.env.example`:

```sh
# phantom-server config (consumed by compose.yml on first boot)
#
# Required on FIRST boot only. Once /config/server.toml exists, env-vars are ignored.

# TLS server name / SNI. Должен совпадать с тем что клиенты увидят в ghs:// ссылке.
# Пример: nl2.bikini-bottom.com
SERVER_NAME=

# Image source (для pull из ghcr.io). Меняй на свой ник если форкаешь.
GHCR_OWNER=ghoststream
TAG=latest

# WAN-интерфейс хоста — куда MASQUERADE'нуть исходящий трафик.
# Проверь: `ip route show default | awk '{print $5}'`
WAN_IFACE=eth0

# Опционально — переопределить дефолты:
# TUN_NAME=tun1
# TUN_ADDR=10.7.0.1/24
# LISTEN_ADDR=0.0.0.0:443

# Admin API token. Оставь пустым — entrypoint сгенерит и распечатает в лог.
ADMIN_TOKEN=
```

- [ ] **Step 3: Проверить что compose валиден**

```sh
cd /Users/p.kurkin/ghoststream/docker/server
cp compose.example.yml compose.yml
cp .env.example .env
echo "SERVER_NAME=test.example.com" >> .env
docker compose config
```

Ожидаемо: docker compose печатает разрешённую конфигурацию с подставленными ENV без ошибок валидации. (Не `up`, только `config` — статическая проверка.)

Cleanup:
```sh
rm compose.yml .env
```

- [ ] **Step 4: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/server/compose.example.yml docker/server/.env.example
git commit -m "docker(server): compose.example + .env.example with host networking"
```

---

## Task 5: README для server

**Files:**
- Create: `docker/server/README.md`

- [ ] **Step 1: Написать `docker/server/README.md`**

Файл `/Users/p.kurkin/ghoststream/docker/server/README.md`:

```markdown
# phantom-server (Docker)

NL exit узел: H2/TLS listener :443 + TUN + NAT.

## Требования к хосту

- Linux kernel ≥ 5.10 (io_uring для tun_uring)
- Docker ≥ 20.10, docker-compose v2
- Открытый порт 443/tcp на публичном интерфейсе
- Свободное имя интерфейса `tun1` (`wg0` от WireGuard не мешает)

## Быстрый старт (свежий хост)

```sh
git clone https://github.com/<org>/ghoststream.git
cd ghoststream/docker/server
cp compose.example.yml compose.yml
cp .env.example .env
$EDITOR .env                          # выставить SERVER_NAME
docker compose up -d
docker compose logs -f phantom-server # увидеть ADMIN_TOKEN в bootstrap-логах
```

После старта в `./config/` лежит весь state: `ca.crt`, `ca.key`, `server.crt`, `server.key`, `server.toml`, `clients.json`.

## Создать первого клиента

```sh
docker exec -it phantom-server keys
```

Откроется интерактивное меню `keys.py`: `add client` → задать имя → получить `ghs://...` ссылку. Cert+key положатся в `./config/clients/<name>/`.

Просмотр / экспорт / отзыв — там же в меню.

## Восстановление со старого хоста

На старом сервере:
```sh
tar czf phantom-state-$(date +%F).tar.gz -C /var/lib/phantom-vpn config/
# или там где у тебя bind-mount: -C /path/to/docker/server config/
scp phantom-state-*.tar.gz new-host:~
```

На новом сервере:
```sh
git clone ... && cd ghoststream/docker/server
cp compose.example.yml compose.yml
cp .env.example .env                  # SERVER_NAME можно оставить пустым — bootstrap пропустится
mkdir -p ./config
tar xzf ~/phantom-state-*.tar.gz -C ./config --strip-components=1
docker compose up -d
```

Старые ghs:// ссылки клиентов продолжат работать (новый IP, тот же SNI, тот же CA, те же fingerprint'ы).

## Управление

| Действие | Команда |
|---|---|
| Логи | `docker compose logs -f phantom-server` |
| Рестарт | `docker compose restart` |
| Стоп | `docker compose down` |
| Обновить образ | `docker compose pull && docker compose up -d` |
| Шелл внутрь | `docker exec -it phantom-server sh` |
| keys меню | `docker exec -it phantom-server keys` |
| Бэкап state | `tar czf phantom-state.tgz ./config` |

## Troubleshooting

**`[bootstrap] FATAL: SERVER_NAME env var must be set`** — забыл прописать `SERVER_NAME=...` в `.env`, или забыл сделать `cp .env.example .env`.

**`iptables: command not found`** — Dockerfile должен ставить iptables в runtime стадии. Перепроверить что используется правильный образ (не distroless).

**Сервер стартует, но клиент не подключается** — проверь `WAN_IFACE`: имя интерфейса в `.env` должно совпадать с реальным `ip route show default`.

**`Address already in use`** — на хосте уже что-то слушает :443. Останови (nginx, другой VPN) или меняй `LISTEN_ADDR=0.0.0.0:8443` + поставь nginx-stream впереди.
```

- [ ] **Step 2: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/server/README.md
git commit -m "docker(server): README with pull-and-go + restore-from-backup"
```

---

## Task 6: Dockerfile для phantom-relay

**Files:**
- Create: `docker/relay/Dockerfile`

- [ ] **Step 1: Написать `docker/relay/Dockerfile`**

Файл `/Users/p.kurkin/ghoststream/docker/relay/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.6

# ─── Builder ──────────────────────────────────────────────────────────────────
FROM rust:1.83-bookworm AS builder

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        clang \
        cmake \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY server/ server/

RUN cargo build --release -p phantom-relay --bin phantom-relay

# ─── Runtime ──────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/phantom-relay /usr/local/bin/phantom-relay

# Пример конфига как seed для первого запуска
COPY server/relay/relay.example.toml /opt/phantom-relay/relay.example.toml

COPY docker/relay/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /config — bind-mount с relay.toml и опционально LE cert/key
VOLUME ["/config"]

# Не root: relay не нуждается в caps
RUN useradd -r -u 10001 -g nogroup relay
USER relay

EXPOSE 443/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 2: Тестовая сборка**

```sh
cd /Users/p.kurkin/ghoststream
docker buildx build --platform linux/amd64 \
    -f docker/relay/Dockerfile \
    -t ghoststream-relay:dev \
    --load \
    .
```

Ожидаемо: успешный билд. Размер runtime: ~80-100 МБ (нет python, нет iptables).

- [ ] **Step 3: Проверить бинарь**

```sh
docker run --rm ghoststream-relay:dev phantom-relay --help
```

Ожидаемо: usage без ошибок.

- [ ] **Step 4: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/relay/Dockerfile
git commit -m "docker(relay): multi-stage Dockerfile, non-root, minimal runtime"
```

---

## Task 7: Entrypoint, compose и README для relay

**Files:**
- Create: `docker/relay/entrypoint.sh`
- Create: `docker/relay/compose.example.yml`
- Create: `docker/relay/.env.example`
- Create: `docker/relay/README.md`

- [ ] **Step 1: Написать `docker/relay/entrypoint.sh`**

Файл `/Users/p.kurkin/ghoststream/docker/relay/entrypoint.sh`:

```sh
#!/bin/sh
# phantom-relay entrypoint
#
# Если /config/relay.toml нет — копируем шаблон и рендерим из ENV.
# Если есть — стартуем как есть.

set -eu

CONFIG_DIR="${CONFIG_DIR:-/config}"
RELAY_TOML="${CONFIG_DIR}/relay.toml"

mkdir -p "$CONFIG_DIR"

if [ ! -f "$RELAY_TOML" ]; then
    echo "[bootstrap] $RELAY_TOML missing — generating from env"

    if [ -z "${UPSTREAM_ADDR:-}" ]; then
        echo "[bootstrap] FATAL: UPSTREAM_ADDR must be set on first boot (e.g. nl2.example.com:443)" >&2
        exit 1
    fi
    if [ -z "${EXPECTED_SNI:-}" ]; then
        echo "[bootstrap] FATAL: EXPECTED_SNI must be set on first boot (e.g. relay.example.com)" >&2
        exit 1
    fi

    LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:443}"

    if [ -n "${FALLBACK_CERT:-}" ] && [ -n "${FALLBACK_KEY:-}" ]; then
        FALLBACK_BLOCK="cert_path = \"${FALLBACK_CERT}\"
key_path  = \"${FALLBACK_KEY}\""
    else
        FALLBACK_BLOCK="# fallback disabled — SNI mismatch drops the connection"
    fi

    cat > "$RELAY_TOML" <<EOF
# Generated by docker entrypoint on first boot.

listen_addr   = "${LISTEN_ADDR}"
upstream_addr = "${UPSTREAM_ADDR}"
expected_sni  = "${EXPECTED_SNI}"

${FALLBACK_BLOCK}
EOF
    echo "[bootstrap] Wrote $RELAY_TOML"
else
    echo "[entrypoint] Found existing $RELAY_TOML — skipping bootstrap"
fi

exec phantom-relay --config "$RELAY_TOML"
```

- [ ] **Step 2: Написать `docker/relay/compose.example.yml`**

Файл `/Users/p.kurkin/ghoststream/docker/relay/compose.example.yml`:

```yaml
services:
  phantom-relay:
    image: ghcr.io/${GHCR_OWNER:-ghoststream}/ghoststream-relay:${TAG:-latest}
    # build:
    #   context: ../..
    #   dockerfile: docker/relay/Dockerfile
    container_name: phantom-relay
    restart: unless-stopped

    # Bridge — relay чистый TCP proxy, никаких caps/devices не нужно.
    ports:
      - "443:443/tcp"

    volumes:
      - ./config:/config

    environment:
      UPSTREAM_ADDR: ${UPSTREAM_ADDR}
      EXPECTED_SNI:  ${EXPECTED_SNI}
      LISTEN_ADDR:   ${LISTEN_ADDR:-0.0.0.0:443}
      FALLBACK_CERT: ${FALLBACK_CERT:-}
      FALLBACK_KEY:  ${FALLBACK_KEY:-}

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

- [ ] **Step 3: Написать `docker/relay/.env.example`**

Файл `/Users/p.kurkin/ghoststream/docker/relay/.env.example`:

```sh
# phantom-relay config (first boot only)

GHCR_OWNER=ghoststream
TAG=latest

# Адрес NL exit (phantom-server). Включая порт.
# Пример: nl2.bikini-bottom.com:443
UPSTREAM_ADDR=

# SNI, который реальные клиенты шлют в ClientHello.
# Должен совпадать с SERVER_NAME сервера (cert у клиента подписан CN=$EXPECTED_SNI).
EXPECTED_SNI=

# Опционально:
# LISTEN_ADDR=0.0.0.0:443
# FALLBACK_CERT=/config/fullchain.pem
# FALLBACK_KEY=/config/privkey.pem
```

- [ ] **Step 4: Написать `docker/relay/README.md`**

Файл `/Users/p.kurkin/ghoststream/docker/relay/README.md`:

```markdown
# phantom-relay (Docker)

RU SNI-passthrough узел. Слушает :443, peek'ает SNI, форвардит к NL exit.

## Быстрый старт

```sh
cd ghoststream/docker/relay
cp compose.example.yml compose.yml
cp .env.example .env
$EDITOR .env                           # UPSTREAM_ADDR + EXPECTED_SNI
docker compose up -d
```

## Что в .env

| Переменная | Что |
|---|---|
| `UPSTREAM_ADDR` | NL exit `host:port`, куда форвардить совпадающий SNI |
| `EXPECTED_SNI` | Имя в ClientHello клиентов. Должно равняться SERVER_NAME у сервера |
| `FALLBACK_CERT/KEY` | Опционально: LE cert для fallback-HTML, если кто-то постучится без правильного SNI |

## State

Только `relay.toml` в `./config/`. Если есть LE cert — клади туда же (`/config/fullchain.pem`) и пропиши пути в .env как `/config/fullchain.pem`.

## Управление

| Действие | Команда |
|---|---|
| Логи | `docker compose logs -f phantom-relay` |
| Рестарт | `docker compose restart` |
| Обновить | `docker compose pull && docker compose up -d` |

## Когда нужен relay

Если NL exit (vdsina) забанен по IP в RU — relay живёт на дружественном RU-провайдере и форвардит. Клиенты пишут `relay.example.com:443` в ghs://, фактически выходят через NL.

Если NL exit доступен напрямую — relay не нужен, клиенты ходят на сервер сразу.
```

- [ ] **Step 5: Smoke-тест: bootstrap relay**

```sh
mkdir -p /tmp/gs-relay/config
docker run --rm \
    -e UPSTREAM_ADDR=nl2.example.com:443 \
    -e EXPECTED_SNI=relay.example.com \
    -v /tmp/gs-relay/config:/config \
    ghoststream-relay:dev 2>&1 | head -10
```

Ожидаемо: видим `[bootstrap] Wrote /config/relay.toml`, потом relay стартует и пытается слушать :443 (упадёт на permission denied — порт <1024 для non-root, но это нормально для теста с user:relay внутри). Главное: bootstrap сработал, файл создан.

```sh
cat /tmp/gs-relay/config/relay.toml
rm -rf /tmp/gs-relay
```

Ожидаемо: видишь нормальный TOML.

- [ ] **Step 6: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add docker/relay/entrypoint.sh docker/relay/compose.example.yml docker/relay/.env.example docker/relay/README.md
git commit -m "docker(relay): entrypoint + compose + README"
```

---

## Task 8: CI workflow для push в ghcr.io

**Files:**
- Create: `.github/workflows/docker.yml`

- [ ] **Step 1: Написать `.github/workflows/docker.yml`**

Файл `/Users/p.kurkin/ghoststream/.github/workflows/docker.yml`:

```yaml
name: docker-build-push

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    strategy:
      fail-fast: false
      matrix:
        image:
          - name: server
            dockerfile: docker/server/Dockerfile
          - name: relay
            dockerfile: docker/relay/Dockerfile
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository_owner }}/ghoststream-${{ matrix.image.name }}
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=raw,value=latest,enable={{is_default_branch}}
            type=raw,value=latest,enable=${{ startsWith(github.ref, 'refs/tags/v') }}

      - uses: docker/build-push-action@v5
        with:
          context: .
          file: ${{ matrix.image.dockerfile }}
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha,scope=${{ matrix.image.name }}
          cache-to: type=gha,mode=max,scope=${{ matrix.image.name }}
```

- [ ] **Step 2: Локальная валидация workflow синтаксиса**

```sh
# Если установлен actionlint:
actionlint /Users/p.kurkin/ghoststream/.github/workflows/docker.yml
```

Если actionlint нет — пропустить, проверка пройдёт на push. Но визуально пробежать YAML на отступы.

- [ ] **Step 3: Commit**

```sh
cd /Users/p.kurkin/ghoststream
git add .github/workflows/docker.yml
git commit -m "ci(docker): multi-arch build & push to ghcr.io on v* tags"
```

- [ ] **Step 4: Триггер первой сборки (опционально, только если готов к pre-release)**

```sh
# Если хочется проверить workflow без релиза — workflow_dispatch:
gh workflow run docker-build-push
# или просто push какого-нибудь тега:
# git tag v0.26.19-docker-test && git push origin v0.26.19-docker-test
```

> Этот шаг — не часть автоматики, делай только когда план полностью завершён и ты готов выкатить первую docker-версию. Workflow ничего не сломает в случае проблем — образы лягут в ghcr.io как packages, удалить из GitHub UI.

---

## Self-Review Checklist

После выполнения всех задач прогнать вручную:

- [ ] **Server pull-and-go на свежей VPS**: 
  1. Чистая Ubuntu/Debian VPS, установлен Docker.
  2. `git clone ...; cd docker/server; cp compose.example.yml compose.yml; cp .env.example .env`
  3. Прописать `SERVER_NAME=` (реальный или test SNI с self-signed) и `WAN_IFACE=`.
  4. `docker compose up -d`.
  5. `docker compose logs phantom-server` — видим bootstrap-строки + сервер слушает :443.
  6. `docker exec -it phantom-server keys` — создать клиента.
  7. С другого хоста подключиться через ghs:// — должно работать.

- [ ] **Server restore-from-backup**: 
  1. На исходном хосте сделать `tar czf state.tgz ./config`.
  2. На новом хосте: `mkdir config; tar xzf state.tgz -C config --strip-components=1`.
  3. Скопировать .env (SERVER_NAME можно не менять — он уже зашит в server.toml).
  4. `docker compose up -d`.
  5. Подключиться **существующей** ghs:// ссылкой (старого клиента). Должна работать с новым IP.

- [ ] **Relay pull-and-go**: 
  1. Свежая VPS.
  2. `cd docker/relay; cp ...; cp ...; nano .env`.
  3. `docker compose up -d`.
  4. С клиента ghs:// направить через relay → выходит через NL.

- [ ] **CI**: первый `git tag vX.Y.Z; git push origin vX.Y.Z` — workflow зеленый, образы в ghcr.io/<owner>/ghoststream-server и ghoststream-relay с тегами `latest`, `X.Y.Z`, `X.Y`.

---

## После завершения плана

| Что сделано | Что обновить |
|---|---|
| Появился docker init | `docs/knowledge/build.md` — добавить секцию "Docker deploy" |
| Изменён workflow деплоя | `docs/knowledge/decisions/NNNN-docker-deploy.md` — новый ADR: почему docker, почему host networking, почему python остался в образе |
| Сборка теперь идёт через ghcr.io | `docs/knowledge/history/timeline.md` — запись о docker-релизе |

И добавить запись в auto-memory: `reference_docker_deploy.md` — где живёт docker init, как обновлять, ключевые env-vars.
