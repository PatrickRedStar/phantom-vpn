---
updated: 2026-04-17
---

# Server — phantom-server + phantom-relay

## Стек

- **`phantom-server`** (`server/server/`) — TLS accept + VPN data plane + admin
  HTTP API + passive DNS cache + fakeapp fallback + mimicry warmup. Всё в одном
  бинаре, один `tokio::runtime` (multi-threaded).
- **`phantom-relay`** (`server/relay/`) — SNI passthrough на RU-хопе. **НЕ
  терминирует TLS** (v0.17.0+). Peek ClientHello → SNI → raw `copy_bidirectional`.
- **`phantom-keygen`** — CLI для bootstrap: CA generation, client cert issue,
  `admin-grant`. Отдельный бинарь, живёт рядом с `phantom-server`.
- Runtime: Tokio multi-threaded scheduler. TUN на сервере — `tun_uring` (io_uring,
  zero-copy через `Bytes` / `BytesMut`).

## Хосты

| Алиас | IP | Роль | DNS |
|---|---|---|---|
| `vdsina` | 89.110.109.128 | NL exit-нода (phantom-server + nginx frontend) | `tls.nl2.bikini-bottom.com` |
| — | 193.187.95.128 | RU relay-нода (phantom-relay) | `hostkey.bikini-bottom.com` |

SSH: `~/.ssh/bot`, алиасы в `~/.ssh/config`. Claude Code обычно запущен
прямо на `vdsina` — сборка server/linux/android идёт локально.

## Файловая раскладка

| Назначение | Путь |
|---|---|
| Исходники (git working tree на vdsina) | `/opt/github_projects/phantom-vpn/` |
| Runtime | `/opt/phantom-vpn/` |
| Бинарь | `/opt/phantom-vpn/phantom-server` |
| Keygen CLI | `/opt/phantom-vpn/phantom-keygen` |
| Конфиг | `/opt/phantom-vpn/config/server.toml` |
| Keyring (fingerprint → client) | `/opt/phantom-vpn/config/clients.json` |
| CA cert + key | `/opt/phantom-vpn/config/ca.crt`, `ca.key` |
| Per-client | `/opt/phantom-vpn/config/clients/<name>.crt`, `<name>.key` |
| Admin mTLS server cert (auto-gen) | `/opt/phantom-vpn/config/admin-server.crt`, `.key` |
| systemd unit | `/etc/systemd/system/phantom-server.service` |

## Сборка + деплой

Сборка локально на vdsina, деплой — тем же `deploy.sh` или руками:

```bash
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-server --bin phantom-server --bin phantom-keygen
install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server
install -m 0755 target/release/phantom-keygen /opt/phantom-vpn/phantom-keygen
systemctl restart phantom-server.service
```

One-click deploy-скрипт — `server/scripts/deploy.sh` (умеет удалённо, через SSH,
fallback на remote-build при не-Linux источнике).

## Конфиг сервера

Пример — `server/config/server.example.toml`. Ключевые поля:

```toml
[network]
listen_addr = "0.0.0.0:443"   # или :8443 если впереди nginx
tun_name    = "tun1"          # не tun0 чтобы не конфликтовать с wg0
tun_addr    = "10.7.0.1/24"
tun_mtu     = 1350
wan_iface   = "eth0"          # для NAT/iptables; закомментировать чтобы отключить

[keys]
server_private_key = "..."    # генерится phantom-keygen
server_public_key  = "..."

[timeouts]
idle_timeout_secs = 300
hard_timeout_secs = 86400

[quic]                         # legacy name секции, транспорт теперь H2/TLS
cert_subjects = ["tls.nl2.bikini-bottom.com"]
# cert_path / key_path для LE
# ca_cert_path = "/opt/phantom-vpn/config/ca.crt"
# allowed_clients_path = "/opt/phantom-vpn/config/clients.json"
idle_timeout_secs = 30

[admin]
listen_addr     = "10.7.0.1:8080"     # mTLS listener, только через VPN
token           = "..."                # break-glass bearer-token для бота
bot_listen_addr = "127.0.0.1:8081"     # loopback HTTP для Telegram-бота
# ca_cert_path / ca_key_path — для выпуска клиентских сертов через /api/clients
```

Admin-server cert для mTLS listener'а — self-signed на `10.7.0.1`, генерится при
первом старте. Клиенты пиннят SHA-256 (TOFU, см. `VpnProfile.cachedAdminServerCertFp`
на Android / `VpnProfile` в PhantomKit).

Подробности протокола admin API — см. [admin-api.md](../architecture/admin-api.md).

## NAT / iptables

При каждом старте `phantom-server`:

1. `teardown_nat()` — удаляет старые правила (если остались от прошлого запуска).
2. `setup_nat()` — ставит MASQUERADE для `wan_iface` + FORWARD для tun-подсети.

Зачем: коммит `a55965c` (март 2026) — без teardown'а iptables копились дубликаты
при каждом рестарте, и после нескольких циклов получалось 10+ идентичных правил.

## nginx frontend (NL)

Перед `phantom-server` на vdsina стоит nginx как **stream SNI preread** на `:443`:

- SNI == `tls.nl2.bikini-bottom.com` → passthrough на `127.0.0.1:8443` (phantom-server).
- Любой другой SNI → LE-cert fallback HTTPS (выглядит как обычный веб-сайт).

Это даёт двойную страховку: `phantom-server` может остаться на нестандартном
порту, а внешний probe видит валидный TLS-сертификат, выданный Let's Encrypt.

## Relay — SNI Passthrough (RU, v0.17.0+)

`phantom-relay` на RU-хопе (`hostkey.bikini-bottom.com`, `193.187.95.128`) **не
терминирует TLS**. Псевдокод логики:

```rust
let client_hello = peek_up_to(socket, 1500).await?;
let sni = parse_sni_from_client_hello(&client_hello)?;

if sni == expected_sni {
    // raw forward — TLS handshake end-to-end между phone и NL phantom-server
    copy_bidirectional(socket, upstream_to_nl).await?;
} else {
    // fallback acceptor c LE-cert → HTML-заглушка
    serve_fallback_html(socket).await?;
}
```

Почему:
- До v0.17 был double-TLS (RU terminate → NL terminate) — RU был CPU-bound на
  AES-GCM. Теперь RU чисто I/O-bound, держит в разы больше соединений.
- Fallback с LE-cert нужен для того чтобы на внешний probe (без нужного SNI) RU
  выглядел как обычный HTTPS-сайт → не палимся активным сканированием.

End-to-end TLS: phone-side рукопожатие идёт напрямую в NL phantom-server, relay
видит только зашифрованные байты. Подробно — [transport.md](../architecture/transport.md#sni-passthrough-relay).

## Admin HTTP API — коротко

Встроен в `phantom-server`. Два listener'а (v0.19+):

| Listener | Bind | Транспорт | Auth | Для кого |
|---|---|---|---|---|
| mTLS | `[admin].listen_addr` = `10.7.0.1:8080` | HTTPS + mTLS | client cert → fingerprint → `is_admin` | Android/Linux admin panel через VPN |
| loopback | `[admin].bot_listen_addr` = `127.0.0.1:8081` | plain HTTP | `Authorization: Bearer <token>` | Telegram-бот (same-host only) |

Role (`is_admin`) — per-client флаг в `clients.json`. Первый админ — через
`phantom-keygen admin-grant --name <n> --enable`. Полный список endpoint'ов
и shape'ов JSON — [admin-api.md](../architecture/admin-api.md).

## Команды диагностики

```bash
# Локально на vdsina
systemctl status phantom-server.service
systemctl restart phantom-server.service
journalctl -u phantom-server.service -n 50 -f

# Состояние keyring
cat /opt/phantom-vpn/config/clients.json | jq '.[] | {name,enabled,is_admin,last_seen_secs}'

# Admin API через VPN-туннель (с любого клиента в сети 10.7.0.0/24)
curl --cert client.crt --key client.key https://10.7.0.1:8080/api/status
curl --cert client.crt --key client.key https://10.7.0.1:8080/api/clients

# Loopback API (только на самом сервере — для Telegram-бота)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8081/api/status

# RU relay
ssh -i ~/.ssh/bot root@193.187.95.128
systemctl status phantom-relay
```

## Критичные pitfalls

- **`teardown_nat()` перед `setup_nat()`** — иначе на каждый рестарт копится
  дубль iptables-правил (`a55965c`, март 2026).
- **TUN name = `tun1`** — `tun0` может быть занят WireGuard; конфликт даёт молчаливый
  фейл при старте.
- **`admin_url` в keyring** хранится вместе с клиентом — нужен клиенту для `/api/me`,
  синхронизируется через conn_string.
- **Бинарь `phantom-server` + `phantom-keygen` рядом** — deploy-скрипт копирует оба;
  не оставлять keygen устаревшим, иначе `admin-grant` может не понять новый формат
  `clients.json`.
- **`cert_subjects` должен включать внешний DNS** (`tls.nl2.bikini-bottom.com`),
  иначе клиент отвергнет сертификат при SNI-матчинге через nginx stream.

## Релизный процесс

Сервер не тегается отдельно — релизится вместе с клиентом через тег `v*`:

```bash
# Сборка + деплой на vdsina (локально на vdsina'е)
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-server --bin phantom-server --bin phantom-keygen
install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server
install -m 0755 target/release/phantom-keygen /opt/phantom-vpn/phantom-keygen
systemctl restart phantom-server.service

# Проверить что поднялось
systemctl is-active phantom-server.service
journalctl -u phantom-server.service -n 30 --no-pager
```

Deploy-скрипт `server/scripts/deploy.sh` делает то же самое + рестарт + health-check.
Конфиг синхронизируется только если локально есть `config/server.toml`, иначе
заливается `server.example.toml` как шаблон (без перезаписи существующего
`config/server.toml` на сервере).

## Sources

- **Бинари:** [server/server/src/](../../../server/server/src/), [server/relay/src/](../../../server/relay/src/)
- **Конфиг:** [server/config/server.example.toml](../../../server/config/server.example.toml)
- **Deploy:** [server/scripts/deploy.sh](../../../server/scripts/deploy.sh), [setup-server.sh](../../../server/scripts/setup-server.sh)
- **Admin API детали:** [architecture/admin-api.md](../architecture/admin-api.md)
- **Transport / SNI relay:** [architecture/transport.md](../architecture/transport.md)
- **Sessions / passive DNS:** [architecture/sessions.md](../architecture/sessions.md)
- **Handshake:** [architecture/handshake.md](../architecture/handshake.md)
- **ADR:** [0001 remove QUIC](../decisions/0001-remove-quic.md), [0002 Noise → mTLS](../decisions/0002-noise-to-mtls.md), [0003 H2 multi-stream](../decisions/0003-h2-multistream-transport.md)
- **gitnexus:** `gitnexus_query({query: "server admin api"})`, `gitnexus_query({query: "phantom relay sni passthrough"})`, `gitnexus_impact({target: "setup_nat", direction: "upstream"})`
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
