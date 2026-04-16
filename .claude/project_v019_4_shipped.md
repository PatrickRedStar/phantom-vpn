---
name: v0.19.4 shipped state (2026-04-15)
description: Что задеплоено в v0.19.4 — QUIC removed, 4 bug fixes, 4 DNS unit tests, renaming QuicConfig→TlsConfig
type: project
originSessionId: 7c766df7-cd9f-4e4e-862b-2fb753f37291
---
Релиз задеплоен 2026-04-15. Commit `04913e9`, tag `v0.19.4`, GitHub Actions Build & Release run `24465016413`. Android versionCode 53.

**Diff stats: 39 файлов, +298/−1765, net −1467 строк.**

## Что вошло в релиз

### Основное — удаление QUIC (dead code)
- Удалены файлы: `crates/core/src/quic.rs` (115), `crates/core/src/congestion.rs` (70), `crates/server/src/quic_server.rs` (410).
- Удалены `quinn`/`quinn-proto` из Cargo.toml, `quic` feature.
- Rename `QuicConfig` → `TlsConfig` + `#[serde(alias = "quic")]` (backward-compat для server.toml).
- Android: удалены `runtimeTransport`, `quicProbeStart`, `nextAutoQuicRetryAtMs`, `switchRuntimeTransport`, `transportLabel`, `normalizeTransport`, auto-fallback в `startWatchdog` — ~210 строк kotlin.
- Удалены поля `transport` в VpnProfile.kt, VpnConfig.kt, ConnStringParser.kt.
- client-common: удалены `normalize_transport`, `Args.transport`.
- client-linux: удалён `resolve_transport`.

### Bug fixes
1. **Server DNS passive cache** (`vpn_session.rs`) — `name_pos = pos - rdlen - 10` указывал **за** qname (на конец). Исправлено на `name_pos = name_start` (уже был сохранён выше). Добавлено 4 unit-теста в `#[cfg(test)] mod dns_tests`.
2. **io_uring SQ push panics** (`crates/core/src/tun_uring.rs`) — 3× `.expect("push")` в hot-path → `push_entry()` helper с submit+retry, возвращает `Err` вместо panic.
3. **Android thread::spawn panic** (`crates/client-android/src/lib.rs`) — `.spawn(...).unwrap()` → match, return `-10`. Новый error message в `VpnStateManager.nativeStartErrorMessage(-10)` = "Не удалось запустить поток (ресурсы исчерпаны)".
4. **admin.rs remove_dir("/")** — fallback `Path::new("/")` убран, теперь `if let Some(parent) = Path::new(p).parent()`.

### Docs
- CLAUDE.md, README.md, ARCHITECTURE.md — убраны устаревшие упоминания QUIC/transport.
- CHANGELOG.md — новая секция v0.19.x (2026-04-15).
- config/*.example.toml — заголовки «QUIC Transport» → «H2 Transport».
- scripts/keys.py — `transport=` параметры удалены.
- Удалены `scripts/build-android-local.sh` + 6 устаревших CSV `other_docs/speedtest_*`.

## Процесс релиза

Выполнен через **4 параллельных субагента** (see `feedback_multi_agents.md`):
- Dev-Server (crates/server/)
- general-purpose (crates/core/ + crates/client-common/)
- Dev-Android (android/ + crates/client-android/)
- general-purpose (docs + config + scripts)

После сборки и merge'а одна регрессия: `client-linux` не собирался, т.к. `resolve_transport` ссылался на удалённые symbols. Пофиксил инлайн.

## Deployment

Сервер на vdsina (89.110.109.128):
- Binary installed via `cargo build --release -p phantom-server` + `install -m 0755` в `/opt/phantom-vpn/phantom-server`.
- Config `/opt/phantom-vpn/config/server.toml` — секция `[quic]` переименована в `[tls]` через `sed -i 's/^\[quic\]$/[tls]/'` (хотя `serde(alias)` тоже справился бы).
- Systemd unit Description обновлён: «PhantomVPN Server (H2/TLS transport)».
- Service restarted, PID 573958. `ss -ulnp` — нет UDP listeners (QUIC полностью мёртв).
- Все 9 client fingerprints загружены, H2/TLS-only на 8443/8080/8081.

## Android APK

Собирается на машине пользователя через SSH тунель (port 22222) — Android SDK не установлен на vdsina. `.so` уже в репе (собран через `cargo ndk` на vdsina).

## Что НЕ вошло (намеренно отложено)

- Priority 1 perf items из `project_v019_priorities.md` (batch TUN writes, zero-copy RX) — disproven в `reference_v019_perf_tests.md`, код near-optimal для 2-core TCP-in-TLS.
- Detection vectors 11-13 (timing jitter, heartbeat frames, connection migration) — в `reference_detection_vectors_11_13.md`, план v0.20.
- Android Clone profile — в `feedback_profile_ux.md`, отдельный sprint.
- Rewrite `scripts/keys.py` на ghs:// формат — флаг от docs-агента, оставлен для следующего relay-deploy.
