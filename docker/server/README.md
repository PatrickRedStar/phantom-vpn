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
