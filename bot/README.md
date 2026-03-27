# GhostStream Telegram Bot

Webhook-бот для управления VPN-подписками через Telegram Stars (`XTR`) и Admin API.

## Что реализовано

- webhook endpoint: `/telegram/webhook`
- health endpoint: `/healthz`
- оплата Stars (`sendInvoice`, `pre_checkout_query`, `successful_payment`)
- идемпотентность платежей по `telegram_payment_charge_id`
- multi-subscriptions на одного пользователя
- выдача `conn_string` + QR
- полноценная админка в Telegram (статус, клиенты, подписки, enable/disable, revoke/delete с confirm, logs/stats)
- единая точка правды подписок: данные читаются только из Admin API VPN-серверов
- хранение данных бота: `tg_users`, `payments`, `subscription_events`, `client_bindings` (`subscriptions` — legacy)
- retry/backoff клиент к Admin API

## Структура

- `app/main.py` — запуск uvicorn
- `app/web.py` — FastAPI app + webhook
- `app/bot_logic.py` — aiogram handlers
- `app/admin_client.py` — Admin API клиент
- `app/models.py` / `app/repositories.py` — слой БД
- `app/migrations/0001_init.sql` — SQL-миграция
- `deploy/systemd/ghoststream-bot.service` — unit
- `deploy/nginx/ghoststream-bot.conf` — reverse proxy

## Локальный запуск

```bash
cd bot
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python -m app.main
```

## Переменные окружения

- `TELEGRAM_BOT_TOKEN` — токен бота
- `TELEGRAM_WEBHOOK_SECRET` — secret header в webhook
- `TELEGRAM_WEBHOOK_URL` — публичный HTTPS URL webhook
- `TELEGRAM_PROVIDER_TOKEN` — для Stars обычно пустой
- `VPN_SERVERS_JSON` — статический JSON-реестр серверов (multi-server режим)
- `DEFAULT_VPN_SERVER_ID` — сервер по умолчанию из `VPN_SERVERS_JSON`
- `ADMIN_API_BASE_URL`, `ADMIN_API_TOKEN` — legacy single-server fallback
- `DATABASE_URL` — `sqlite+aiosqlite:///./bot.db` или PostgreSQL DSN
- `BOT_HOST`, `BOT_PORT` — bind FastAPI
- `BOT_ADMIN_IDS` — список Telegram ID админов через запятую (пример: `396733927`)
- `PRICE_30_XTR`, `PRICE_90_XTR`, `PRICE_180_XTR` — цены тарифов в звёздах

## Деплой на VDS (systemd + nginx)

Быстрый запуск на новом хосте:

```bash
cd bot
sudo TELEGRAM_BOT_TOKEN='...' \
  TELEGRAM_WEBHOOK_URL='https://bot.example.com/telegram/webhook' \
  VPN_SERVERS_JSON='[{"id":"default","name":"Default","admin_api_base_url":"http://10.7.0.1:8080","admin_api_token":"..."}]' \
  DEFAULT_VPN_SERVER_ID='default' \
  ./install.sh --setup-nginx --domain bot.example.com
```

Что делает `install.sh`:

- ставит зависимости Python (и nginx при `--setup-nginx`);
- создаёт `.venv` и ставит `requirements.txt`;
- генерирует `bot/.env` с переданными секретами;
- создаёт и запускает `ghoststream-bot.service`;
- создаёт nginx конфиг и перезагружает nginx (опционально).

Проверка:

- `systemctl status ghoststream-bot`
- `curl -fsS http://127.0.0.1:8090/healthz`
- `curl -fsS https://bot.example.com/healthz`
- `journalctl -u ghoststream-bot -f`

