#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_HOST="127.0.0.1"
BOT_PORT="8090"
ADMIN_API_BASE_URL="http://10.7.0.1:8080"
DATABASE_URL="sqlite+aiosqlite:///./bot.db"
TELEGRAM_PROVIDER_TOKEN=""
SETUP_NGINX="false"
DOMAIN=""
VPN_SERVERS_JSON="${VPN_SERVERS_JSON:-}"
DEFAULT_VPN_SERVER_ID="${DEFAULT_VPN_SERVER_ID:-}"
PRICE_30_XTR="${PRICE_30_XTR:-1}"
PRICE_90_XTR="${PRICE_90_XTR:-2}"
PRICE_180_XTR="${PRICE_180_XTR:-3}"
ADMIN_PRICE_XTR="${ADMIN_PRICE_XTR:-1}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_WEBHOOK_URL="${TELEGRAM_WEBHOOK_URL:-}"
TELEGRAM_WEBHOOK_SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
ADMIN_API_TOKEN="${ADMIN_API_TOKEN:-}"
BOT_ADMIN_IDS="${BOT_ADMIN_IDS:-}"
XUI_BASE_URL="${XUI_BASE_URL:-}"
XUI_USERNAME="${XUI_USERNAME:-}"
XUI_PASSWORD="${XUI_PASSWORD:-}"
XUI_INBOUND_IDS="${XUI_INBOUND_IDS:-}"
XUI_SUB_URL="${XUI_SUB_URL:-}"
XUI_TLS_VERIFY="${XUI_TLS_VERIFY:-1}"
XUI_CA_BUNDLE="${XUI_CA_BUNDLE:-}"

usage() {
  cat <<'EOF'
Usage:
  TELEGRAM_BOT_TOKEN=... \
  ADMIN_API_TOKEN=... \
  ./install.sh [options]

Options:
  --project-dir <path>         Project directory (default: current bot dir)
  --bot-host <host>            FastAPI bind host (default: 127.0.0.1)
  --bot-port <port>            FastAPI bind port (default: 8090)
  --admin-api-base-url <url>   Admin API URL (default: http://10.7.0.1:8080)
  --admin-api-token <token>    Admin API token (legacy single-server mode)
  --vpn-servers-json <json>    Static list of VPN servers for multi-server mode
  --default-server-id <id>     Default server id from VPN_SERVERS_JSON
  --database-url <dsn>         SQLAlchemy DB URL
  --provider-token <token>     Telegram provider token (for Stars can be empty)
  --bot-admin-ids <ids>        Admin Telegram IDs, comma separated
  --price-30-xtr <int>         Price for 30 days in Stars (default: 1)
  --price-90-xtr <int>         Price for 90 days in Stars (default: 2)
  --price-180-xtr <int>        Price for 180 days in Stars (default: 3)
  --admin-price-xtr <int>      Price for admins in Stars (default: 1)
  --webhook-url <url>          Public webhook URL (optional, can be set later)
  --webhook-secret <secret>    Webhook secret token
  --domain <domain>            Domain for nginx config (e.g. bot.example.com)
  --setup-nginx                Install nginx config (requires --domain)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --bot-host) BOT_HOST="$2"; shift 2 ;;
    --bot-port) BOT_PORT="$2"; shift 2 ;;
    --admin-api-base-url) ADMIN_API_BASE_URL="$2"; shift 2 ;;
    --admin-api-token) ADMIN_API_TOKEN="$2"; shift 2 ;;
    --vpn-servers-json) VPN_SERVERS_JSON="$2"; shift 2 ;;
    --default-server-id) DEFAULT_VPN_SERVER_ID="$2"; shift 2 ;;
    --database-url) DATABASE_URL="$2"; shift 2 ;;
    --provider-token) TELEGRAM_PROVIDER_TOKEN="$2"; shift 2 ;;
    --bot-admin-ids) BOT_ADMIN_IDS="$2"; shift 2 ;;
    --price-30-xtr) PRICE_30_XTR="$2"; shift 2 ;;
    --price-90-xtr) PRICE_90_XTR="$2"; shift 2 ;;
    --price-180-xtr) PRICE_180_XTR="$2"; shift 2 ;;
    --admin-price-xtr) ADMIN_PRICE_XTR="$2"; shift 2 ;;
    --webhook-url) TELEGRAM_WEBHOOK_URL="$2"; shift 2 ;;
    --webhook-secret) TELEGRAM_WEBHOOK_SECRET="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --setup-nginx) SETUP_NGINX="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
  echo "TELEGRAM_BOT_TOKEN is required" >&2
  exit 1
fi
if [[ -z "${VPN_SERVERS_JSON}" && -z "${ADMIN_API_TOKEN}" ]]; then
  echo "Either VPN_SERVERS_JSON or ADMIN_API_TOKEN is required" >&2
  exit 1
fi
if [[ "${SETUP_NGINX}" == "true" && -z "${DOMAIN}" ]]; then
  echo "--setup-nginx requires --domain" >&2
  exit 1
fi

if [[ -z "${TELEGRAM_WEBHOOK_SECRET}" ]]; then
  TELEGRAM_WEBHOOK_SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
fi

if [[ -z "${TELEGRAM_WEBHOOK_URL}" ]]; then
  echo "Warning: TELEGRAM_WEBHOOK_URL is empty. Bot will start without registering webhook."
fi

if [[ -z "${VPN_SERVERS_JSON}" ]]; then
  # Build default single-server registry JSON from legacy variables
  VPN_SERVERS_JSON="$(python3 - <<PY
import json
print(json.dumps([{
  "id": "default",
  "name": "Default",
  "admin_api_base_url": "${ADMIN_API_BASE_URL}",
  "admin_api_token": "${ADMIN_API_TOKEN}"
}], ensure_ascii=True))
PY
)"
fi
if [[ -z "${DEFAULT_VPN_SERVER_ID}" ]]; then
  DEFAULT_VPN_SERVER_ID="default"
fi

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3 python3-venv python3-pip curl
    if [[ "${SETUP_NGINX}" == "true" ]]; then
      apt-get install -y nginx
    fi
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip curl
    if [[ "${SETUP_NGINX}" == "true" ]]; then
      dnf install -y nginx
    fi
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm python python-pip curl
    if [[ "${SETUP_NGINX}" == "true" ]]; then
      pacman -Sy --noconfirm nginx
    fi
    return
  fi
  echo "Unsupported package manager. Install Python3 + venv manually." >&2
  exit 1
}

write_env() {
  cat > "${PROJECT_DIR}/.env" <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_WEBHOOK_SECRET=${TELEGRAM_WEBHOOK_SECRET}
TELEGRAM_WEBHOOK_URL=${TELEGRAM_WEBHOOK_URL}
TELEGRAM_PROVIDER_TOKEN=${TELEGRAM_PROVIDER_TOKEN}
ADMIN_API_BASE_URL=${ADMIN_API_BASE_URL}
ADMIN_API_TOKEN=${ADMIN_API_TOKEN}
VPN_SERVERS_JSON=${VPN_SERVERS_JSON}
DEFAULT_VPN_SERVER_ID=${DEFAULT_VPN_SERVER_ID}
DATABASE_URL=${DATABASE_URL}
BOT_HOST=${BOT_HOST}
BOT_PORT=${BOT_PORT}
BOT_ADMIN_IDS=${BOT_ADMIN_IDS}
PRICE_30_XTR=${PRICE_30_XTR}
PRICE_90_XTR=${PRICE_90_XTR}
PRICE_180_XTR=${PRICE_180_XTR}
ADMIN_PRICE_XTR=${ADMIN_PRICE_XTR}
XUI_BASE_URL=${XUI_BASE_URL}
XUI_USERNAME=${XUI_USERNAME}
XUI_PASSWORD=${XUI_PASSWORD}
XUI_INBOUND_IDS=${XUI_INBOUND_IDS}
XUI_SUB_URL=${XUI_SUB_URL}
XUI_TLS_VERIFY=${XUI_TLS_VERIFY}
XUI_CA_BUNDLE=${XUI_CA_BUNDLE}
EOF
  chmod 600 "${PROJECT_DIR}/.env"
}

write_systemd_service() {
  cat > /etc/systemd/system/ghoststream-bot.service <<EOF
[Unit]
Description=VLESS Telegram Bot (Webhook)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${PROJECT_DIR}
EnvironmentFile=${PROJECT_DIR}/.env
ExecStart=${PROJECT_DIR}/.venv/bin/python -m app.main
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_conf() {
  cat > /etc/nginx/conf.d/ghoststream-bot.conf <<EOF
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location /telegram/webhook {
        proxy_pass http://127.0.0.1:${BOT_PORT}/telegram/webhook;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /healthz {
        proxy_pass http://127.0.0.1:${BOT_PORT}/healthz;
        proxy_set_header Host \$host;
    }
}
EOF
}

main() {
  [[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
  [[ -f "${PROJECT_DIR}/requirements.txt" ]] || { echo "requirements.txt not found in ${PROJECT_DIR}" >&2; exit 1; }
  [[ -d "${PROJECT_DIR}/app" ]] || { echo "app/ not found in ${PROJECT_DIR}" >&2; exit 1; }

  install_packages

  cd "${PROJECT_DIR}"
  python3 -m venv .venv
  .venv/bin/pip install --upgrade pip
  .venv/bin/pip install -r requirements.txt

  write_env
  write_systemd_service

  systemctl daemon-reload
  systemctl enable --now ghoststream-bot.service
  systemctl restart ghoststream-bot.service

  if [[ "${SETUP_NGINX}" == "true" ]]; then
    write_nginx_conf
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
  fi

  sleep 1
  systemctl --no-pager --full status ghoststream-bot.service | sed -n '1,20p'
  echo
  echo "Local health check:"
  curl -fsS "http://127.0.0.1:${BOT_PORT}/healthz" || true
  echo
  echo "Done."
}

main "$@"
