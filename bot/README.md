# VLESS Telegram Bot

Telegram-бот для управления VLESS-подписками через Telegram Stars (`XTR`) и 3x-ui.

## Запуск через Docker Compose (рекомендуется)

```bash
cd /opt/botvpn
cp .env.example .env
# заполните .env
docker compose up -d --build
```

`bot` контейнер перед запуском приложения автоматически выполняет SQL-миграции (`python -m app.db_migrate`).

Проверка:

```bash
docker compose ps
curl -fsS http://127.0.0.1:${NGINX_HTTP_PORT:-8090}/healthz
docker compose logs -f bot
```

## Структура compose

- `bot` — приложение FastAPI + aiogram (`python -m app.main`)
- `nginx` — reverse proxy к `bot:8090`
- `./data` — персистентная директория для SQLite (`/data/bot.db` в контейнере)

## Переменные окружения

Основные:

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_WEBHOOK_SECRET`
- `TELEGRAM_WEBHOOK_URL`
- `TELEGRAM_PROVIDER_TOKEN`
- `BOT_ADMIN_IDS`

Тарифы:

- `PRICE_30_XTR`, `PRICE_90_XTR`, `PRICE_180_XTR`
- `ADMIN_PRICE_XTR` (цена для админа)

Интеграция 3x-ui:

- `XUI_BASE_URL`, `XUI_USERNAME`, `XUI_PASSWORD`
- `XUI_INBOUND_IDS`, `XUI_SUB_URL`
- `XUI_TLS_VERIFY` (`1`/`0`)
- `XUI_CA_BUNDLE` (опционально, путь к CA bundle)
- `XUI_CA_BUNDLE_HOST_PATH` (директория на хосте, монтируется в `/opt/xui-certs` контейнера)

Важно для Docker:
- не используйте `localhost` в `XUI_BASE_URL`, если 3x-ui не в этом же контейнере;
- для 3x-ui на хосте используйте `https://host.docker.internal:2053/panel`.
- для кастомного CA положите файл в `XUI_CA_BUNDLE_HOST_PATH` и задайте `XUI_CA_BUNDLE=/opt/xui-certs/<file>.pem`.

Хранилище/сеть:

- `DATABASE_URL` (для docker по умолчанию: `sqlite+aiosqlite:////data/bot.db`)
- `BOT_HOST`, `BOT_PORT`
- `NGINX_HTTP_PORT` (порт публикации nginx, по умолчанию `8090`)

## Миграция с legacy systemd (`/opt/phantom-vpn/src/bot`) в `/opt/botvpn`

```bash
# 1) подготовить новую директорию
mkdir -p /opt/botvpn/data

# 2) скопировать код бота (без venv и sqlite)
rsync -av --exclude '.venv' --exclude 'bot.db' /opt/phantom-vpn/src/bot/ /opt/botvpn/

# 3) перенести рабочий .env и БД
cp /opt/phantom-vpn/src/bot/.env /opt/botvpn/.env
cp /opt/phantom-vpn/src/bot/bot.db /opt/botvpn/data/bot.db

# 4) перевести DATABASE_URL на путь в контейнере
sed -i 's#^DATABASE_URL=.*#DATABASE_URL=sqlite+aiosqlite:////data/bot.db#' /opt/botvpn/.env

# 5) выбрать свободный порт публикации nginx
echo 'NGINX_HTTP_PORT=8090' >> /opt/botvpn/.env

# 6) поднять docker compose
cd /opt/botvpn
docker compose up -d --build

# 7) проверить новый стек
docker compose ps
curl -fsS http://127.0.0.1:8090/healthz
docker compose logs --tail=100 bot

# 8) после успешной проверки отключить legacy unit
systemctl disable --now ghoststream-bot.service
```

## TLS и внешний доступ

- `docker-compose` nginx поднимает HTTP reverse proxy.
- Для продакшена TLS должен завершаться на внешнем уровне (Cloudflare/LB/Ingress/внешний nginx).
- `TELEGRAM_WEBHOOK_URL` должен указывать на публичный HTTPS URL.
