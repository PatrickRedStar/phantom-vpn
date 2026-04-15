# phantom-telegram-bot

Telegram-бот для управления `phantom-server` через admin HTTP API.
Работает только с одним Telegram ID (админом), указанным в `.env`.

## Возможности

- Список клиентов + детали (статус, трафик, подписка, 👑 для админов)
- Создать клиента: имя → срок подписки → тип (админ/обычный)
- Toggle «Сделать админом / Снять админа» в карточке клиента
- Удалить клиента
- Enable / Disable
- Управление подпиской (extend / set / cancel / revoke)
- QR-код + текстовая строка подключения (формат `ghs://...`)

## Развёртывание

```bash
cd /opt/github_projects/phantom-vpn/tools/telegram-bot
cp .env.example .env
# отредактировать .env — вписать BOT_TOKEN, ADMIN_TELEGRAM_ID, PHANTOM_ADMIN_TOKEN
chmod 600 .env

docker compose build
docker compose up -d
docker logs -f phantom-telegram-bot
```

В логах должно появиться `Application started`.

## Admin-статус

Админство клиента хранится **на сервере** (`clients.json` → `is_admin`).
Бот выставляет его через `POST /api/clients/<name>/admin` и читает из
`GET /api/clients`. Никакой локальной базы ролей больше нет.

Бот ходит в phantom-server через `http://127.0.0.1:8081` (loopback-only
plain HTTP + Bearer token listener — канал break-glass). Основной admin
API на `10.7.0.1:8080` требует mTLS и доступен только клиентам VPN.

## Структура

```
tools/telegram-bot/
├── Dockerfile
├── docker-compose.yml
├── .env                    # gitignored, секреты
├── .env.example
├── requirements.txt
├── data/                   # bind-mount (пусто)
└── bot/
    ├── main.py             # entry
    ├── config.py           # чтение .env
    ├── api.py              # httpx обёртка над admin API
    ├── qr.py               # генерация QR PNG
    ├── auth.py             # фильтр по Telegram ID
    └── handlers.py         # /start, меню, ConversationHandler
```
