---
name: GhostStream v2 HTTP/2 transport plan
description: Architecture plan for adding TCP/TLS+HTTP/2 transport to bypass TSPU QUIC throttling — phases, key decisions, file map
type: project
---

# GhostStream v2: HTTP/2 транспорт

**Why:** ТСПУ дросселит QUIC до 80 Mbps на потребительских каналах. TCP/TLS не дросселируется (567 Mbps).
**How to apply:** Добавить HTTP/2 как второй транспорт. QUIC остаётся для DC↔DC, HTTP/2 для телефонов.

## Ключевые решения

1. **HTTP/2 а не HTTP/3** — HTTP/3=QUIC, а QUIC дросселируется. HTTP/2=TCP.
2. **Крейт `h2` а не `hyper`** — нужен контроль над lifecycle стримов для bidirectional streaming.
3. **8 HTTP/2 стримов** — та же идея что 8 QUIC streams, меньше HOL blocking.
4. **gRPC камуфляж** — `Content-Type: application/grpc`, POST /v1/tunnel/{idx}. Выглядит как gRPC-сервис.
5. **Protobuf-контейнер** — опционально, +5 байт overhead, полная мимикрия под gRPC. Не в первой итерации.
6. **WebSocket** — будущий fallback для CDN-проксирования (Cloudflare). Не в первой итерации.

## Фазы

- **Фаза 0:** Извлечь VpnSession из QuicSession (transport-agnostic session types)
- **Фаза 1:** HTTP/2 сервер (h2_server.rs, h2_transport.rs) — TCP:443 рядом с UDP:8443
- **Фаза 2:** Linux клиент HTTP/2 (h2_tunnel.rs, h2_handshake.rs) — тест на vps_balancer
- **Фаза 3:** Android клиент HTTP/2 — JNI + protect(tcp_fd) + Kotlin UI
- **Фаза 4:** Auto-negotiation (будущее)
- **Фаза 5:** gRPC protobuf-контейнер (опциональный тюнинг, будущее)

## Новые зависимости

- `h2 = "0.4"` — HTTP/2 framing
- `tokio-rustls = "0.26"` — TLS для TCP
- `socket2 = "0.5"` — для Android TCP socket creation + protect()

## Полный план

Детали в `other_docs/PLAN_v2_transport.md`
