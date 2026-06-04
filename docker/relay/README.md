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
