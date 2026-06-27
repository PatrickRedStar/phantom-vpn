# Changelog

## [0.27.0] - 2026-06-27

### Security
- **Удалён флаг `Insecure TLS` (`skip_verify`)** — он полностью отключал проверку серверного сертификата (MITM-вектор), а UI это маскировал под «skip hostname check». Серверный серт теперь проверяется **всегда** через webpki (сервер отдаёт настоящий Let's Encrypt серт). mTLS-identity клиента сохранён. Старые `ghs://…&insecure=1` ссылки парсятся, флаг игнорируется. Пиннинг сознательно НЕ вводился — leaf/SPKI-пин ломался бы на ротации LE-серта. См. [ADR 0011](docs/knowledge/decisions/0011-remove-insecure-always-verify.md). Затрагивает все клиенты (core), openwrt тоже перестал хардкодить `skip_verify=true`.

### Fixed
- **Зомби-туннель «подключено, но трафика нет» при смерти одного стрима** — death-watcher теперь делает teardown+reconnect при `alive < n_streams` (любой мёртвый стрим), а не только при `alive==0`. Один мёртвый стрим ронял весь TX через dispatcher (`flow_stream_idx % n` → закрытый канал → `break`), но статус оставался «Connected». Реконнект всех N (инвариант all-N сохранён, без partial-quorum).
- **Медленная реакция на обрыв TX-пути** — завершение dispatcher (TUN→stream) теперь armed в главный `select!` → мгновенный teardown вместо ожидания RX-idle (75с).
- **UI/нотификация врали «Подключено» при мёртвом туннеле** — постоянная нотификация теперь читает реальный `health` (через `derivedVpnState`): `Healthy/Stale/Throttled/Reconnecting/Dead` с цветом, скоростью и `streams_up/n_streams`. Источник текста — честный `derivedVpnState`, не строка `state`.
- **Инфографика дашборда хардкодила «8/8»** — `MuxBars` теперь рисует реальные `streamsUp/nStreams` и `stream_activity`; мёртвые стримы красным.

### Added
- **Уведомление об обрыве** — отдельный heads-up канал, единичный alert на переходе «был up → reconnecting» (не спамит, не срабатывает на ручной Disconnect). Запрашивается `POST_NOTIFICATIONS` (Android 13+).
- **Проактивный battery-optimization exemption + POST_NOTIFICATIONS** при первом подключении (раньше прятался пассивным баннером в настройках) — дешёвый и результативный шаг против Doze («телефон в кармане»).
- `DEGRADED_TEARDOWN_SECS` (3 c) — порог teardown при деградации стримов (заменил `ALL_STREAMS_DEAD_TIMEOUT_SECS`).

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
