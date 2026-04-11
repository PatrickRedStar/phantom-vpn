# phantom-telegram-bot

Telegram-бот для управления `phantom-server` через admin HTTP API.
Работает только с одним Telegram ID (админом), указанным в `.env`.

## Возможности

- Список клиентов + детали (статус, трафик, подписка)
- Создать клиента с выбором роли **Admin** / **Regular**
  - Regular → в `conn_string` вырезается `admin` (url+token панели)
  - Admin → `conn_string` отдаётся как есть
- Удалить клиента
- Enable / Disable
- Управление подпиской (extend / set / cancel / revoke)
- QR-код + текстовая строка подключения

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

## Структура

```
tools/telegram-bot/
├── Dockerfile
├── docker-compose.yml
├── .env                    # gitignored, секреты
├── .env.example
├── requirements.txt
├── data/                   # bind-mount, roles.json
└── bot/
    ├── main.py             # entry
    ├── config.py           # чтение .env
    ├── api.py              # httpx обёртка над admin API
    ├── conn_string.py      # strip_admin для regular
    ├── roles.py            # локальный store ролей
    ├── qr.py               # генерация QR PNG
    ├── auth.py             # фильтр по Telegram ID
    └── handlers.py         # /start, меню, ConversationHandler
```

## Роли

Роли хранятся только в `data/roles.json` — на сервере (phantom-server) нет
концепции admin/regular. Единственный эффект роли: для `regular` клиента
бот вырезает поле `admin` из conn_string перед отправкой пользователю,
чтобы тот не получил доступ к admin-панели сервера.
