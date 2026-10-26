---
updated: 2026-10-26
---

# Server — phantom-server + phantom-relay

## Стек

- **`phantom-server`** (`server/server/`) — TLS accept + VPN data plane + admin
  HTTP API + passive DNS cache + fakeapp fallback. Всё в одном
  бинаре, один `tokio::runtime` (multi-threaded).
- **`phantom-relay`** (`server/relay/`) — SNI passthrough на RU-хопе. **НЕ
  терминирует TLS** (v0.17.0+). Читает ClientHello → SNI → raw `copy_bidirectional`.
- **`phantom-keygen`** — CLI для bootstrap: CA generation, client cert issue,
  `admin-grant`. Отдельный бинарь, живёт рядом с `phantom-server`.
- Runtime: Tokio multi-threaded scheduler. TUN на сервере — `tun_uring` (io_uring,
  zero-copy через `Bytes` / `BytesMut`).

## Хосты

| Алиас | IP | Роль | DNS |
|---|---|---|---|
| `vdsina` | 89.110.109.128 | NL exit-нода (phantom-server `:8443` + nginx frontend) | `tls.nl2.bikini-bottom.com` |
| `vps_balancer` | 158.160.135.140 | **боевой RU relay** (phantom-relay `127.0.0.1:5443` за nginx) + 3x-ui панель + xray + headless phantom-client → SOCKS5 для 3x-ui outbound | `balancer.bikini-bottom.com`, `tls.nl2.bikini-bottom.com` (passthrough SNI) |
| — | 89.169.175.55 | резервный RU relay (`0.0.0.0:443` без nginx), из тракта выведен | `relay.bikini-bottom.com` |
| — | 193.187.95.128 | Прежний RU relay — выведен | — |

SSH: алиасы в `~/.ssh/config`. Claude Code работает на локальной машине,
на серверы ходит по SSH; деплой — скриптами из `server/scripts/`.

## Файловая раскладка

| Назначение | Путь |
|---|---|
| Runtime | `/opt/phantom-vpn/` |
| Бинарь | `/opt/phantom-vpn/phantom-server` (прежний — `phantom-server.prev`) |
| Keygen CLI | `/opt/phantom-vpn/phantom-keygen` |
| Конфиг | `/opt/phantom-vpn/config/server.toml` |
| Keyring (fingerprint → client) | `/opt/phantom-vpn/config/clients.json` |
| CA cert + key | `/opt/phantom-vpn/config/ca.crt`, `ca.key` |
| Per-client | `/opt/phantom-vpn/config/clients/<name>/client.crt`, `client.key` (ключи 0600, каталоги 0700) |
| Admin mTLS server cert (auto-gen) | `/opt/phantom-vpn/config/admin-server.crt`, `.key` |
| systemd unit | `/etc/systemd/system/phantom-server.service` |

## Сборка + деплой

С локальной машины, одной командой (на не-Linux хосте сборка идёт на сервере):

```bash
server/scripts/deploy.sh vdsina ~/.ssh/personal           # --dry-run третьим аргументом
```

Что делает `deploy.sh`:
- собирает `cargo build --locked --profile release-server` (`panic = "unwind"`) — локально на Linux
  или на сервере из того же набора файлов, что `docker/server/Dockerfile`;
- кладёт новые бинари рядом как `*.new`, сервис работает до последнего шага;
- `systemctl restart` сразу после атомарного `mv`, прежние бинари остаются `.prev`;
- ждёт до 15 с, пока сервис active, слушается порт `[h2].listen_addr` и (если задан
  `wan_iface`) стоит NAT-правило `phantom-vpn-*` — сервер ошибки iptables только логирует;
  если нет — **откатывает** бинари, unit и `server.toml` на `.prev` и выходит с ошибкой;
- unit с sandboxing: `NoNewPrivileges`, `CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
  CAP_NET_BIND_SERVICE`, `ProtectSystem=strict` (писать можно только в `config/` — keyring,
  admin-server.*, clients/ — и `/run` под `xtables.lock`), `ProtectHome`, `PrivateTmp`.
  Без `PrivateDevices`/`ProtectKernelTunables`: сервер сам открывает `/dev/net/tun` и
  пишет `ip_forward`. Если сервер пишет keyring вне `config/` — расширить `ReadWritePaths`.

Конфиг на хосте перезаписывается, только если локально есть `server/config/server.toml`;
иначе на чистый хост кладётся `server.example.toml` как `server.toml` (существующий не трогается).

Основной путь развёртывания нового exit — Docker ([ADR 0010](../decisions/0010-docker-deploy.md), `docker/server/`).

## Конфиг сервера

Пример — [server/config/server.example.toml](../../../server/config/server.example.toml). Ключевые поля:

```toml
[network]
listen_addr = "0.0.0.0:8443"
tun_name    = "tun1"          # не tun0 чтобы не конфликтовать с wg0
tun_addr    = "10.7.0.1/24"
tun_mtu     = 1350
wan_iface   = "eth0"          # для NAT/iptables; закомментировать чтобы отключить
public_addr = "<реле или exit>:<порт>"     # host:port в ghs:// ссылках
server_name = "tls.nl2.bikini-bottom.com"  # SNI в ghs:// ссылках

[h2]
listen_addr = "0.0.0.0:8443"  # транспорт; без [h2] сервер слушает :9443

[timeouts]
idle_timeout_secs = 300
hard_timeout_secs = 0          # 0 = без жёсткого лимита жизни сессии (по умолчанию)

[tls]                         # старое имя секции [quic] тоже понимается
cert_path = "/etc/letsencrypt/live/tls.nl2.bikini-bottom.com/fullchain.pem"
key_path  = "/etc/letsencrypt/live/tls.nl2.bikini-bottom.com/privkey.pem"
ca_cert_path         = "/opt/phantom-vpn/config/ca.crt"        # CA клиентских сертов (mTLS)
allowed_clients_path = "/opt/phantom-vpn/config/clients.json"  # allowlist, SIGHUP — перечитать

[admin]
listen_addr     = "10.7.0.1:8080"     # mTLS listener, только через VPN
token           = "..."                # break-glass bearer-token для бота
bot_listen_addr = "127.0.0.1:8081"     # loopback HTTP для Telegram-бота
# ca_cert_path / ca_key_path — для выпуска клиентских сертов через /api/clients
```

`keys.py` после каждой записи `clients.json` пишет файл атомарно и сам шлёт
`pkill -HUP -x phantom-server` — удаление/добавление клиента применяется сразу.

## Сертификат exit

Сервер читает LE-серт только при старте. На vdsina в
`/etc/letsencrypt/renewal/tls.nl2.bikini-bottom.com.conf` (`[renewalparams]`) должен быть
`renew_hook = systemctl restart phantom-server`, а с balancer раз в сутки по cron —
[`server/scripts/check-cert.sh`](../../../server/scripts/check-cert.sh) (срок серта, который
`:8443` реально отдаёт; ненулевой код за 14 дней до истечения). Подробно — [build.md](../build.md#сертификат-exit-продление-и-контроль-срока).

Admin-server cert для mTLS listener'а — self-signed на `10.7.0.1`, генерится при
первом старте. Клиенты пиннят SHA-256 (TOFU, см. `VpnProfile.cachedAdminServerCertFp`
на Android / `VpnProfile` в PhantomKit).

Подробности протокола admin API — см. [admin-api.md](../architecture/admin-api.md).

## NAT / iptables

При каждом старте `phantom-server`:

1. `teardown_nat()` — удаляет старые правила (если остались от прошлого запуска).
2. `setup_nat()` — проверяет, что `wan_iface` существует, включает
   `ip_forward` и ставит правила (все с комментарием `phantom-vpn-<tun>`,
   вставляются в начало цепочек):
   - `nat POSTROUTING`: MASQUERADE (или SNAT на `exit_ip`) для tun-подсети;
   - `FORWARD -i tun`: DROP в приватные диапазоны (10/8, 172.16/12, 192.168/16,
     100.64/10, 169.254/16), кроме DNAT-трафика (опубликованные docker-порты
     сервисов на exit), REJECT на tcp/25, дальше ACCEPT tun ⇄ wan;
   - `INPUT -i tun -d <tun-подсеть>`: established, icmp, порт admin API (из
     `[admin].listen_addr`), 22, 53 — остальное DROP. Публичные адреса exit'а
     из туннеля доступны так же, как из интернета (сайты на самом exit работают).

Любая ошибка iptables/sysctl фатальна: сервер не стартует (systemd покажет
причину), а не поднимается «с подключением, но без интернета».

Зачем teardown: коммит `a55965c` (март 2026) — без него iptables копились
дубликаты при каждом рестарте. Список правил один и тот же для setup и teardown.

## Соединения, таймауты, доступ

- **Allowlist** (`allowed_clients_path`) проверяется прямо в TLS-рукопожатии:
  отозванный или удалённый клиент получает alert `certificate_revoked`.
  Путь задан → пускаем ровно включённых клиентов из keyring; пустой список =
  никого. Нечитаемый файл на старте → сервер не стартует (клиенты видят сетевую
  ошибку и ретраят, а не `certificate_revoked`). Путь не задан = любой серт
  нашего CA. Keyring перечитывается раз в минуту и по SIGHUP — правки
  `keys.py` подхватываются без рестарта.
- **Туннельный IP** берётся из keyring по отпечатку серта; пакеты с чужим
  src отбрасываются. Отзыв/удаление вытесняют сессию по отпечатку (обе карты,
  `close()` → RX-циклы перестают пускать uplink, writer'ы шлют FIN).
- Таймауты: TLS-рукопожатие + 2-байтовый заголовок — 10 с; поток без единого
  кадра от клиента — 150 с; close_notify+FIN после writer'а — 5 с; fakeapp — 45 с
  на соединение. Heartbeat сервера — случайно 30–40 с на каждый стрим
  (не 60: клиенты v0.24–v0.26 рвут стрим после 45 с тишины).
- Первые 10–20 кадров каждого стрима дополняются нулями до случайного размера
  (после терминатора батча — wire-формат прежний).
- Таймауты сессий идут по монотонным часам; проверка подписок пропускает тик,
  если системные часы прыгнули больше чем на час.
- **Живучесть процесса.** Ошибка `accept()` (EMFILE и т.п.) не убивает листенер:
  warn, пауза 100 мс, цикл дальше. Паника в одном соединении (профиль
  `release-server`, `panic = "unwind"`) роняет только его. Паника в потоках
  io_uring, выход accept-цикла или TUN-диспетчера роняют процесс целиком —
  systemd его поднимает, полумёртвым сервер не висит. `IFF_TUN_EXCL`: второй
  экземпляр (например, Docker рядом с systemd) к боевому `tun1` не цепляется.

## nginx frontend (NL)

Перед `phantom-server` на vdsina стоит nginx как **stream SNI preread** на `:443`:

- SNI == `tls.nl2.bikini-bottom.com` → passthrough на `127.0.0.1:8443` (phantom-server).
- Любой другой SNI → LE-cert fallback HTTPS (выглядит как обычный веб-сайт).

Это даёт двойную страховку: `phantom-server` может остаться на нестандартном
порту, а внешний probe видит валидный TLS-сертификат, выданный Let's Encrypt.
В боевом тракте этот nginx не участвует: `:443` vdsina из РФ фильтруется, реле
ходит прямо на публичный `:8443`.

## Relay — SNI Passthrough (RU, v0.17.0+)

`phantom-relay` на RU-хопе (`balancer.bikini-bottom.com`, `158.160.135.140` —
vps_balancer) **не терминирует TLS**. Псевдокод логики:

```rust
let hello = read_client_hello(socket).await?;   // до 16 КБ, склеивает TLS-записи
let sni = extract_sni(&hello)?;

if sni == expected_sni {
    // прочитанные байты отдаются exit'у как есть, дальше сырой поток —
    // TLS handshake end-to-end между телефоном и NL phantom-server
    upstream.write_all(&hello).await?;
    copy_bidirectional(socket, upstream).await?;
} else if let Some(acc) = build_fallback_acceptor()? {   // серт с диска — на каждое соединение
    serve_fallback(socket, acc).await?;          // ответ как у стокового nginx
} else {
    /* drop — за nginx stream чужой SNI сюда не доходит */
}
```

Поведение и лимиты:

- **Не больше 8192 соединений одновременно** (семафор; passthrough держит два fd
  при `LimitNOFILE=65536` / docker `nofile 65536`). Упор в лимит пишется в лог.
  Ошибка `accept()` логируется, цикл продолжается.
- **Предварительная фаза — 10 с на всё**: чтение ClientHello, а для fallback —
  TLS-рукопожатие и HTTP-обмен. Висящий коннект с одним байтом больше не держит
  сокет вечно.
- **Connect к exit** — резолв `upstream_addr` на каждом соединении, перебор всех
  адресов, 5 с на попытку. Переезд exit — правка DNS. Кривой `upstream_addr`
  (без порта) валит старт, а не каждое соединение.
- **Passthrough закрывается целиком**, как только закрылась одна сторона —
  молчащий клиент не держит соединение и слот лимита после ухода exit'а.
- **Fallback отвечает как nginx** без сайта: ALPN только `http/1.1`, 404 на
  HTTP-запрос, 400 на мусор, HEAD — только заголовки, `Server: nginx` и `Date`.
- **Fallback-серт перечитывается на каждом fallback-соединении** (они редкие) —
  продление certbot'ом подхватывается без рестарта. `renew_hook` с рестартом
  реле, который рвал все живые стримы, больше не нужен (на хостах — после деплоя
  нового бинаря). `fallback_host` в конфиге больше не нужен.
- **Журнал** — IP клиентов только на DEBUG; обрыв с ошибкой пишется ошибкой, а не
  `up=0B down=0B`.

Почему:
- До v0.17 был double-TLS (RU terminate → NL terminate) — RU был CPU-bound на
  AES-GCM. Теперь RU чисто I/O-bound, держит в разы больше соединений.
- Fallback с LE-cert нужен для того чтобы на внешний probe (без нужного SNI) RU
  выглядел как обычный HTTPS-сайт → не палимся активным сканированием.

End-to-end TLS: phone-side рукопожатие идёт напрямую в NL phantom-server, relay
видит только зашифрованные байты. Подробно — [transport.md](../architecture/transport.md#sni-passthrough-relay).

### Развёртывание (v0.22.x+, behind nginx)

vps_balancer уже хостит 3x-ui + nginx с SNI-routing на `:443`. Чтобы не
ломать панель, relay сидит на **`127.0.0.1:5443`**, а nginx-stream добавляет
SNI-запись в map:

```nginx
stream {
    map $ssl_preread_server_name $backend {
        balancer.bikini-bottom.com         web;
        panel.balancer.bikini-bottom.com   web;
        relay.bikini-bottom.com            phantom_relay;
        tls.nl2.bikini-bottom.com          phantom_relay;   # SNI клиентов
        default                            xray;            # 3x-ui Reality
    }
    upstream phantom_relay { server 127.0.0.1:5443; }
    server { listen 443; proxy_pass $backend; ssl_preread on; }
}
```

Деплой: `server/scripts/deploy-relay.sh vps_balancer ~/.ssh/<key>` — сборка
`--locked --profile release-server` (на не-Linux хосте — на самом реле, из того же
набора файлов, что `docker/relay/Dockerfile`), новый бинарь кладётся как `.new`,
реле останавливается только на `mv` + restart.

**`relay.toml` на хосте деплой не перезаписывает никогда**: у balancer
`127.0.0.1:5443` за nginx, у .55 — `0.0.0.0:443`, общий файл уронил бы боевое реле.
На чистый хост кладётся [server/relay/relay.example.toml](../../../server/relay/relay.example.toml)
как `relay.toml` — отредактировать и `systemctl restart phantom-relay`.
`server/relay/relay.toml` в репо — конфиг .55, на другие хосты не льётся.
Cert/key в TOML опциональны — если nginx уже фильтрует SNI, fallback в relay
никогда не сработает; оставляем для прямой доступности (`:443` бывших
standalone-хостов).

Unit реле — без `--verbose`, логи в своём journald-namespace (`LogNamespace=phantom-relay`,
`/etc/systemd/journald@phantom-relay.conf` с `MaxRetentionSec=1day` + `MaxFileSec=1day`,
то есть не дольше ~2 суток): в них адреса
клиентов, а общий журнал хоста (xray/3x-ui на balancer) не трогаем. Нужен systemd ≥ 245.
Смотреть: `journalctl --namespace=phantom-relay -f`.

### Headless phantom-client + microsocks (для 3x-ui SOCKS5 outbound)

vps_balancer ещё запускает локальный `phantom-client-linux`, чтобы 3x-ui
мог переключать инбаунды на NL exit через SOCKS5:

```
xray inbound → outbound socks 127.0.0.1:10808
                ↑ microsocks (uid 996, phantom-proxy.service)
                ↑ ip rule: from uidrange 996 lookup table 51820
                ↑ table 51820 default dev tun0
                ↑ phantom-client → tls.nl2.bikini-bottom.com:8443 (NL phantom-server; :443 из РФ фильтруется)
```

Критичная деталь: с v0.22 клиент по умолчанию ставит **глобальный route-hijack**
(rules 32764/32765, table 51820 default dev tun0). На headless-боксе это
ломает egress всего хоста (xray Reality, nginx). Поэтому в `phantom-client.service`
выставлен `Environment=PHANTOM_NO_DEFAULT_ROUTE=1` — флаг, который пропускает
`add_default_route` в `apps/linux/cli/src/main.rs`. ExecStartPost потом
добавляет узкое правило только для uid 996.

Конфиг клиента — `--conn-string-file /etc/phantom-vpn/conn_string` (TOML
больше не поддерживается клиентским рантаймом). Conn-string выпускается
admin API: `POST /api/clients` + `GET /api/clients/<name>/conn_string`.

## Admin HTTP API — коротко

Встроен в `phantom-server`. Два listener'а (v0.19+):

| Listener | Bind | Транспорт | Auth | Для кого |
|---|---|---|---|---|
| mTLS | `[admin].listen_addr` = `10.7.0.1:8080` | HTTPS + mTLS | client cert → fingerprint → `is_admin` | Android/Linux admin panel через VPN |
| loopback | `[admin].bot_listen_addr` = `127.0.0.1:8081` | plain HTTP | `Authorization: Bearer <token>`, только с loopback-адреса | Telegram-бот (same-host only) |

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

# RU relay (vps_balancer)
ssh vps_balancer
sudo systemctl status phantom-relay phantom-client phantom-proxy
sudo journalctl --namespace=phantom-relay -f              # passthrough events (хранятся ≤2 суток)
sudo ss -tnp | grep ':5443\|89.110.109.128:8443'         # active tunnels

# Sanity check that nginx SNI routing didn't break 3x-ui:
echo | openssl s_client -connect 158.160.135.140:443 \
  -servername balancer.bikini-bottom.com -tls1_3 2>/dev/null \
  | openssl x509 -noout -subject       # → CN=balancer.bikini-bottom.com (LE)

# Verify SOCKS5 bridge for 3x-ui:
ssh vps_balancer "curl -s -x socks5h://127.0.0.1:10808 https://ifconfig.me"
# → 91.84.109.85 (NL exit), а прямой curl → 158.160.135.140 (box egress)
```

## Критичные pitfalls

- **`teardown_nat()` перед `setup_nat()`** — иначе на каждый рестарт копится
  дубль iptables-правил (`a55965c`, март 2026).
- **TUN name = `tun1`** — `tun0` может быть занят WireGuard; конфликт даёт молчаливый
  фейл при старте.
- **Адрес админки клиент вычисляет сам** — `.1` своей tun-подсети, порт 8080
  (`https://10.7.0.1:8080`); ни в keyring, ни в строке подключения его нет.
- **Бинарь `phantom-server` + `phantom-keygen` рядом** — deploy-скрипт копирует оба;
  не оставлять keygen устаревшим, иначе `admin-grant` может не понять новый формат
  `clients.json`.
- **`cert_subjects` должен включать внешний DNS** (`tls.nl2.bikini-bottom.com`),
  иначе клиент отвергнет сертификат при SNI-матчинге через nginx stream.

## Релизный процесс

Сервер не тегается отдельно — релизится вместе с клиентом через тег `v*`
(бинари `phantom-server`/`phantom-keygen` в GitHub Release, образы в ghcr.io).
На vdsina выкатывается `server/scripts/deploy.sh` (см. «Сборка + деплой» выше):
health-check по порту `[h2]` и NAT-правилу и автоматический откат встроены. После первого
деплоя с sandbox-unit проверить руками: `iptables -t nat -S POSTROUTING | grep phantom-vpn`
и реальный трафик через туннель.

```bash
# Проверить что поднялось (на сервере)
systemctl is-active phantom-server.service
journalctl -u phantom-server.service -n 30 --no-pager
```

## Sources

- **Бинари:** [server/server/src/](../../../server/server/src/), [server/relay/src/](../../../server/relay/src/)
- **Конфиг:** [server/config/server.example.toml](../../../server/config/server.example.toml), [server/relay/relay.example.toml](../../../server/relay/relay.example.toml)
- **Deploy:** [server/scripts/deploy.sh](../../../server/scripts/deploy.sh) (server), [server/scripts/deploy-relay.sh](../../../server/scripts/deploy-relay.sh) (relay), [server/scripts/check-cert.sh](../../../server/scripts/check-cert.sh) (срок серта), Docker — [docker/](../../../docker/) ([ADR 0010](../decisions/0010-docker-deploy.md))
- **Admin API детали:** [architecture/admin-api.md](../architecture/admin-api.md)
- **Transport / SNI relay:** [architecture/transport.md](../architecture/transport.md)
- **Sessions / passive DNS:** [architecture/sessions.md](../architecture/sessions.md)
- **Handshake:** [architecture/handshake.md](../architecture/handshake.md)
- **ADR:** [0001 remove QUIC](../decisions/0001-remove-quic.md), [0002 Noise → mTLS](../decisions/0002-noise-to-mtls.md), [0003 H2 multi-stream](../decisions/0003-h2-multistream-transport.md)
- **gitnexus:** `gitnexus_query({query: "server admin api"})`, `gitnexus_query({query: "phantom relay sni passthrough"})`, `gitnexus_impact({target: "setup_nat", direction: "upstream"})`
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
