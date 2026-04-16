---
name: Detection vectors 11-13 — timing jitter, heartbeat, connection migration
description: Three additional TSPU detection vectors beyond the 10 in project_ghoststream_v018_detection_vectors.md, with severity and v0.19/v0.20 remediation
type: reference
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
Supplements project_ghoststream_v018_detection_vectors.md. Those 10 vectors are the v0.18 focus; these three are longer-tail signals that matter for v0.19/v0.20 planning. Discussed 2026-04-11 with user.

# Вектор 11. Inter-batch timing jitter

**Что видит ТСПУ:** per-flow гистограмма inter-arrival time между TLS records. Реальный HTTPS — рваный шаблон (burst → пауза на чтение/скролл → burst). GhostStream — почти равномерное распределение, потому что дропаем `tun_uring → tls_write` без искусственных пауз.

**Severity:** 🟡 умеренный. В РФ публично не используется (дорого держать per-flow state на терабайтах), но CN GFW экспериментирует с 2023.

**Лечение v0.20:** расширить `crates/core/src/shaper.rs` — уже умеет LogNormal для размеров, добавить artificial inter-batch delay тоже LogNormal (μ≈3.3, σ≈1.2 → медиана ~27 ms, tail до 500 ms). Цена: 5-10% throughput, browser-like timing profile.

# Вектор 12. Dummy / heartbeat frames

**Что видит ТСПУ:** idle-пользователь = полное молчание внутри TLS на 30+ сек. Нетипично для «живого» приложения — реальный WhatsApp/Telegram шлёт keepalive раз в 5-15 сек, HLS-плеер качает сегменты каждые 2-6 сек. TSPU в 2025 уже флагала долгое молчание внутри установленного TLS.

**Severity:** 🟡 умеренный и ускоряется.

**Лечение v0.20:** добавить `heartbeat_loop` и в `h2_server.rs`, и в клиент: раз в 3-7 сек (jitter) отправлять batch с одним dummy-пакетом 40-200 байт. Нужен sentinel в wire-формате — переиспользовать тот же приём, что у mimicry warmup (битый IPv4 header, `tls_rx_loop` молча дропает на клиенте).

# Вектор 13. Connection migration (TCP re-handshake при смене network)

**Что видит ТСПУ:** Wi-Fi ↔ LTE переключение рвёт TCP, клиент делает новый TLS handshake к тому же `vdsina:443` через 200 ms. У реального HTTPS при миграции обычно меняется destination (Wi-Fi → ближайший CDN edge, LTE → другой edge) — destination остаётся неизменным только у VPN-like сервисов.

**Severity:** 🟡 умеренный. Пересекается с векторами 2 (rate anomaly) и 9 (parallel conn correlation) из основного списка.

**Лечение:**
- Частично решается multi-origin (v0.19): при миграции клиент выбирает другой exit из пула, destination меняется, выглядит как CDN re-resolve.
- Дополнительно в v0.19+: session continuity token в in-band auth payload — сервер узнаёт того же пользователя без mTLS-cert, клиент переживает миграцию без full re-auth.

# Связь с остальной моделью угроз

- Векторы 1-10 в `project_ghoststream_v018_detection_vectors.md` — то, что v0.18 уже частично закрывает (7 из 10).
- Векторы 11-13 здесь — low-severity сейчас, но могут «включиться» в любой момент если ТСПУ прикрутит timing/heartbeat эвристики. Не трогать до v0.20, но держать в плане.
- RBT (A2, rbt.rs) сам по себе НЕ помогает против 11-13 — он про «volume per connection», не про timing внутри flow.

**How to apply:** когда пользователь спросит «что ещё могут спалить», отвечать по этим трём + по `project_ghoststream_v018_detection_vectors.md`. Для v0.19 приоритет остаётся: in-band auth → multi-origin → RBT. Векторы 11-13 — строго после этого.
