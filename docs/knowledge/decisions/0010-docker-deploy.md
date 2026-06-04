---
title: Docker как первичный путь развёртывания server + relay
date: 2026-06-04
status: accepted
---

# ADR-0010: Docker init для server и relay

## Контекст

В мае-июне 2026 vdsina (NL exit-нода) лежала несколько дней — упал сам провайдер.
Восстановить сервис не получилось быстро потому что текущая схема деплоя — это
**bare-metal cargo build на хосте + ручной systemd + ручные iptables + ручной nginx**:

- `server/scripts/install.py` — устаревший QUIC-bootstrap (legacy v0.18).
- `server/scripts/deploy.sh` / `deploy-relay.sh` — remote rsync + remote `cargo build`.
- `clients.json` + CA-ключ — лежат только на боевом хосте, без бэкапа.
- Каждый новый хост = час ручной работы (apt update → install build-essential →
  cargo bootstrap → systemd unit → nginx stream → iptables → SSH copy keys).

Падение vdsina на 3+ дня сделало эту схему неприемлемой.

## Альтернативы

| Подход | Плюсы | Минусы |
|---|---|---|
| Ansible playbook | Полная воспроизводимость | Нужен Ansible на каждой dev-машине; абстракция поверх apt/systemd; легко поломать idempotency |
| Bash скрипт-bootstrap (как install.py) | Минимум зависимостей | Уже пробовали, превратился в legacy за один цикл |
| Docker compose | Один pull = поднялся; image testable изолированно; CI собирает | Нужен docker на хосте; host networking для server обязателен; runtime caps |
| Kubernetes | Промышленный стандарт | Overkill на ~3 узла; маскотравматичный обвес для VPN single-tenant |

**Выбран Docker compose** — баланс между простотой ("spullил и поехал") и
изоляцией. Соответствует ментальной модели self-hosted VPN-панелей (Amnezia,
3x-ui), которыми пользуются операторы.

## Решение

Два независимых docker-проекта:

| Каталог | Образ | Назначение |
|---|---|---|
| `docker/server/` | `ghcr.io/<owner>/ghoststream-server` | NL exit, H2/TLS :443 + TUN + NAT |
| `docker/relay/` | `ghcr.io/<owner>/ghoststream-relay` | RU SNI passthrough :443 |

**Ключевые инварианты:**

1. **Весь state в bind-mount `/config`.** `ca.crt`, `ca.key`, `server.crt`,
   `server.key`, `server.toml`, `clients.json`, `clients/<name>/*` — всё в одном
   каталоге. Бэкап = `tar czf state.tgz ./config`. Восстановление = unpack +
   `docker compose up -d`. Старые ghs:// клиентов работают (та же CA, те же
   fingerprint'ы), только новый IP.

2. **Self-bootstrap entrypoint.** При первом старте, если `/config/server.toml`
   нет:
   - Требует `SERVER_NAME` env (TLS SNI / cert CN).
   - Вызывает `phantom-keygen --out /config --server-name $SERVER_NAME`
     (генерит CA + server cert).
   - Авто-генерирует `ADMIN_TOKEN` если не задан (`head /dev/urandom | od | tr`).
   - Рендерит `server.toml` из heredoc с подстановкой env.
   - Пишет пустой `clients.json`.

   На последующих стартах entrypoint видит существующий `server.toml` → exec'ит
   phantom-server без bootstrap. Конфиг **никогда не перезаписывается** — это
   гарантия что restore-from-backup работает identical.

3. **Server networking — `network_mode: host`.** Не bridge. Причина: phantom-server
   сам выполняет `iptables -t nat -A POSTROUTING ... MASQUERADE -o $WAN_IFACE`
   внутри своего network namespace. В bridge-режиме `$WAN_IFACE` — это
   docker-private интерфейс, правила NAT не достигают реального трафика. Host
   networking — единственный надёжный путь без переписывания NAT-логики или
   ручной настройки iptables на хосте.

4. **Server capabilities — `privileged: true`.** Можно сузить до
   `[NET_ADMIN, NET_RAW, SYS_ADMIN]` (io_uring требует SYS_ADMIN), но
   privileged эквивалентно для single-process контейнера на dedicated VPS и не
   создаёт extra attack surface. TODO: сузить когда будет ranged-cap проверка.

5. **Relay — non-root UID 10001 + bridge networking + port mapping.** Relay
   ничего не NAT-ит, чистый TCP proxy. Поэтому никаких caps не нужно. Но
   non-root UID не может биндить порты <1024 без `CAP_NET_BIND_SERVICE`. Решено:
   контейнер слушает `:5443` (внутри), compose делает `ports: "443:5443/tcp"`.
   Снаружи это всё ещё `:443`.

6. **User management через `keys.py` в образе.** Гибрид-решение: keys.py
   осталась в server image (~30MB python3-minimal), запускается через
   `docker exec -it phantom-server keys`. Symlink `/opt/phantom-vpn/config → /config`
   в Dockerfile делает hardcoded пути из keys.py прозрачно резолвимыми к
   bind-mount'у. **TODO:** заменить на native Rust CLI
   (`phantom-server users add|list|revoke|export`) — выкинет python3 и +1 layer.

7. **CI multi-arch.** `.github/workflows/docker.yml` собирает оба образа для
   `linux/amd64,linux/arm64` через QEMU buildx на push тега `v*`. Pushed в
   `ghcr.io/<repo-owner>/ghoststream-{server,relay}` с тегами `vX.Y.Z`, `X.Y`,
   `latest`.

## Trade-off

| Что отдали | Что получили |
|---|---|
| `network_mode: host` (нет network isolation на server'е) | Работает iptables NAT, не надо переписывать data plane |
| `privileged: true` на server'е | Простота; io_uring/tun_uring требуют SYS_ADMIN всё равно |
| Python3 в server-образе (~30MB) | keys.py работает as-is, без двух-этапной миграции |
| `latest` тег на pre-release (`v*-rc1`) | Простота CI; фикс — `enable=...!contains(github.ref,'-')` когда понадобится |
| QEMU arm64 на amd64 runner (медленно ~40min) | Один workflow, один matrix, никаких native arm64 runners |

## Что НЕ автоматизируем

- **Бэкап `/config`.** Пользователь сам делает `tar+scp` или ставит restic в
  cron. Закладывать backup в compose = слой обёрток над core фичей.
- **Watchtower / auto-pull.** Образ обновляется руками
  (`docker compose pull && up -d`). Намеренный chokepoint для контроля над
  upgrade window.
- **Health-check sidecar.** `restart: unless-stopped` + journalctl на хосте
  достаточно.

## Файлы

- `docker/server/Dockerfile` — multi-stage rust:1.83-bookworm builder → debian:bookworm-slim runtime (iptables, iproute2, openssl, python3-minimal, tini, ca-certificates).
- `docker/server/entrypoint.sh` — POSIX sh, self-bootstrap + exec phantom-server.
- `docker/server/compose.example.yml` — host networking, privileged, /dev/net/tun, /config volume.
- `docker/server/.env.example` — SERVER_NAME, WAN_IFACE, ADMIN_TOKEN.
- `docker/server/README.md` — pull-and-go + restore-from-backup инструкции.
- `docker/relay/Dockerfile` — multi-stage, non-root UID 10001.
- `docker/relay/entrypoint.sh` — render relay.toml from env, exec phantom-relay.
- `docker/relay/compose.example.yml` — bridge, ports 443:5443/tcp.
- `docker/relay/.env.example` — UPSTREAM_ADDR, EXPECTED_SNI, FALLBACK_CERT/KEY.
- `docker/relay/README.md`.
- `.github/workflows/docker.yml` — multi-arch CI на тэги `v*`.

Старая схема (cargo + systemd + install.py + deploy.sh) **остаётся для
bare-metal случаев** и legacy серверов, не выкидывается.

## Когда не нужен Docker

- Бокс уже работает на старой схеме и не падает — не трогать.
- Embedded / OpenWrt — там docker и так нет, отдельная схема в `apps/openwrt/`.

## Связанные документы

- План — `docs/superpowers/plans/2026-06-04-docker-init-server-relay.md`.
- Build процедура — [../build.md](../build.md) (раздел "Docker deploy").
