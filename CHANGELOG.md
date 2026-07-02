# Changelog

## [macOS 0.25.1 build 30] - 2026-07-02

### Added
- **Русская локализация основных экранов** — подключены переводы состояний/кнопок/настроек/онбординга + **языковой пикер** (Системный / English / Русский) в настройках.
- **Редактирование профиля** — имя, сервер, SNI, адрес туннеля прямо в списке профилей (раньше только добавить/удалить); connString пересобирается автоматически.
- **Kill-switch** — блокировка всего трафика при обрыве туннеля (`includeAllNetworks`), доступен в режиме «Весь трафик», доступ к локальной сети сохраняется. Выключен по умолчанию.
- **«Вставить конфиг»** прямо из меню-бара, когда в буфере обмена лежит `ghs://`-ссылка.
- **Прогресс переподключения** (номер попытки и отсчёт до следующей) в попапе и на дашборде.
- **«Подключиться сейчас»** на финальном шаге онбординга.

### Changed
- Ошибки подключения показываются по-русски и человекочитаемо (сервер недоступен / сертификат отклонён / нет сети / расширение не одобрено) вместо сырого системного текста.
- Системный Reduce Motion теперь учитывается во всех анимациях, а не только в отдельном тумблере.

### Internal
- Тестируемая логика вынесена в PhantomKit и покрыта тестами (86, +31): фильтр логов, нормализация уровней, арифметика IPv4-маршрутов, сборка `ghs://`, humanizer ошибок. Убран рукописный дубль таблицы уровней логов.

## [macOS 0.25.1 build 29] - 2026-07-02

### Fixed
- **layeredAuto (Cisco-пресет): «что-то грузится, что-то нет» при двух VPN.** Вычитание маршрутов Cisco из includedRoutes (агрегированное в супернеты) вырезало из GhostStream огромные публичные диапазоны (Cloudflare/Google CDN) — этот трафик уходил голым через физический интерфейс мимо обоих VPN, и в РФ его резал ТСПУ (speedtest, YouTube-превью). Новая модель ([ADR 0012](docs/knowledge/decisions/0012-layered-routing-longest-prefix.md)): ничего не вычитаем, иерархию «корп → Cisco» обеспечивает longest-prefix системной таблицы; detectedUpstreamCidrs исключены из routeHash (дребезг динамического сплита больше не флапает туннель); серверный exclude ставится всегда; при full-tunnel upstream — предупреждение в Settings.

## [macOS 0.25.1] - 2026-07-02

### Fixed
- **Вкладка логов «зависала» после долгой работы.** Провайдер эмитил DBG-события `ipc request/response` на каждый polling-запрос (в т.ч. на сам `subscribe_logs` раз в 1.5 с) — лог-поток самоподпитывался и добивал буфер UI до потолка даже в простое. На потолке `trim` держал `logs.count` постоянным, `onChange(of: count)` переставал срабатывать, и tail замерзал. Теперь: DBG для `get_status`/`subscribe_logs` только под verbose_log; UI наблюдает монотонный `revision`, а не `count`; фильтрация буфера ушла с main actor в фон; cap 50k→10k; `LogFrame.id` включает хэш `fields` (дубли ломали ForEach).
- **Split routing на пресете Cisco (layeredAuto): подключался и сразу сбрасывался.** Cisco добавляет сотни динамических /32 — комплемент раздувался до тысяч `includedRoutes`, а `routeHash` дребезжал на каждый новый хост → `setTunnelNetworkSettings` каждые 5 с → reassert-петля. Теперь маршруты upstream-VPN агрегируются лестницей /24→/20→/16 (cap 192, стабильные супернеты); policy применяется только в `.connected` с гистерезисом в 2 опроса; отдельный FFI-лимит 256 КиБ для расчёта маршрутов (прежние 16 КиБ молча отключали split routing на большом наборе); пустой комплемент теперь громкая ошибка, а не тихий туннель без трафика.
- **«Интернет пропадал» под нагрузкой на логи.** Inbound-пакеты доставлялись через актор `PhantomBridge`, где конкурировали с колбэками логов/статусов; `writeSnapshot` (файловый I/O) выполнялся на акторе на каждый StatusFrame. Теперь пакеты идут напрямую с Rust-потока, `submitInbound` — `nonisolated`, запись snapshot — на serial-очереди с коалесценцией `StatusBroadcastGate` (1/с, паритет с iOS).
- **IPC мог зависнуть навсегда** — `TunnelIpcBridge.send` без таймаута + ветки `updateRoutePolicy`, не вызывавшие completionHandler, вешали host-side continuation до перезапуска. Добавлен таймаут 10 с и ответ во всех ветках.
- **`runtime.log` был недоступен** — system extension (root, sandbox) писал в контейнер root'а, кнопка «Reveal» всегда отвечала «not yet created». Добавлено host-side NDJSON-зеркало в пользовательский контейнер.
- **Зацикленная анимация открытия menubar-попапа** («шторка» бесконечно выезжала/заезжала в connected) — `PulseDot` запускал пульс через `withAnimation(.repeatForever)`, транзакция накрывала раскладку окна MenuBarExtra. Переведён на scoped `.animation(_, value:)`; добавлен тест-инвариант против рецидива (`MenuBarAnimationInvariantTests`).
- **Обрезка футера menubar-попапа в connected** («Логи» наполовину, «Выход» скрыт) — 520pt теперь минимальная высота, контент может расти; строка «Логи» видна в любом состоянии.
- **UI-аудит интерактивности (~70 элементов, 13 экранов):** копирование логов переехало с ⇧⌘C на ⌥⌘C (комбу перехватывало меню «Командной палитры» — шорткат молча не работал); «Check for updates» больше не рисует красную «ошибку коннекта» под CONNECT; шорткаты ⌘K/⇧⌘⌫/⌥⌘C/⇧⌘E/⌘F не срабатывают под открытой палитрой; профиль в menubar-попапе теперь реально переключается (Menu, как в сайдбаре) — раньше шеврон вёл в никуда; «Edit» в ростере переименован в «Manage…» (редактирования там нет).
- **`event=connected` эмитился каждую секунду** (на каждый статус-фрейм рантайма, +3600 фреймов/час в лог) — теперь только на переходе состояния.
- Прочее: teardown-бюджет 5.5→4.5 с (укладывается в SIGKILL-дедлайн NE); guard от двойного `installAndStart`; миграция UserDefaults по whitelist ключей (не тянет весь NSGlobalDomain); build-штамп из `Info.plist` вместо хардкода; запрос авторизации нотификаций только при `.notDetermined`; claim-tracking в DockPolicyController; версия бандла из build settings; smoke-test.sh больше не даёт ложный FAIL (pipefail+SIGPIPE).

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
