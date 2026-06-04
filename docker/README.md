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
