---
name: QUIC status — удалён полностью в v0.19.4
description: QUIC stack был мёртвым кодом, удалён целиком в v0.19.4 (2026-04-15). Только H2/TLS. Для истории — что удалили и почему.
type: reference
originSessionId: 7c766df7-cd9f-4e4e-862b-2fb753f37291
---
**Статус на 2026-04-15: QUIC полностью удалён из кода в релизе v0.19.4.**

Был мёртвым кодом с v0.17: `normalize_transport` в `helpers.rs` принимал только "h2", UDP-сокет :443 слушал впустую, Android fallback недостижим. README/ARCHITECTURE/CLAUDE ещё упоминали его как fallback — устаревший текст.

**Что удалено в v0.19.4 (commit 04913e9):**
- `crates/core/src/quic.rs` (115 строк) — quinn config builders
- `crates/core/src/congestion.rs` (70 строк) — UnlimitedConfig
- `crates/server/src/quic_server.rs` (410 строк) — endpoint loop
- `quic` feature из `crates/core/Cargo.toml`, зависимости `quinn`, `quinn-proto`
- QUIC-ветка `select!` в `crates/server/src/main.rs`
- `normalize_transport`, `Args.transport`, `resolve_transport` (client-common, client-linux)
- Android `runtimeTransport`, `quicProbeStart`, `nextAutoQuicRetryAtMs`, auto-fallback методы (~200 строк kotlin)
- Поле `transport` в `VpnProfile.kt`, `VpnConfig.kt`, `ConnStringParser.kt`

**Renaming:** `QuicConfig` → `TlsConfig`, `cfg.quic` → `cfg.tls` по всем файлам. Backward-compat для `server.toml`: `#[serde(alias = "quic")]` на поле `tls` — старые конфиги с `[quic]` секцией продолжат парситься.

**Systemd unit description:** «QUIC/HTTP3 transport» → «H2/TLS transport with mTLS» в `scripts/deploy.sh`.

**Контрольная проверка:** `grep -rn "quinn\|QuicEndpoint\|quic_server" crates/ android/app/src/main/` — пусто (кроме CHANGELOG исторически).

**Если кто-то захочет вернуть QUIC:** в git history до 04913e9 он жив, но текущая позиция — TSPU активно маркирует QUIC/UDP (detection vectors), H2/TLS выигрывает по скрытности.
