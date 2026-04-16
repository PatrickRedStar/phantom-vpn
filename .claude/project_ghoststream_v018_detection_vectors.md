---
name: GhostStream v0.18 full list of 10 detection vectors with severity
description: Detailed breakdown of every way v0.18 can still be detected/blocked, severity assessment, and what v0.19 needs to fix
type: project
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
Supplement to project_ghoststream_v018.md. Read that first.

# 10 векторов детекции v0.18

Каждый вектор: что видит ТСПУ, уровень риска, что делать сейчас / потом.

## 🔴 Критические (нелеченные в v0.18)

### Вектор 1. mTLS client certificate — ГЛАВНАЯ ДЫРА

В TLS ClientHello шлём `Certificate` handshake message. Реальные мобильные/браузерные HTTPS-клиенты **почти никогда** этого не делают. mTLS используется в B2B API, enterprise VPN, corp SSO. Эвристика «ClientHello с client cert к публичному IP → подозрение» палит ВСЕ GhostStream-коннекты.

**Уровень:** 🔴 критический
**Лечение v0.19:** отказаться от mTLS, аутентифицировать клиента ВНУТРИ TLS payload: первые N байт encrypted body = `HMAC(shared_secret, timestamp) || client_id`. Сервер валидирует, неверный → fake app-face.

### Вектор 2. Connection rate anomaly

8-коннект пул + ротация на 10 KB + 500 Mbit/s = 6250 новых TLS-коннектов в секунду к одному IP. Реальные мобильные приложения делают 5-20 новых conn/sec. Mobile operators уже имеют rate-limit эвристики.

**Уровень:** 🔴 критический
**Лечение:** trade-off. Либо большее `RBT_MAX_PAYLOAD` (рискуем 15-20KB), либо больший pool (рискуем parallel correlation), либо jitter delays (режем throughput). В v0.19 — multi-origin shard распределяет rate по нескольким IP.

### Вектор 3. Volume-to-IP anomaly

500 Mbit/s к одному IP = больше всего остального интернет-трафика абонента. Видно статистикой независимо от DPI. Любой single-exit VPN страдает.

**Уровень:** 🔴 критический
**Лечение v0.19:** multi-origin shard, клиент распределяет трафик между N серверов в разных AS. Выглядит как CDN-usage.

## 🟠 Серьёзные

### Вектор 4. JA4 rustls fingerprint

rustls default ClientHello имеет узнаваемый JA4 (cipher suite order, extensions). Не похож ни на OkHttp, ни на Chrome, ни на Safari.

**Уровень:** 🟠
**Лечение v0.20:** utls-style fingerprint spoofing, rustls-uwu или chrome-fingerprint crate.

### Вектор 5. Fake app-face quality

ТСПУ active probe на `89.110.109.128:443`:
- `GET /` → HTML?
- `GET /favicon.ico` → PNG?
- `GET /robots.txt` → text?
- `GET /.well-known/*` → 404 OK
- `GET /manifest.json` → JSON

В матрице v0.18 — статичные ответы. Нужно **несколько** эндпоинтов с правдоподобным контентом: SPA HTML (+JS bundle imitation), favicon, /privacy, /terms, /api/v1/health.

**Уровень:** 🟠
**Лечение в v0.18:** расширить `fakeapp.rs` до 6-8 эндпоинтов.

### Вектор 6. TLS session timing

Реальный мобильный HTTPS: ~150-300 ms до первого app-data. rustls: ~40-80 ms.

**Уровень:** 🟠
**Лечение:** искусственная серверная задержка 50-100 ms перед first app-data. Латентность растёт, но не критично.

### Вектор 7. Deep content inspection (MITM)

Если ТСПУ дешифрует TLS (через govroot MITM — уже законопроект), увидит POST `/api/v1/telemetry` с бинарным payload вместо JSON/Protobuf.

**Уровень:** 🟠 (не применяется массово, но legally прописано)
**Лечение:** обернуть binary в JSON Base64, `{"events":[{"data":"<base64>",...}]}`. Overhead 33%.

## 🟡 Умеренные

### Вектор 8. IP↔DNS correlation

ТСПУ: SNI=tls.nl2.bikini-bottom.com → DNS resolve → 89.110.109.128 → OK. Но:
- Клиент не делал DNS resolve перед connect (pre-resolved в profile) → подозрительно
- PTR 89.110.109.128 → `ovc.r133.vdsina.net` ≠ SNI → подозрительно

**Уровень:** 🟡
**Лечение в v0.18:** клиент делает системный DNS запрос на tls.nl2.* перед каждым новым коннектом (рыхло, но это signal). Настроить правильный PTR на IP.

### Вектор 9. Parallel connection correlation

8 параллельных TCP коннектов, стартуют с разницей в мс, все в один IP+SNI. Мобильные приложения делают параллельные, но к **разным** хостам (CDN + API + analytics).

**Уровень:** 🟡
**Лечение в v0.18:** jitter на старт каждого коннекта пула (+-50-200 ms), сдвинутые warmup периоды.

### Вектор 10. ALPN / Host / User-Agent

- ALPN сейчас `http/1.1` в плане → современные мобильные почти всегда `h2`. Нужно либо ALPN h2 + H2 frames (тяжелее), либо `http/1.1` с признаниями «legacy API».
- Host header = SNI = OK
- User-Agent нельзя оставить `curl/` или `phantom/`. Нужен правдоподобный: `okhttp/4.12.0` или `Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/...`

**Уровень:** 🟡
**Лечение в v0.18:** захардкодить правдоподобный User-Agent в rbt_client; продумать ALPN.

---

# Сводная матрица защит

| Защита от | v0.17.2 | v0.18 | v0.19 | v0.20 |
|---|---|---|---|---|
| 15-20KB TCP lockout | ❌ | ✅ RBT | ✅ | ✅ |
| TLS+hammer heuristic | ❌ | ✅ warmup | ✅ | ✅ |
| UDP/443 блок | ✅ | ✅ | ✅ | ✅ |
| WG magic byte | ✅ | ✅ | ✅ | ✅ |
| mTLS fingerprint | ❌ | ❌ | ✅ in-band auth | ✅ |
| Volume-to-IP | ❌ | ❌ | ✅ multi-origin | ✅ |
| Connection rate | ❌ | ❌ | ✅ multi-origin | ✅ |
| JA4 rustls | ❌ | ❌ | ❌ | ✅ utls |
| Fake app quality | ❌ | ✅ частично | ✅ | ✅ |
| DNS correlation | ✅ | ✅ | ✅ | ✅ |
| Parallel conn correlation | ❌ | ✅ jitter | ✅ | ✅ |
| ALPN/UA | ❌ | ✅ | ✅ | ✅ |

v0.18 закрывает 7 из 12. v0.19 — ещё 3 (главные дыры). v0.20 — последний штрих (JA4).
