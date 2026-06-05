# Changelog

## [0.26.22] - 2026-06-05

### Fixed
- **Edge-to-edge (Android 15+)** — `MainActivity.onCreate` теперь использует `enableEdgeToEdge()` вместо deprecated `WindowCompat.setDecorFitsSystemWindows(false)`. Закрывает Google Play warning «Отображение от края до края может работать не у всех пользователей».
- **Deprecated bar-color APIs** — `Theme.kt` больше не вызывает `window.statusBarColor =` / `window.navigationBarColor =` (deprecated в SDK 35). Прозрачность достигается через `enableEdgeToEdge()`. Закрывает Google Play warning «В вашем приложении используются неподдерживаемые API».

## [0.26.21] - 2026-06-05

### Fixed
- **Phantom tunnel detection** — supervisor теперь детектит когда все streams умерли (≥3 сек) и делает teardown + reconnect, вместо ложного `health:healthy` при `streams_up=0`. Промежуточный статус `health:degraded` при `streams_up < n_streams/2`. Health computation перенесён в `derive_health` (single source of truth) — больше не race с watcher'ом.
- **TCP keepalive logging** — раньше ошибки `setsockopt` молча игнорировались, теперь видны в logcat как `event=tcp_keepalive_failed` (или `tcp_keepalive_set` при успехе).
- **FileProvider crash в Logs → Share** — файл писался в `cacheDir/`, а paths.xml объявлял подпапку `logs/`. Теперь файл попадает в `cacheDir/logs/`.
- **Debug report silent failure** — `shareDebugReport` обёрнут в `runCatching` + `withContext(Dispatchers.IO)`, ошибки теперь видны через Toast. Секция логов содержит диагностический маркер `persist=N B, tail=K строк`.

### Added
- `TunnelHealth::Dead` вариант (`crates/gui-ipc/src/lib.rs:337`) + Kotlin mirror (`VpnStateManager.kt`). Отражает «все streams умерли, teardown в процессе». iOS Codable обрабатывает через `.unknown` fallback.
- `ALL_STREAMS_DEAD_TIMEOUT_SECS` (3 сек) — порог для death watcher'а.
- `derive_health` теперь учитывает `streams_up` + `n_streams` — health UI отражает реальное состояние streams.
