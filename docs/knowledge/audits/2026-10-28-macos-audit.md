---
title: macOS-клиент — аудит багов, UX и дизайна
date: 2026-10-28
type: audit
status: open
updated: 2026-10-28
agents: 5 (визуал, UX, app-слой, туннель, паритет)
version-tested: v0.29.0 (44)
---

# Аудит macOS-клиента — 2026-10-28

Пять агентов прочитали код (сборку и приложение не запускали), дубли сведены.
Пути: `M/` = `apps/macos/GhostStream/`, `PTP` =
`apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift`, `PK/` =
`apps/ios/Packages/PhantomKit/Sources/PhantomKit/`.

**Итог.** Ядро провайдера после прошлых раундов аккуратное: UAF и двойных
free нет, completion вызывается один раз. Плохо в трёх местах:

1. UI и сервисы читают `activeProfile` и prefs, а не то, что реально запущено в
   провайдере. Отсюда P0 с relay и смена профиля без переподключения.
2. Канал «экстеншен → приложение» на macOS — только IPC живой сессии. Всё, что
   провайдер пишет в App Group, уходит в контейнер root, и его никто не
   читает. Поэтому причина отключения не видна.
3. Нет дизайн-системы. Экраны перерисованы с HTML-мокапа литералами:
   232 `.font(.custom)` и 22 размера; около 8 самописных кнопок; половина
   текстов — английский жаргон; у фирменных шрифтов нет кириллицы.

Сильные стороны: мастер онбординга, полная админка, отдельное окно логов,
палитра команд.

## VPN и данные

| # | Что | Где | Фикс |
|---|---|---|---|
| P0 | Монитор маршрутов считает политику по exit (`serverAddr`), а коннект идёт через relay (`effectiveServerAddr`). Хэши расходятся, и через ~10 с в туннель уходит политика с /32 exit. После рестарта рантайма по смене сети endpoint пинится на `exitIP:443`, а этот порт из РФ фильтруется, и туннель вечно переподключается. Нарушен ADR 0013. | `M/Service/UpstreamVpnMonitor.swift:99`, `M/Service/VpnTunnelController.swift:115`, PTP:1305-1317 | В мониторе брать `effectiveServerAddr`; в `installOnly` использовать `withRelayEndpoint`, как на iOS (иначе `connString` остаётся с exit) |
| P1 | DNS-кэш адреса relay живёт вечно. После captive portal или переезда IP реле Connect идёт на старый адрес до перезапуска приложения. | `M/Service/UpstreamVpnRouteDetector.swift:336-338,381` | TTL несколько минут; в `installOnly` делать свежий резолв |
| P1 | Причина фатального отключения (отзыв, истёкший серт, часы) мелькает и пропадает, после чего UI показывает STANDBY. Снапшот с ошибкой лежит в контейнере root. Фикс 6f46e61f на macOS не работает. | `M/Service/VpnStateManager.swift:182-211`, PTP:1515-1593 | На `.disconnected` вызывать `connection.fetchLastDisconnectError()` и держать `.error` до следующего Connect |
| P1 | `VpnStateManager` навсегда держит первый `NETunnelProviderManager`. Если конфиг удалён в Настройках → VPN, UI следит за мёртвым менеджером и отключиться из приложения нельзя. | `M/Service/VpnStateManager.swift:99-102,174-178` | Обновлять кэш по `.NEVPNConfigurationChange` и после `saveToPreferences` |
| P1 | Смена профиля при поднятом VPN. UI показывает новый сервер, а трафик идёт через старый. Монитор шлёт в старый туннель политику нового профиля. «Connect to B» в палитре молча ничего не делает. | `PK/Storage/ProfilesStore.swift:134-138`; вызовы `M/UI/MenuBar/MenuBarPopover.swift:370`, `M/UI/Sidebar/SidebarProfileBlock.swift:49`, `M/UI/Servers/ServerRosterView.swift:594`, `M/UI/Window/CommandPalette.swift:322` | В connected/connecting: stop → дождаться `.disconnected` → start |
| P1 | Удаление активного профиля при поднятом VPN — туннель продолжает работать на удалённом профиле. Запись в Настройках → VPN остаётся навсегда, сброса нет. | `PK/Storage/ProfilesStore.swift:125-130`, `M/Service/VpnTunnelController.swift:280-284` | Останавливать перед удалением; удаление последнего профиля → `tunnel.remove()` |
| P1 | ⌘Q и «Выйти» при включённом VPN без подтверждения. Туннель остаётся, а выключить его негде. CONC-L1 ещё открыт. | `M/App/AppDelegate.swift` (нет `applicationShouldTerminate`) | Алерт «Отключить и выйти / Выйти, оставив VPN / Отмена» |
| P2 | В publicSplit/layeredAuto IPv6 идёт мимо туннеля (`excludedRoutes=::/0`), тумблер работает наоборот. SEC-R2-R04 ещё открыт; на iOS исправлено. | PTP:1114-1149,1175-1178 | `::/0` в туннель, исключать только явные IPv6 |
| P2 | Провайдер сам перезапускает рантайм при флапе сети в reconnecting, вопреки ADR 0018: сбрасывает бэкофф, при stop >2 с два рестарта накладываются и дают ERR_ALREADY_RUNNING. В connected смена Wi‑Fi до ядра не доходит, до 75 с «Подключено» без трафика. | PTP:337-447,509-528 | FFI-сигнал «сеть сменилась» в ядро вместо stop/start |
| P2 | Полный диск роняет экстеншен (`FileHandle.write` бросает ObjC-исключение). | `apps/macos/PacketTunnelExtension/LogFileWriter.swift:142` | `try handle.write(contentsOf:)` |
| P2 | Бюджет stop 4,5 с только на бумаге: `withTaskGroup` ждёт блокирующий FFI, худший случай ~12 с. CONC-R2-N02/N03 по сути открыты. | PTP:1829-1844 | Гонка через continuation с однократным resume |
| P2 | Настройки при поднятом VPN применяются наполовину: режим маршрутов — сразу, kill switch, DNS и IPv6 — после переподключения. Подсказка есть только у потоков. | `M/Service/UpstreamVpnMonitor.swift:94-131`, `M/UI/Settings/SettingsView.swift` | «Применится после переподключения · [Переподключить]» |
| P2 | Reconnect в палитре стартует через 350 мс после stop. Teardown дольше, и туннель просто остаётся выключенным. | `M/UI/Window/CommandPalette.swift:551-556` | Ждать `.disconnected` |
| P2 | Попап и иконка в меню-баре не показывают dead/degraded: «зелёная точка, всё хорошо», когда стримы мертвы. | `M/UI/MenuBar/MenuBarPopover.swift:186-230` | Вывести health, точку красить в warn |
| P2 | Ошибка применения маршрутов глотается, IPC повторяется каждые 5 с бесконечно. | `M/Service/UpstreamVpnMonitor.swift:124-131` | Запомнить провалившийся hash, показать ошибку |
| P2 | `panic = "abort"` — `catch_unwind` в FFI бесполезен, паника рантайма убивает экстеншен. FFI-C6 ещё открыт. | `Cargo.toml:25` | Unwind-профиль для client-apple; на ERR_PANIC ctx не освобождать |
| P3 | Обновление приложения: `.replace` экстеншена без сравнения версий рвёт туннель, обратно не подключается. С kill switch риск того же класса, что ADR 0021. Не проверено. | `M/Service/SystemExtensionInstaller.swift:89-96` | Запомнить «был подключён» и переподключить; сравнить версии; проверить вживую |
| P3 | Логи теряют строки: больше 500 за 1,5 с и курсор по времени. Хвост упавшей сессии не попадает ни в TAIL, ни в runtime.log. | PTP:1729-1745, `M/Service/TunnelLogStore.swift:48-132` | Монотонный seq-курсор; финальный опрос на disconnect |
| P3 | Тумблер «Verbose logging» не работает: UserDefaults под root — другой домен. | PTP:1023-1028 | Передавать в `providerConfiguration` |
| P3 | Ложное «Отключено» и уведомление при рестарте рантайма; скорость застывает в reconnecting; таймер сессии и байты обнуляются на каждую попытку (на iOS это закрыто `SessionClock`). | PTP:359,550-578; `crates/client-core-runtime/src/supervise.rs:282-365` | Глушить Disconnected старого рантайма; обнулять скорость; `SessionClock` |
| P3 | Fallback-кадр кладёт байты/с в поле бит/с (×8 меньше); график начинается с хвоста прошлой сессии. | `M/Service/VpnStateManager.swift:322-378`, `M/Service/TrafficSeriesStore.swift:84-90` | ×8; чистить на disconnect |
| P3 | IPv6 в ручных CIDR помечаются Invalid и не передаются, хотя экстеншен их умеет. | `M/Service/VpnTunnelController.swift:175-184` | Передавать `manualDirectIpv6Cidrs` |
| P3 | Редактор профиля не нормализует relayAddr (`:443`) и не сбрасывает TOFU-пин админки при смене endpoint. | `M/UI/Settings/ProfileEditorSheet.swift:296-307` | `normalizedRelayAddr`, `cachedAdminServerCertFp = nil` |
| P3 | Админка опрашивает 10.7.0.1:8080 без VPN: таймауты, а TOFU может закрепить чужой хост в LAN. | `M/UI/Admin/AdminConsoleView.swift:94-106` | Опрос только в `.connected` |
| P3 | Мелочи провайдера: поздний start после отмены оставляет рантайм-сироту; `invalidate()` не обнуляет `onInbound`; `activeSettings` портится при неудачном apply; кольцевой буфер логов O(n) под общей блокировкой. | PTP:937-1017,1406-1430,1752; `PK/FFI/PhantomBridge.swift:91,125` | По месту |

## Тексты и UX

| # | Что | Где |
|---|---|---|
| P1 | Около половины интерфейса — английский жаргон: TUNNEL STATE, SNI, TUN IP, MUX · STREAMS, NO ACTIVE TUNNEL, roster., + NEW PROFILE. Палитра целиком английская, поиск по-русски не работает. Каталог на 144 ключа есть, но около 100 `Text("…")` его обходят. UI-H6, UI-M6, UI-L1–L3 открыты. | Dashboard, MenuBarPopover, ServerRoster, CommandPalette, TailView, Settings |
| P1 | Слова состояния сбивают с толку: отключено — «ожидание.», подключение — «настройка.» (так же называется вкладка), подключено — «передаёт.», отозван — «сигнал потерян.». | `M/UI/MenuBar/MenuBarPopover.swift:171-182`, `state.*` в xcstrings |
| P1 | В reconnecting не видно причины: «нет сети», «сервер недоступен» и «неверный серт» выглядят одинаково — «попытка N». `last_error` ядро отдаёт. | `M/UI/Dashboard/DashboardView.swift:153-160`, `M/UI/MenuBar/MenuBarPopover.swift:272` |
| P1 | Мастер ведёт по английской macOS («System Settings → Login Items & Extensions», «Allow»), сырые ошибки. Нет проверки «запущено не из /Applications». При `willCompleteAfterReboot` вечно ждёт. | `M/UI/Onboarding/WelcomeWindow.swift`, `M/Service/SystemExtensionInstaller.swift:101-137` |
| P1 | Ошибки Connect на английском («System extension is install is still pending») и уводят в мастер, который может сразу сказать «Готово». Пустой дашборд без кнопки «Добавить профиль». | `M/UI/MenuBar/MenuBarPopover.swift:696-740`, `M/UI/Dashboard/DashboardView.swift:646-687` |
| P1 | При запуске окно не открывается (тумблер «Запускать в строке меню» ни на что не влияет). Автозапуск, требующий одобрения, молча откатывается. После мастера пользователь остаётся без окна и без подсказки про строку меню. Клик по Dock ненадёжен. | `PK/Models/MacStartupPolicy.swift:26-31`, `M/Service/LoginItemController.swift:27-42`, `M/UI/Onboarding/WelcomeWindow.swift:754`, `M/App/AppDelegate.swift:58-68` |
| P1 | Срок подписки загружается (`/api/me`), но не показывается — только в диагностике. A4 из full-scan на macOS открыт. | `M/Service/EntitlementRefresher.swift:74-84` |
| P1 | Видны заглушки обновлений: «Недоступно: Sparkle updater не подключен» и пункт в палитре. Механизма обновлений нет, хотя `platforms/macos.md` описывает Sparkle как работающий. | `M/UI/Settings/SettingsView.swift:255-266`, `M/UI/Window/CommandPalette.swift:381-399` |
| P2 | Уведомления по-английски, включены по умолчанию и приходят на каждый переход, включая ручной Disconnect и роуминг. Отзыв доступа приходит как «GhostStream error». | `PK/Models/VpnStateNotificationPolicy.swift:22-43`, `M/App/GhostStreamApp.swift:300-345` |
| P2 | Отзыв или истечение доступа показывается без подсказки, что делать (у `ConnectErrorHumanizer.fatalStop` есть готовый текст). | Dashboard, MenuBarPopover |
| P2 | Повторный импорт той же ссылки создаёт дубликат; строка «Вставить конфиг» висит, пока в буфере `ghs://`. | `PK/Storage/ProfilesStore.swift:144-163` |
| P2 | Настройки описаны языком разработчика: «SMAppService.mainApp · login item», «LSUIElement runtime», «— DARWIN», «warm-black + lime», «Cisco/work VPN first». About показывает «PHOSPHOR», нет номера сборки. | `M/UI/Settings/SettingsView.swift`, `M/UI/Window/AboutView.swift` |
| P2 | ⌘, открывает отдельное окно 520 pt с той же двухколоночной страницей. | `M/App/GhostStreamApp.swift:187-203` |
| P2 | Админ одним кликом отключает себя или снимает с себя права, без подтверждения. | `M/UI/Admin/AdminConsoleView.swift:541-566` |
| P2 | Клик по строке лога молча затирает буфер JSON-ом, выделить текст нельзя. | `M/UI/Logs/TailView.swift:602-604` |
| P2 | В редакторе профиля сервер, SNI и tun свободно правятся без проверки. Одна опечатка — вечный реконнект. | `M/UI/Settings/ProfileEditorSheet.swift:162-165` |
| P3 | Конвенции macOS: ⌘K работает только на «ПОТОК», ⌘N — только в «СПИСОК»; нет меню VPN; «Справка» пустая; окна называются «Logs/Welcome/About». | `M/App/GhostStreamApp.swift:104-176` |
| P3 | Список серверов: регион «nl · vdsina» по захардкоженным IP, боевое реле показано как «— internal»; активный профиль отмечен трижды. Палитра показывает RTT активного профиля у всех. | `M/UI/Servers/ServerRosterView.swift:300-465`, `M/UI/Window/CommandPalette.swift:313` |

## Дизайн

| # | Что | Где |
|---|---|---|
| P1 | Кириллица не тем шрифтом: в Space Grotesk и Instrument Serif нет кириллицы, а подмена на системный сделана только под `#if os(iOS)`. Засечный курсив hero превращается в прямой текст. | `apps/ios/Packages/PhantomKit/Sources/PhantomUI/Theme/Typography.swift:196-205` |
| P1 | Токены не используются: 232 `.font(.custom)`, 22 размера (8,5–54), около 27 разных отступов. Одинаковые подписи на соседних экранах — 10 / 9,5 / 9 pt. | весь `M/UI/` |
| P1 | Каркас не похож на Mac: окно без тулбара, самописный сайдбар без системного выделения, самописные таблицы, ноль материалов и glass на macOS 26. | `M/UI/Window/MainConsoleWindow.swift`, `M/UI/Sidebar/SidebarList.swift` |
| P1 | Около 8 реализаций кнопок. Главная «Подключить» — тонкая контурная кнопка в ряду SNI/TUN IP. | Dashboard:306-333, `PhantomUI/Components/GhostFab.swift` |
| P1 | Иконка — квадрат без альфы и скругления, другой рисунок, чем на iOS/Android. В меню-баре цветной не-template PNG (контраст лайма на светлом ~1,2:1), ширина прыгает. | `Assets.xcassets/AppIcon`, `M/UI/MenuBar/MenuBarStatusItem.swift:57-97` |
| P1 | Самописный тумблер: VoiceOver читает «On, button» без названия. В шитах при этом нативный — два разных тумблера. | `M/UI/Settings/SettingsView.swift:668-716` |
| P2 | Контраст `textFaint` 2,4–2,9:1 (92 использования, часто 9–10 pt); цвета категорий логов не адаптируются к светлой теме. UI-M2 открыт. | `PhantomUI/Theme/Colors.swift:93,109` |
| P2 | Дашборд: mux-карточка фиксирована на 360 pt, значения переносятся; скорость в трёх форматах; минимальный размер окна задан дважды по-разному. | `M/UI/Dashboard/DashboardView.swift:509-624` |
| P2 | Попап меню-бара фиксирован 380×600: в ожидании пустота, при подключении низ с «Quit» обрезается. | `M/UI/MenuBar/MenuBarPopover.swift:79-87` |
| P2 | Пилюля темы рисует «▾», а по клику циклически переключает тему. Остальные меню вероятно с двойным шевроном. | `M/UI/Settings/SettingsView.swift:790-1002` |
| P2 | Три бренд-знака (кольцо с синусоидой, призрак, словесный знак) и два написания: Ghoststream / GhostStream. | Sidebar, MenuBarPopover, About, Welcome |
| P3 | Пульсирующий «SAVED», hover-scale тумблеров, двойной пунктир, радиусы 3/4 мимо токенов, юникод «▾ ✕» вместо SF Symbols, 11 размеров символов. | Settings, Dashboard |

## Пробелы относительно Android/iOS

| # | Что | Объём | Переиспользование |
|---|---|---|---|
| P1 | «РФ напрямую» (страны geoip, домены, IPv6): `directCountries` игнорируется с предупреждением (PTP:1216). | M | `RoutingRulesManager` из PhantomKit, логика из iOS `VpnTunnelController` |
| P1 | Обновления: Sparkle нет. | S (проверка GitHub + баннер) / M (Sparkle) | — |
| P1 | Автоподключение (On-Demand) после перезагрузки или сна. | S | `applyOnDemand` из iOS |
| P2 | Открытие ссылок `ghs://`, файлов и перетаскивание (нет ни на одной платформе). | S | `ProfilesStore` |
| P2 | App Intents и Shortcuts — заодно глобальная горячая клавиша через «Команды». | S | iOS `Shared/VpnIntents.swift` |
| P2 | QR ссылки клиента в админке. | S | iOS `ConnStringShareCard.swift` |
| P3 | Скорость в строке меню, импорт QR с картинки, виджет и Пункт управления, Focus filter. | S–M | частично iOS |

## План

1. **Баги VPN, без дизайна:** P0 relay, DNS-кэш, причина отключения,
   кэш менеджера, смена и удаление профиля, Quit, IPv6, LogFileWriter,
   reconnect в палитре. Это cross-process boundary, поэтому после правок
   обязателен `apps/macos/scripts/smoke-test.sh` с реальным Connect.
2. **Тексты и жизненный цикл:** весь UI через каталог, человеческие статусы,
   причина реконнекта, срок подписки, уведомления, убрать заглушки Sparkle,
   кириллица на macOS, окно при запуске, мастер под русскую macOS.
3. **Дизайн:** HTML-макет на утверждение (правило — UI только после approve) →
   токены, одна кнопка, нативный каркас по образцу iOS, иконки.
4. **Фичи:** «РФ напрямую», On-Demand, обновления, `ghs://`, App Intents.
