# CHANGELOG

> Линейная история релизов PhantomVPN / GhostStream. Для перформанс-замеров см. [ROADMAP.md](ROADMAP.md), для архитектурного контекста — [ARCHITECTURE.md](ARCHITECTURE.md).

## v0.18.2 — 2026-04-12

* **Detection vector 12 (idle heartbeat frames)** — на idle стримах каждые 20–30с отправляется случайный 40–200B dummy frame с sentinel-версией `0x0`. Имитирует keepalive обычного мобильного клиента, закрывает вектор «стрим стоит молча N минут».
* **Telegram admin bot** (`tools/telegram-bot/`) — single-admin Python bot над admin HTTP API, Docker-deployable. Роли admin/regular хранятся локально, для regular вырезается поле `admin` из conn_string перед отправкой клиенту.
* **GitHub Actions:** в релизные артефакты добавлены `phantom-server` и `phantom-keygen` (раньше релизились только клиенты).
* **Docs refresh:** README/ARCHITECTURE/ROADMAP переписаны под текущее состояние v0.18+ с сохранением исторического контекста QUIC-эры.

## v0.18.1 — 2026-04-11

* **Multi-stream handshake negotiation** — клиент отправляет `[stream_idx, max_streams]` при открытии каждого стрима, `effective_N = min(server_N, client_N)`. Автоматическая деградация если у одной стороны меньше ядер.
* **Zombie session eviction** — явный generation counter в `SessionCoordinator`, стрим из старого generation не может «оживить» уже освобождённую сессию.

## v0.18.0 — 2026-04-10

* **Mimicry warmup** — первые ~2 секунды сессии пишется staged последовательность «HTML → image → image → bundle» с 50KB бюджетом, закрывает detection vector 6 (traffic burst pattern). Раньше после TLS handshake был instant VPN hammering — явный сигнал для DPI.

## v0.17.2 — 2026-04-10

* **Parallel per-stream batch loops** на сервере — download с одного клиента вырос с 138 → 625 Mbit/s (4.5×). Раньше serial `session_batch_loop` был single-CPU bottleneck; теперь каждый стрим крутит свой batch loop на своём ядре.

## v0.17.1-checkpoint-tx-ceiling — 2026-04-09

* Checkpoint: H2 multi-stream транспорт закреплён, RU relay переведён на SNI passthrough. TX ceiling в serial session loop диагностирован — исправление в v0.17.2.

## v0.15.0–v0.15.8 — H2 migration + iOS

* **v0.15.0** — GhostStream iOS app + CI release pipeline (iOS удалён позже, см. ниже).
* **v0.15.1–v0.15.8** — серия фиксов iOS-сборки и CI: платформа, индентация, plist, iOS 17 onChange → iOS 16. **iOS впоследствии удалён из дерева** (проект сфокусирован на Android).
* В этих же версиях — первый рабочий HTTP/2 + TLS 1.3 транспорт поверх TCP как основной, с fallback на QUIC. См. [other_docs/PLAN_v2_transport.md](other_docs/PLAN_v2_transport.md).

## v0.14.0–v0.14.1 — Android UX

* **v0.14.0** — аудит и улучшения UX/функционала.
* **v0.14.1** — UX overhaul + split-routing стабильность.

## v0.12.0–v0.13.0 — Glassmorphism UI

* **v0.12.0** — новый Android UI по дизайну VPN_UI.html.
* **v0.13.0** — полный glassmorphism UI.

## v0.11.0–v0.11.1

* **v0.11.0** — AGP 8.9.1, Kotlin 2.1.20, armeabi-v7a, glass UI.
* **v0.11.1** — DNS reconnect + clipboard crash fix.

## v0.10.0–v0.10.2

* **v0.10.0** — TV pairing via QR code.
* **v0.10.1** — Android TV совместимость.
* **v0.10.2** — liquid glass navbar + ProfileRow fix.

## v0.9.0 — 2025

* Ping measurements, subscription status в UI, log hierarchy, debug share.

## v0.8.0–v0.8.9 — Admin panel era

* **v0.8.0** — cleanup.
* **v0.8.1** — CA cert TLS, VpnState timing, logs UI, DEBUG log level.
* **v0.8.2** — DNS resolution для hostname в server addr; CA удалён из conn string.
* **v0.8.3** — multi-profile connections (v2rayTun style).
* **v0.8.4** — version display из BuildConfig, updated system apps в per-app picker.
* **v0.8.5** — auto-reconnect on VPN drop + увеличенный QUIC idle timeout.
* **v0.8.6** — **Admin HTTP panel** (server + Android UI).
* **v0.8.7** — `adminUrl` / `adminToken` сериализуются в `ProfilesStore` (раньше терялись при сохранении).
* **v0.8.8** — admin panel polish, dest logging, time-series stats, client filters.
* **v0.8.9** — bump versionCode=15.

## v0.7.0

* Base64 connection string auth across all platforms.

## v0.6.0–v0.6.1

* **v0.6.0** — IP-based split routing + per-app VPN.
* **v0.6.1** — fingerprint-based client allowlist + musl cross-compilation.

## v0.5.0

* Logs UI files + gitignore fix.

## v0.4.0–v0.4.4

* **v0.4.0** — connection string import в Android.
* **v0.4.1** — `foregroundServiceType=specialUse` для VPN на Android 14.
* **v0.4.2** — remove invalid `android.app.ServiceInfo` import.
* **v0.4.3** — `{:#}` для full error chain в Android tunnel log.
* **v0.4.4** — misc.

## v0.3.9

* mTLS client cert/key support в Android — отправная точка для всей последующей auth-модели.

---

## QUIC-era performance tags (2025)

Не версии, а performance-оптимизации QUIC datapath. Подробности — [ROADMAP.md часть II](ROADMAP.md).

* **opt-v5-unlimited-cc** — 128MB window, inner TCP рулит congestion. +15% iperf3.
* **opt-v6-zerocopy** — in-place batch walk, build into `buf[4..]`. +4% download.
* **opt-v7-io-uring** — io_uring TUN I/O, batch syscalls. +10% download.
* **opt-v8-h264-shaping** — I/P-frame pattern, маскировка, −5 Mbps.
* **opt-v9-reality-fallback** — REALITY-style fallback для DPI active probing.
* **opt-v10-fix-pkt-loss** — `tun_to_quic_loop` больше не роняет пакеты для других клиентов.
* **opt-v11-multiqueue-tun** — `IFF_MULTI_QUEUE`, ~2× TUN throughput.
* **opt-v12-pipeline-collapse** — ❌ регрессия (mutex serializes writes), reverted.

---

## Удалённые платформы

* **macOS/iOS** — существовали в v0.10.0–v0.15.8 (iOS app + CI release pipeline). Удалены из дерева, когда проект сфокусировался на Android. История в git tags `v0.15.*`.
