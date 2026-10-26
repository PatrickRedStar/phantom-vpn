#!/bin/sh
# Срок TLS-сертификата, который exit реально отдаёт клиентам (а не файла на диске:
# сервер читает серт только при старте). Ненулевой код и сообщение в stderr,
# если до истечения меньше DAYS дней или серт не получить.
#
# Usage: check-cert.sh [host:port] [sni]      DAYS=14 по умолчанию
# Cron (с balancer — оттуда :8443 и смотрят клиенты): см. docs/knowledge/build.md

set -eu

ADDR="${1:-89.110.109.128:8443}"
SNI="${2:-tls.nl2.bikini-bottom.com}"
DAYS="${DAYS:-14}"

cert="$(openssl s_client -connect "$ADDR" -servername "$SNI" </dev/null 2>/dev/null \
    | openssl x509 2>/dev/null || true)"
if [ -z "$cert" ]; then
    echo "CRIT: не удалось получить сертификат $SNI с $ADDR" >&2
    exit 2
fi

end="$(printf '%s\n' "$cert" | openssl x509 -noout -enddate | cut -d= -f2)"
if ! printf '%s\n' "$cert" | openssl x509 -noout -checkend $((DAYS * 86400)) >/dev/null; then
    echo "CRIT: сертификат $SNI на $ADDR истекает $end (меньше $DAYS дн.) — certbot renew + systemctl restart phantom-server" >&2
    exit 1
fi
echo "OK: сертификат $SNI на $ADDR действует до $end"
