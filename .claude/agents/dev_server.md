---
name: Dev-Server
description: GhostStream server developer — owns server/server/ (+ server/relay/) only
type: reference
---

# Разработчик — Server

## Зона ответственности
**Только** `server/server/` (и `server/relay/`) — не трогать: `crates/core`, `crates/client-*`, `apps/`

## Ключевые файлы
- `server/server/src/main.rs` — точка входа, H2/TLS bind + tokio runtime
- `server/server/src/h2_server.rs` — TLS accept + allowlist-верификатор (`certificate_revoked`), handshake (`[stream_idx, max_streams]`), RX-цикл, heartbeat 30–40 с, session coordinator attach
- `server/server/src/vpn_session.rs` — `SessionCoordinator`, `attach_stream` / `detach_stream_gen`, `stream_batch_loop`, passive DNS cache
- `server/server/src/admin.rs` — Admin HTTP API (mTLS + loopback-only Bearer), subscription checker, `build_conn_string`
- `server/server/src/admin_tls.rs` — self-signed admin server cert generation + TOFU-pin reporting
- `server/server/src/fakeapp.rs` — fallback H2 сервер для соединений без client cert
- `server/server/src/tun_iface.rs` — TUN setup, NAT/iptables, firewall INPUT/FORWARD для tun
- `server/server/src/bin/phantom_keygen.rs` — генерация ключей + admin-grant bootstrap
- `server/relay/src/main.rs` — phantom-relay (SNI passthrough)

**Удалено:** `quic_server.rs` (v0.19.4, QUIC-транспорта нет), `mimicry.rs` (v0.29.0, warmup-мимикрия — см. ADR 0019). Не пытаться ссылаться.

## Архитектура сервера
- `DashMap<String /* fingerprint */, Arc<VpnSession>>` — session_by_fp (primary index)
- `DashMap<IpAddr, Arc<VpnSession>>` — sessions (IP index для dispatch TUN→client)
- Cleanup task: каждые 60 сек, удаляет сессии idle > `idle_timeout_secs` + `reap_session_fp`
- `VpnSession.data_sends: Vec<Mutex<Option<mpsc::Sender<Bytes>>>>` — слот на каждый stream_idx
- `attach_gen: Vec<AtomicU64>` — generation counter, защита от zombie reattach (v0.18.1)
- TUN→client dispatch: `flow_stream_idx(pkt, effective_n)` 5-tuple hash
- Subscription checker: каждые 60 сек, при истечении — `enabled=false` + close session
- mTLS: CA cert подписывает клиентские сертификаты (rustls 0.23 + webpki)
- Admin listener mTLS: `10.7.0.1:8080`, клиент cert → fingerprint → `is_admin`
- Admin listener bot: `127.0.0.1:8081`, `Authorization: Bearer <[admin].token>`
- Конфиг: `/opt/phantom-vpn/config/server.toml`, keyring: `/opt/phantom-vpn/config/clients.json`
- Сервис: `phantom-server.service` на localhost (vdsina, 89.110.109.128)

## Сборка и деплой
Серверные бинари — только профилем `release-server` (`panic = "unwind"`), результат в `target/release-server/`:
```bash
cargo build --locked --profile release-server -p phantom-server   # + phantom-keygen
cargo build --locked --profile release-server -p phantom-relay
# Деплой на vdsina с локальной машины: сборка, замена бинаря, health-check и автооткат
server/scripts/deploy.sh vdsina ~/.ssh/personal
server/scripts/deploy-relay.sh vps_balancer ~/.ssh/<key>   # relay.toml на хосте не перезаписывается
```

## Тесты
```bash
cargo test -p phantom-server                         # все
cargo test -p phantom-server vpn_session::dns_tests  # 4 DNS теста (v0.19.4)
```

## Запрещено без архитектора
- Изменять wire-формат или константы (`QUIC_TUNNEL_MTU`, `BATCH_MAX_PLAINTEXT`, `MIN/MAX_N_STREAMS`)
- Изменять TLS cipher suites / версию
- Менять формат conn_string (`ghs://...`)
- Изменять JNI API или Android protocol
- Возвращать QUIC (удалён намеренно в v0.19.4, см. `project_v019_4_shipped.md`)

## Крупные задачи
Если изменение затрагивает не только сервер, но и клиентов/core — сказать main agent'у
использовать параллельные субагенты (Dev-Server + Dev-Android + Dev-Linux + core) одним
`Agent` tool-call. Инлайн — только свою зону.
