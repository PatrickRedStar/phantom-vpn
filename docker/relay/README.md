# phantom-relay (Docker)

RU SNI-passthrough узел. Слушает :443, читает SNI из ClientHello, форвардит к NL exit.

## Быстрый старт

```sh
cd ghoststream/docker/relay
cp compose.example.yml compose.yml
cp .env.example .env
$EDITOR .env                           # UPSTREAM_ADDR + EXPECTED_SNI
mkdir -p config && cp -L /etc/letsencrypt/live/<имя реле>/{fullchain,privkey}.pem config/
sudo chown -R 10001 config                # контейнер работает от UID 10001
docker login ghcr.io                      # пакеты приватные: логин GitHub + токен с read:packages
docker compose up -d
```

## Что в .env

| Переменная | Что |
|---|---|
| `UPSTREAM_ADDR` | NL exit `host:port`, куда форвардить совпадающий SNI. Порт `:8443` — `:443` exit'а из РФ фильтруется |
| `EXPECTED_SNI` | Имя в ClientHello клиентов. Должно равняться SERVER_NAME у сервера (имя exit'а, не реле) — иначе все клиенты падают с `BadCertificate` |
| `FALLBACK_CERT/KEY` | Обязательно: LE cert собственного имени реле. Проб с чужим SNI получает ответ как от обычного nginx (404), а не мгновенный обрыв, похожий на блок |

## State

`relay.toml` и LE cert/key в `./config/`. Серт перечитывается на каждом fallback-соединении: после продления достаточно скопировать свежие файлы в `./config/` (certbot deploy-hook), рестарт не нужен и живые стримы не рвутся.

Режим без fallback-серта (drop) — только за nginx stream (`ssl_preread`), когда порт реле наружу не опубликован: положи в `./config/relay.toml` свой конфиг без `cert_path`/`key_path`, bootstrap его не тронет.

## Управление

| Действие | Команда |
|---|---|
| Логи | `docker compose logs -f phantom-relay` |
| Рестарт | `docker compose restart` |
| Обновить | `docker compose pull && docker compose up -d` |

## Когда нужен relay

Если NL exit (vdsina) забанен по IP в RU — relay живёт на дружественном RU-провайдере и форвардит. Клиенты пишут `relay.example.com:443` в ghs://, фактически выходят через NL.

Если NL exit доступен напрямую — relay не нужен, клиенты ходят на сервер сразу.
