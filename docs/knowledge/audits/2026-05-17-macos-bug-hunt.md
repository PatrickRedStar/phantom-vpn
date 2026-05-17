---
title: macOS GhostStream — Adversarial Bug Hunt
date: 2026-05-17
type: audit
status: open
agents: 6 (opus)
version-tested: 0.24.0 build 20
---

# Bug Hunt — macOS GhostStream — 2026-05-17

## Как это собрано

6 параллельных опус-агентов специально пытались сломать приложение со всех сторон. Каждый отвечал за свою зону:

| Агент | Зона | Найдено |
|---|---|---|
| UI Adversary | SwiftUI, анимации, accessibility, layout | 32 |
| Provider Adversary | PacketTunnelProvider, System Extension lifecycle | 23 |
| Rust/FFI Adversary | `client-apple`, `client-core-runtime`, panic boundaries | 14 |
| IPC/State Adversary | wire format, PhantomKit модели, persistence | 15 |
| Security Adversary | утечки секретов, signing, entitlements | 17 |
| Concurrency/Lifecycle Adversary | race conditions, sleep/wake, force quit | 14 |

**Итого: 115 находок.** После дедупликации (один и тот же баг находили до пяти агентов независимо — это хороший signal что баг реально есть) остаётся **~85 уникальных проблем**.

Разбивка по серьёзности:
- **26 CRITICAL** — крэшит / утекает данные / делает не то что обещает пользователю
- **43 HIGH** — серьёзный дефект, UX или correctness страдают
- **31 MEDIUM** — нюансы которые накапливаются и потом всплывают
- **15 LOW** — косметика

---

## Что страшно — топ‑12 простым языком

### 1. Утечка `BridgeContext` (нашли 5 агентов независимо!)

**Где:** `apps/ios/Packages/PhantomKit/Sources/PhantomKit/FFI/PhantomBridge.swift:138-141, 188-196` + `crates/client-apple/src/lib.rs:367-386`

**Что:** В Swift делаем `Unmanaged.passRetained(box).toOpaque()` (retain +1), а потом `stop()` обнуляет только обычное Swift-поле `contextBox = nil`. Тот retain, который ушёл в Rust как указатель — **никогда не релизится**. Каждый Connect/Disconnect утекает один объект, и удерживает за собой всю actor-ссылку.

Хуже: после `phantom_runtime_stop` Rust ещё продолжает работать (supervisor может handshake'ить, log forwarder ждёт frame'ов). Он держит этот ctx и вызывает Swift callback'и. **Сейчас не падает только потому что объект утёк** — формально это use-after-free.

**Что увидит пользователь:** через много часов работы (8+) или после агрессивного reconnect — memory pressure, System Extension убит, VPN отваливается без объяснения. Если кто-то "починит" утечку без полного fix — крэш на каждом Disconnect.

**Фикс:** Rust сторона должна синхронно дожидаться завершения supervisor в `phantom_runtime_stop` (как уже сделано в Android `client-android/src/lib.rs:160-182`). После того как Rust подтвердил что больше callback'ов не будет — Swift вызывает `Unmanaged.fromOpaque(ctx).release()`.

### 2. IPv6 leak — реальный IPv6 идёт мимо туннеля

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:492-498`

**Что:** macOS Provider создаёт `NEIPv6Settings(addresses: [], networkPrefixLengths: [])` — пустой массив адресов. Apple требует хотя бы один tunnel IPv6 address чтобы settings вообще применились. **На iOS это сделано правильно** (там есть ULA `fd00:6768:6f73:7473::1`), на mac — нет. Плюс `packetFlow.writePackets` помечает ВСЕ возвратные пакеты как `AF_INET`, что ломает IPv6 даже если бы settings работали.

**Что увидит пользователь:** Подключил VPN → пошёл на `curl -6 https://ifconfig.io/v6` → видит свой реальный IPv6, не серверный. **Полное нарушение продуктового обещания** — для VPN это критичный privacy leak.

**Фикс:** скопировать IPv6 логику с iOS Provider (`apps/ios/PacketTunnelProvider/PacketTunnelProvider.swift:195-198`) включая ULA tunnel address и corrected `writePackets` (определять protocol по первому байту: `0x4* → AF_INET, 0x6* → AF_INET6`).

### 3. `completionHandler(nil)` вызывается ДО реального handshake

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:411`

**Что:** В `startTunnelAsync()` после `PhantomBridge.shared.start()` сразу вызывается `callStartCompletionOnce(nil)`. Но `phantom_runtime_start` делает только `tokio::spawn(run(...))` и возвращается через микросекунды — TLS handshake ещё даже не начался. NetworkExtension framework видит `nil` (= "tunnel up") и переключает статус в `.connected`. UI показывает "Connected" хотя на самом деле через пару секунд может прийти `.error`.

**Что увидит пользователь:** "Connected" на UI, но сайты не открываются 30 секунд (handshake timeout где-то на сервере) → потом резкий "Disconnected" без понятного объяснения.

**Фикс:** убрать `callStartCompletionOnce(nil)` из строки 411. Оставить только путь через `onStatus` где `frame.state == .connected`. Добавить таймаут 15-30 сек — если не подключилось, вернуть error.

### 4. Bundle id переименовали — миграция не написана, пользователи теряют профили

**Где:** entitlements/project.yml уже на `com.ghoststream.client` + `group.com.ghoststream.client`, но нигде нет кода миграции из старого `group.com.ghoststream.vpn`

**Что:** Старая версия (≤0.23.x) хранила `profiles.json`, Keychain items с PEM, и preferences в `group.com.ghoststream.vpn`. После обновления на v0.24+ приложение читает только новый App Group — **старые данные становятся недоступны**.

**Что увидит пользователь:** Обновил app → выглядит как fresh install. Нет ни одного профиля. Все PEM-сертификаты потеряны. Старый `NETunnelProviderManager` (`com.ghoststream.vpn.tunnel`) болтается в System Settings как мёртвая конфигурация.

**Фикс:** на первом запуске после обновления:
1. Скопировать `profiles.json` + preference keys из `UserDefaults(suiteName: "group.com.ghoststream.vpn")` в новый suite.
2. Скопировать Keychain items со старой access group в новую.
3. Удалить старый `NETunnelProviderManager` через `removeFromPreferences()`.

### 5. CI релиз сломан — `release.yml` использует старый bundle id

**Где:** `.github/workflows/release.yml:344-345`

**Что:** CI пытается установить provisioning profile для `com.ghoststream.vpn` / `com.ghoststream.vpn.tunnel`, но проект уже на `com.ghoststream.client`. App identifier check на строке 335-338 всегда fail'ится. Релиз через `git push v*` не пройдёт.

Хуже того: если когда-нибудь зарегистрируют чужой profile с `com.ghoststream.vpn`, билд произведётся с **чужим entitlements set** — это другая App Group, другой Team ID, потенциально доступ к Keychain ломается → fallback на shared default keychain (см. п. 6).

**Фикс:** в `.github/workflows/release.yml:344-345` заменить `com.ghoststream.vpn` → `com.ghoststream.client` и `com.ghoststream.vpn.tunnel` → `com.ghoststream.client.tunnel`.

### 6. Keychain fallback пишет PEM в default keychain без access group

**Где:** `apps/ios/Packages/PhantomKit/Sources/PhantomKit/Storage/Keychain.swift:85-91`

**Что:** Если запись в Keychain c access group вернула `errSecMissingEntitlement`, код удаляет access group и пытается снова. **Если provisioning profile неправильно подписан**, сертификат и приватный ключ запишутся в **default user keychain** — доступный любому приложению под этим пользователем.

**Что произойдёт:** На сломанном CI (пункт 5) или при ручной сборке без правильного profile — секреты VPN утекают в shared keychain. Любой process под пользователем может прочитать.

**Фикс:** удалить fallback. Лучше бросить ошибку и не сохранять секреты вообще, чем сохранять их без access group.

### 7. Disconnect виснет 75 секунд если нажать в момент handshake

**Где:** `crates/client-core-runtime/src/supervise.rs:400-470` + `crates/client-common/src/tls_handshake.rs:14-99`

**Что:** Когда supervisor итерирует `n_streams` TLS handshakes, каждый делает `TcpStream::connect` (до 75с до SYN timeout). Если в этот момент пользователь жмёт Disconnect, `cancel` сигнал не пересматривается до завершения текущей итерации handshake — нет `tokio::select!`.

**Что увидит пользователь:** Нажал Disconnect → UI на "tuning..." висит до 75 секунд → пользователь думает что приложение зависло.

**Фикс:** обернуть `tls_connect` в `tokio::select! { _ = handshake_loop => ..., _ = wait_cancelled(&mut cancel) => return Err(anyhow!("cancelled")) }`. Или `tokio::time::timeout(15s, tls_connect)`.

### 8. Sleep/wake/network-change не обрабатывается вообще

**Где:** ни в Provider, ни в host app нет `NWPathMonitor`, нет `NSWorkspace.willSleepNotification`, нет override `sleep(completionHandler:)` / `wake()`.

**Что:** MacBook закрыли крышку с активным VPN. После wake TCP socket'ы мертвы, но Rust runtime не знает — ждёт пакетов до `RX_IDLE_TIMEOUT_SECS = 45`. Только через 45 секунд supervisor начнёт reconnect (с backoff).

**Что увидит пользователь:** После wake — 30-90 секунд "тишины" (Connected на UI, но трафик никуда не идёт) перед автоматическим reconnect. Если плохая сеть — может дольше. Это **главный use case для macOS**.

**Фикс:**
1. Override `sleep(completionHandler:)` и `wake()` в `PacketTunnelProvider` — на wake форсировать reconnect.
2. Добавить `NWPathMonitor` подписку — при path change форсировать reconnect.
3. Уменьшить `RX_IDLE_TIMEOUT_SECS` с 45 до 30 для быстрой реакции на dead socket.

### 9. Wire format drift — пять полей `StatusFrame` Rust шлёт, Swift игнорирует

**Где:** `crates/gui-ipc/src/lib.rs:335-381` vs `apps/ios/Packages/PhantomKit/Sources/PhantomKit/Models/StatusFrame.swift:5-85`

**Что:** Rust runtime после ADR 0008 добавил `last_rx_ms`, `last_tx_ms`, `idle_rx_secs`, `health` (`TunnelHealth`), `bandwidth_class` (`BandwidthClass`) — это TSPU throttle detector, "Stale"/"Degraded" health классификация. Swift `StatusFrame` останавливается на `reconnectNextDelaySecs` и ничего из этого не знает. `JSONDecoder` тихо игнорирует unknown keys.

**Что увидит пользователь:** Throttling сервером не виден в UI. "Stale" / "Degraded" статусы — невидимы. Вся работа по ADR 0008 для macOS лежит мёртвым грузом.

**Фикс:** добавить 5 полей в Swift `StatusFrame` через `decodeIfPresent`, плюс прокинуть через `VpnStateManager.statusFrame` в UI.

### 10. `routeSettingsTask` объявлен, отменяется, но никогда не присваивается

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:27, 114, 229, 684`

**Что:** Поле `private var routeSettingsTask: Task<Void, Never>?` — `?.cancel()` вызывается в трёх местах, но **никто не пишет в это поле**. Cancel всегда no-op. В `handleAppMessage` `.updateRoutePolicy` создаёт новый `Task { ... }` без сохранения. Если `UpstreamVpnMonitor` пришлёт два update'а подряд (например при смене Cisco Secure Client off+on), два параллельных `setTunnelNetworkSettings(...)` могут racе'нуться.

**Что увидит пользователь:** иногда route table в неконсистентном состоянии после быстрых изменений конфига — DNS может уйти на неправильную matchDomain или route partially apply'нется.

**Фикс:** либо реально `routeSettingsTask = Task { ... }`, либо сериализовать через `actor`/`AsyncSemaphore`.

### 11. IPC принимает три разных формата — `"stop"` строкой убивает туннель

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:270-307`

**Что:** `decodeIpcMessage` пытается три стратегии: canonical Codable, JSON с key probing, и **plain UTF-8 строки**. Любой кто отправит сырую строку `"stop"` через `sendProviderMessage` — остановит туннель. Любой кто отправит `{"disconnect": "no"}` — тоже остановит (потому что probing просто смотрит на наличие ключа).

**Что увидит пользователь:** Если другой dev-tool или debug app имеет access к `NETunnelProviderSession` — может неожиданно дисконнектнуть VPN.

**Фикс:** Оставить только канонический Codable путь. Стратегии 2 и 3 — это dev-time conveniences, в shipping build не нужны.

### 12. `filteredLogs` пересчитывается на каждый body 3+ раза = main thread залипает

**Где:** `apps/macos/GhostStream/UI/Logs/TailView.swift:586-595`

**Что:** Computed property `filteredLogs` — `var` без кэша. Каждое body чтение её 3+ раза (в `detailHead.count`, `tailTable` empty check, `ForEach`). На лог-буфере в 50_000 строк фильтр итерирует и делает `localizedCaseInsensitiveContains` каждый раз. Плюс `formatTs(_:)` аллоцирует новый `DateFormatter` на каждую видимую строку.

**Что увидит пользователь:** Окно логов открыто 10 минут → главный thread залипает на 200-500ms за каждый поступающий лог. Прокрутка дёргается. Вентилятор крутится.

**Фикс:** кэшировать `filteredLogs` в `@State`, обновлять только при изменении `logs.count`/`activeFilter`/`searchText` через `onChange`. `DateFormatter` сделать `private static let`.

---

## Полные списки по категориям

### A. FFI и lifecycle (Rust ↔ Swift граница)

| ID | Описание | Файл |
|---|---|---|
| FFI-C1 | **BridgeContext leak + UAF risk** (см. топ‑1) | `PhantomBridge.swift:138-196` + `client-apple/src/lib.rs:367-386` |
| FFI-C2 | `phantom_runtime_stop` возвращается до завершения supervisor — старые callback'и могут попасть в новые handlers следующего start'а | `client-apple/src/lib.rs:367-386` |
| FFI-C3 | `log_cb` task не abort'ится — между stop и следующим start любой `tracing!` зовёт `lcb(old_ctx)` | `client-apple/src/lib.rs:305-315` + `client-core-runtime/src/logsink.rs:60-71` |
| FFI-C4 | iOS `Callback` reverse-forwarder deadlock на reconnect при idle network — old forwarder парк'нут на recv с lock'ом, new ждёт lock | `client-core-runtime/src/lib.rs:453-488` |
| FFI-C5 | `pub extern "C"` функции дереференсят raw pointers без `unsafe` модификатора — clippy `not_unsafe_ptr_arg_deref` fail; Rust 2024 это закрутит | `client-apple/src/lib.rs:167, 338, 395, 454, 491` |
| FFI-C6 | `panic = "abort"` в workspace release profile делает все `catch_unwind` в FFI no-op'ом — любая паника в Rust = abort extension | `Cargo.toml:25` |
| FFI-C7 | `block_on(client_core_runtime::run(...))` в `phantom_runtime_start` блокирует Swift caller (`startTunnel` thread) на десятки-сотни миллисекунд при больших PEM | `client-apple/src/lib.rs:281` |
| FFI-H1 | `phantom_runtime_submit_inbound` принимает `len: usize` без upper bound — Swift bug с гигантским `len` = OOM или OOB read | `client-apple/src/lib.rs:338-360` |
| FFI-H2 | `CStr::from_ptr` без length bound — non-NUL-terminated buffer от Swift = SIGBUS, не ловится `catch_unwind` | `client-apple/src/lib.rs:182, 207, 400, 459` |
| FFI-H3 | `logsink::add_sender/clear_senders/subscribe` `unwrap()` на `std::sync::Mutex` poison — паника на FFI path | `client-core-runtime/src/logsink.rs:51, 61, 69` |
| FFI-H4 | `.expect("spawn tun reader/writer thread")` в hot path runtime'а — при PID/thread cap = abort | `client-core-runtime/src/lib.rs:330, 372` |
| FFI-H5 | Release default log spec `"info"` не включает `phantom_client_apple=debug` — но `anyhow::Error` Display от `base64::DecodeError`/`FromUtf8Error` может leak'нуть исходные байты PEM в логи (latent secret leak) | `client-apple/src/lib.rs:49-55, 410-415` |
| FFI-M1 | `OutboundDispatcher` может быть вызван reentrantly из разных tokio workers через reconnect — Swift NEPacketFlow expects specific queue | `client-core-runtime/src/lib.rs:466-472` |
| FFI-M2 | `frame.clone()` (включая `BTreeMap<String, String>`) на каждом log event для каждого subscriber — hot-path allocation | `client-core-runtime/src/logsink.rs:91` |
| FFI-M3 | `BTreeMap<String, String>` в `LogFrame.fields` без size cap — malicious peer может прислать 50MB JSON, helper аллоцирует весь map (Linux helper path) | `gui-ipc/src/lib.rs:438-444` |

### B. UI (SwiftUI)

| ID | Описание | Файл |
|---|---|---|
| UI-C1 | **`filteredLogs` пересчитывается 3+ раза за render** (см. топ‑12) | `TailView.swift:586-595` |
| UI-C2 | `DateFormatter` аллоцируется на каждую строку лога — лагает экспорт + прокрутка | `TailView.swift:759-764` |
| UI-C3 | `NSEvent.addLocalMonitorForEvents` ловит **все** ⌘C/⌘F/⌘L/⌘E приложения — копирование текста в любом TextField сломано пока TailView в дереве | `TailView.swift:671-693` |
| UI-C4 | CommandPalette: и `.onKeyPress(.return)`, и `.onSubmit` оба срабатывают на Enter → два `installAndStart` одновременно | `CommandPalette.swift:80-83, 104-107` |
| UI-C5 | `showInDock = false` + `connected` → **нет ни одного видимого Quit affordance** | `MenuBarPopover.swift:395-406` + `AppDelegate.swift:46-50` |
| UI-C6 | TailView shortcut monitor устанавливается в **двух местах** одновременно (вкладка TAIL + detached Logs window) — ⌘E открывает два Save panel'а modally → заклинит | `TailView.swift:55, 671-693` |
| UI-H1 | CONNECT кнопка не disabled во время `connecting`/`reconnecting` — rapid click создаёт 3-5 Task'ов на `installAndStart`, плюс множит `NETunnelProviderManager.saveToPreferences` | `DashboardView.swift:197-217`, `MenuBarPopover.swift:220-229` |
| UI-H2 | Хардкод `"Логи"` в footer popover'а — английская локаль ломается | `MenuBarPopover.swift:397` |
| UI-H3 | `tunnel.lastError` остаётся видимым после успешного Disconnect — красная ошибка в idle state | `MenuBarPopover.swift:230-244, 441-444` |
| UI-H4 | Endpoint/SNI/TUN IP в Dashboard без `lineLimit/truncationMode` — длинный IPv6 или DNS-имя выталкивает CONNECT кнопку за край | `DashboardView.swift:156-194` |
| UI-H5 | Многострочный `inlineConnectError` в фиксированной по высоте popover'е выталкивает footer | `MenuBarPopover.swift:60, 230-236` |
| UI-H6 | WelcomeWindow целиком хардкоженный русский — английская локаль показывает кириллицу | `WelcomeWindow.swift` (весь файл) |
| UI-H7 | CommandPalette: мутирующий `var index` в ViewBuilder + неконсистентный `filteredItemCount` — selection отстаёт от подсветки при rapid вводе | `CommandPalette.swift:157-167` |
| UI-H8 | Двойной `scrollToBottom` от двух `onChange` — рваная анимация follow-tail | `TailView.swift:366-373` |
| UI-H9 | `OnboardingCoordinator` использует `weak` ссылки на singleton'ы — при cold start с медленным Keychain wizard прыгает на step 1 несмотря на сохранённый профиль | `OnboardingCoordinator.swift:50-53` |
| UI-H10 | WelcomeWindow закрывается тремя путями — в русской локали title=="Welcome" не сработает | `WelcomeWindow.swift:55-63` |
| UI-H11 | TailView monitor не снимается при tab-switch в NavigationSplitView — `onDisappear` не всегда триггерится при swap detail view | `TailView.swift:55-56` |
| UI-H12 | Hardcoded RGB точки статуса в menubar — слабый контраст в light mode | `MenuBarStatusItem.swift:43, 47, 51` |
| UI-H13 | Множественные источники ошибки CONNECT без активного профиля — три UI surface показывают одну ошибку | `MenuBarPopover.swift:447-453`, `CommandPalette.swift:494-537` |
| UI-H14 | TextEditor для CIDR-листа парсит на каждый keystroke — paste 1000 строк = freeze UI | `SettingsView.swift:389, 398-404` + `PreferencesStore.swift:242-253` |
| UI-M1 | BUILD timestamp в Settings захардкожен `"2026.04.27.0142"` | `SettingsView.swift:86` |
| UI-M2 | `textFaint` цвет не проходит WCAG AA (contrast ~3.1-3.7) — ALL CAPS подписи нечитаемы | `Colors.swift:93, 109` |
| UI-M3 | Длинные имена профилей растягивают Menu в sidebar без `lineLimit` | `SidebarProfileBlock.swift:52` |
| UI-M4 | ServerRosterView: tap на колонку конфликтует между sort и setActive | `ServerRosterView.swift:33-35` |
| UI-M5 | `rosterStatus` после успешного импорта окрашен в `C.warn` (warning yellow), без TTL — успехи выглядят как ошибки | `ServerRosterView.swift:131-134` |
| UI-M6 | ProfileEditorSheet: `importError = "Неверная ghs:// строка"` хардкод русского | `ProfileEditorSheet.swift:120` |
| UI-M7 | Нет `accessibilityLabel` на GhostFab/PulseDot/ScopeChart/MuxBars | shared `PhantomUI` |
| UI-M8 | Custom fonts через `.font(.custom(...))` silently возвращают system если font не зарегистрирован — нет логирования | везде |
| UI-M9 | TailView toolbar overflow при ширине ниже ~700pt — пиллы фильтра наезжают на кнопки | `TailView.swift:101-235` |
| UI-L1/L2/L3 | Hardcoded русские строки в welcome rail, "⌘W чтобы закрыть", "Нет совпадений" | `WelcomeWindow.swift:106-111, 653`, `CommandPalette.swift:152` |

### C. Provider / Extension lifecycle

| ID | Описание | Файл |
|---|---|---|
| PROV-C1 | **`completionHandler(nil)` до handshake** (см. топ‑3) | `PacketTunnelProvider.swift:411` |
| PROV-C2 | **IPv6 leak — пустой `NEIPv6Settings`** (см. топ‑2) | `PacketTunnelProvider.swift:492-498` |
| PROV-C3 | `writePackets([data], withProtocols: [AF_INET])` — IPv6 пакеты помечаются как IPv4 → drop | `PacketTunnelProvider.swift:382` |
| PROV-H1/H2 | **Нет `NWPathMonitor` и нет sleep/wake handlers** (см. топ‑8) | везде в Provider |
| PROV-H3 | `updateRoutePolicy` пересоздаёт `setTunnelNetworkSettings` без debounce — `reasserting` шторм при частых route changes | `PacketTunnelProvider.swift:674-691` |
| PROV-H4 | `loadProfile` throws → catch вызывает `callStartCompletionOnce(error)`, но **никогда не вызывает `cancelTunnelWithError`** и не делает `phantom_runtime_stop` — runtime остаётся в неконсистентном state | `PacketTunnelProvider.swift:431-465` |
| PROV-H5 | `actionForReplacingExtension` всегда `.replace` без проверки версии — downgrade attack возможен | `SystemExtensionInstaller.swift:91-96` |
| PROV-H6 | `Task { await box.bridge.handleInbound }` на каждый incoming пакет — unbounded backlog при 5-10k pkts/sec | `PhantomBridge.swift:160-164` |
| PROV-H7 | `AsyncStream<[Data]>` в outboundLoop без `bufferingPolicy` (= `.bufferingNewest(Int.max)`) — heap leak при backpressure | `PacketTunnelProvider.swift:723-745` |
| PROV-H8 | `UserDefaults(suiteName:)` пишется конкурентно из host и extension без межпроцессного lock — `synchronize()` deprecated, last writer wins | `PacketTunnelProvider.swift:752-764` |
| PROV-H9 | `LogFileWriter.dayFormatter` в UTC — архивы по UTC, не по локальному времени пользователя | `LogFileWriter.swift:49-55` |
| PROV-M1 | `LogFileWriter.flush(timeout: 1s)` может пропустить tail при busy queue | `LogFileWriter.swift:107-116` |
| PROV-M2 | `stopTunnel` не различает `.userInitiated` vs `.providerFailed` — один code path для всего | `PacketTunnelProvider.swift:101-133` |
| PROV-M3 | `handleAppMessage` без version check — новый host + старый extension = silent decode_failure без понятной ошибки UI | `PacketTunnelProvider.swift:137-255` |
| PROV-M4 | `OSSystemExtensionRequest.didFailWithError` без category-specific retry/backoff — `requestSuperseded` не auto-retried | `SystemExtensionInstaller.swift:132-143` |
| PROV-M5 | `OnboardingCoordinator.startPollingApproval` polls every 1.5s — может пропустить кратковременные state transitions | `OnboardingCoordinator.swift:189-209` |
| PROV-M6 | `excludedRoutes ∩ includedRoutes` может пересекаться при `layeredAuto` mode — поведение macOS undefined | `PacketTunnelProvider.swift:620-630` |

### D. IPC и persistence

| ID | Описание | Файл |
|---|---|---|
| IPC-C1 | **5 полей `StatusFrame` Swift не знает** (см. топ‑9) | `gui-ipc/src/lib.rs:335-381` + `StatusFrame.swift:5-85` |
| IPC-C2 | **`routeSettingsTask` объявлен, отменяется, но не присваивается** (см. топ‑10) | `PacketTunnelProvider.swift:27, 114, 229, 684` |
| IPC-C4 | **Bundle id migration отсутствует** (см. топ‑4) | entitlements + ProfilesStore |
| IPC-H1 | `subscribeLogs(sinceMs: 0)` первой polling может прислать весь 10k frame буфер за один XPC — payload до 3MB, может silently drop, host навсегда сломан до restart extension | `PacketTunnelProvider.swift:170-184, 931-941` + `TunnelLogStore.swift:24-119` |
| IPC-H2 | **IPC принимает три формата** (см. топ‑11) | `PacketTunnelProvider.swift:270-307` |
| IPC-H3 | `vpn.state.v1` записывается, но никогда не читается — dead IPC channel, дублирующий `snapshot.json` Darwin notif | `PacketTunnelProvider.swift:749-756` |
| IPC-H4 | PhantomBridge callbacks от старой session могут долететь до новой (через actor's pending task queue) — UI флэшит stale Connected | `PhantomBridge.swift:148-167, 188-196` |
| IPC-H5 | `TunnelIpcBridge.Response.profile` определён, но Provider'ом не используется — `.getCurrentProfile` всегда возвращает `.ok` | `TunnelIpcBridge.swift:25-30` + `PacketTunnelProvider.swift:185-193` |
| IPC-M1 | Status frame fan-out 4Hz без `StatusBroadcastGate` — ~4 file writes/sec, ~4 Darwin posts/sec, ~4 XPC round-trips/sec | `PacketTunnelProvider.swift:916-922` + `VpnStateManager.swift:93-100, 160-192` |
| IPC-M2 | `VpnProfile` Codable требует все non-Optional fields — добавление поля в Rust ломает декод старых profiles silently | `VpnProfile.swift:16-77` |
| IPC-M3 | `ConnState` enum без `@unknown` case — новая Rust-side variant ломает весь `StatusFrame` decode → status замораживается | `ConnState.swift:3-19` |
| IPC-M4 | `connecting` пишется дважды (в `vpn.state.v1` + в snapshot) — двойная Darwin notification | `PacketTunnelProvider.swift:311-332` |
| IPC-L1 | `ConnState.as_ui_word` Rust ↔ Swift расходятся (English vs localized) | `gui-ipc/src/lib.rs:295-305` |
| IPC-L2 | OnboardingCoordinator опрашивает `sysExt.state` polling'ом вместо `@Observable` | `OnboardingCoordinator.swift:189-209` |

### E. Security

| ID | Описание | Файл |
|---|---|---|
| SEC-C1 | **CI release.yml bundle id mismatch** (см. топ‑5) | `.github/workflows/release.yml:344-345` |
| SEC-C2 | **Keychain fallback в shared default keychain** (см. топ‑6) | `Keychain.swift:85-91, 116-119, 138-141` |
| SEC-H2 | `snapshot.json` пишется без `setAttributes(posixPermissions: 0o600)` — наследует umask (0644), читаем под root | `PacketTunnelProvider.swift:758-782` |
| SEC-H3 | `handleAppMessage` без аутентификации sender'а — любой процесс с tunnel-provider entitlement (или с access к session) может вызвать `disconnect`/`updateRoutePolicy` | `PacketTunnelProvider.swift:137-255` |
| SEC-H4 | `cfg.network.insecure` flag читается прямо в supervise.rs — local attacker может modify App Group profile → MITM | `client-core-runtime/src/supervise.rs:167` |
| SEC-M1 | `providerConfiguration` декодируется без HMAC/version check — root может modify `/Library/Preferences/com.apple.networkextension*.plist` → traffic re-routing через attacker.com | `PacketTunnelProvider.swift:435-454` |
| SEC-M2 | `profile.serverAddr` без URL scheme validation — `host:port` парсится из любого JSON | `PacketTunnelProvider.swift:484, 599-602` |
| SEC-M3 | `GHOSTSTREAM_LOG` env var обходит filter — local user может выставить `trace` и получить packet-level logs в release | `client-apple/src/lib.rs:64` |
| SEC-M4 | `tracing::info!("Loading client TLS certificate from {}", cp)` — path может содержать user-controlled unicode | `client-common/src/helpers.rs:268, 276, 293` |
| SEC-M5 | `ipv6Killswitch=false` default разрешает IPv6 leak (см. PROV-C2) | `PacketTunnelProvider.swift:493-498` |
| SEC-M6 | `lockdownPermissions` устанавливает 0600 только на новые файлы — pre-existing rotated archives могут остаться 0644 | `LogFileWriter.swift:160-163` |
| SEC-L1-L5 | Generic Apple review notes; TLS cipher suites OK (rustls TLS1.3 default); Hardened Runtime включён правильно; `Sparkle` присутствует в derived data, но не интегрирован | разные |

### F. Concurrency / Lifecycle

| ID | Описание | Файл |
|---|---|---|
| CONC-C1 | **`tls_connect` не cancelable — Disconnect виснет 75s** (см. топ‑7) | `supervise.rs:400-470` + `tls_handshake.rs:14-99` |
| CONC-C2 | **Sleep/wake/network-change не обрабатывается** (см. топ‑8) | везде |
| CONC-H1 | `stopTunnel` не вызывает `setTunnelNetworkSettings(nil)` — DNS/routes остаются "залипшими" | `PacketTunnelProvider.swift:101-133` |
| CONC-H2 | IPC `.disconnect` не propagates в систему — NE по-прежнему думает что `.connected`, runtime мёртв, host думает `.disconnected` → state desync | `PacketTunnelProvider.swift:223-254` |
| CONC-H3 | `VpnStateManager.statusObserver` привязан к одному manager'у — при reload (новый профиль) observer становится stale, status events не доходят | `VpnStateManager.swift:108-127` |
| CONC-H4 | `VpnTunnelController` mixed `ObservableObject` + `@Published` несмотря на `@MainActor` — техдолг между двумя SwiftUI парадигмами | `VpnTunnelController.swift:33-37` |
| CONC-H5 | `PhantomBridge.start()` без проверки уже-running — повторный start без stop перезаписывает handlers | `PhantomBridge.swift:105-172` |
| CONC-M3 | `SystemExtensionInstaller.activate()` guard'ит только `.requestPending`/`.awaitingUserApproval` — повторный activate из `.activated` сбрасывает state | `SystemExtensionInstaller.swift:55-79` |
| CONC-L1 | `applicationShouldTerminate` отсутствует — Cmd-Q при connected тихо quit'ит, extension продолжает работать как daemon | `AppDelegate.swift:14-51` |
| CONC-L2 | `VpnStateManager.statusObserver` никогда не removed — minor leak в singleton'е | `VpnStateManager.swift` |

---

## Stress-test сценарии (что проверить руками)

Эти сценарии воспроизводят баги из топ-12 — стоит прогнать после фиксов:

1. **Sleep test:** Connect → закрыть крышку на 30 минут → разбудить. Замерить сколько секунд до восстановления трафика. (CONC-C2, PROV-H1/H2)
2. **Network switch storm:** Connect → переключить Wi-Fi → cellular → Wi-Fi быстро. Проверить — реагирует ли runtime, нет ли застрявших streams. (PROV-H1)
3. **Connect storm:** открыть MenuBar → нажать Connect 10 раз подряд за 5 секунд. (UI-H1, FFI-C1, CONC-H5)
4. **Cancel during handshake:** перенаправить трафик на сервер с DPI блокировкой → нажать Connect, через 1 сек нажать Disconnect. Ожидание: должно отключиться сразу, а не через 75 сек. (CONC-C1)
5. **IPv6 leak:** Connect → `curl -6 https://ifconfig.io/v6` → должен вернуть серверный IPv6, а не реальный. (PROV-C2/C3)
6. **IPC disconnect:** через IPC отправить `.disconnect` → проверить `manager.connection.status`. Должно быть `.disconnected`, не `.connected`. (CONC-H2)
7. **Profile rotation:** Connect → удалить активный профиль → импортировать новый → Connect. Проверить что status events приходят. (CONC-H3)
8. **Memory leak under stress:** Connect/Disconnect 1000 раз через скрипт. Замерить footprint extension'а и host'а через каждые 100 итераций. (FFI-C1, IPC-C3)
9. **Force-kill extension:** `sudo kill -9 <pid of com.ghoststream.client.tunnel>`. Host должен распознать через `NEVPNStatusDidChange` → `.disconnected`. (PROV-M2)
10. **Upgrade from v0.23.x:** установить старую версию (если есть), создать профиль, обновить на v0.24+ → проверить что профили на месте. (IPC-C4) — **сейчас потеряются**.
11. **Stop+Start race:** Connect → сразу Disconnect → Connect → измерить латентность; смотреть нет ли в логах "duplicate inbound from previous session". (FFI-C2, IPC-H4)
12. **Quit during connected:** Cmd-Q при активном VPN. UI исчезает. Extension продолжает работать. Reopen — UI восстанавливается без потерь. (CONC-L1)

---

## Архитектурные слабости (паттерны, не отдельные баги)

1. **macOS Provider — degraded copy of iOS Provider.** iOS реализует IPv6 ULA tunneling, AdminGateway IPv4 route preservation, robust IPv6 split routing, `manualDirectIpv6Cidrs`, `directIpv6RoutesForRouteComputation`. На macOS этих компонентов **нет вовсе**. Это означает что macOS клиент менее secure (IPv6 leak), менее flexible (нет IPv6 split routing), и сложнее в поддержке (два расходящихся code path'а). **Рекомендация:** вынести общие primitives в PhantomKit как `PacketTunnelCommon.swift`, чтобы Mac и iOS использовали одну реализацию.

2. **FFI bridge через `Unmanaged.passRetained` + opaque pointer — leaky abstraction.** Текущая модель не имеет clean lifecycle: retain count не balanced, нет formal stop barrier, нет session id'ов. Android прошёл переделку в v0.25.1 (W3-9, W3-10) с `JniSafeGlobalRef` и proper join — Apple FFI не получил аналогичных fix'ов.

3. **`completionHandler(nil)` лжёт системе.** На обеих платформах (iOS + macOS). Это **архитектурное решение, которое стоит исправить во всех клиентах** — даст системе шанс правильно отметить туннель как failed и не отрисовывать стрелку VPN в menubar при отсутствии connectivity.

4. **`panic = "abort"` workspace-wide + множество `unwrap`/`expect` в FFI** — несовместимо. Любая паника = abort extension. Либо `panic = "unwind"` для Apple профиля, либо вычистить все unwrap'ы с reachable путей.

5. **Provider не интегрируется с macOS power management** — нет `NSWorkspace`/`IOPMConnection`/`NWPathMonitor`. Это всё мусор для laptop'а user'а, где сон + смена сети — ежедневный сценарий.

6. **Дублирующиеся state каналы** — `vpn.state.v1` UserDefaults + `vpn.statusFrame.v1` UserDefaults + `snapshot.json` файл + Darwin notification. Каждый Source-of-truth конфликтует с другими. Единый источник — `snapshot.json` + одна Darwin notif — упростил бы и снизил конкуренцию.

7. **Wire format нет version negotiation.** Host v0.30 + extension v0.24 будут разговаривать на разных языках через тихий ignore unknown fields. Apple App Group UserDefaults не идемпотентен между процессами.

8. **Локализация частичная.** Половина приложения — `String(localized:)`, половина — `"Логи"`, `"Подключись"`, `"Неверная ghs:// строка"` хардкод. Английская локаль показывает русский text в любом из этих мест.

---

## Открытые вопросы

1. **Bundle id migration (IPC-C4):** что делаем с users v0.23.x — auto-migrate silently, prompt the user, или accept data loss?
2. **`decodeIpcMessage` strategies 2 и 3 (IPC-H2):** оставлять для dev convenience или удалить для shipping?
3. **`completionHandler` semantics:** ждать handshake (15-30s) или сразу `nil` для responsive UI? Стоит обсудить с UX перспективой.
4. **`contextBox` leak vs explicit drain:** какой подход больше нравится — Rust signals when watcher tasks have all returned, или accept leak as deliberate trade-off?
5. **Killswitch при extension crash:** macOS не имеет equivalent Android `ALWAYS_ON_VPN`. Документировать как ограничение или искать workaround?
6. **Force-quit host app:** хочет ли пользователь чтобы extension продолжил работать как daemon? Если нет — нужен health-check у extension через IPC.
7. **`Sparkle` в derived data, но не интегрирован.** Удалить из репо или интегрировать?

---

## Где смотреть детальные отчёты по агентам

Эти 6 отчётов агентов сохранены в .jsonl сессии. Полные тексты каждого можно вытащить из `~/.claude/projects/-Users-p-kurkin-ghoststream/` (текущий session id). Они содержат полные воспроизведения, точные line:column ссылки, и более развёрнутые "Что увидит пользователь" описания.

Идентификаторы агентов (для `SendMessage(to: ...)` если нужно задать follow-up вопрос):
- UI Adversary: `a34814af50686b32a`
- Provider Adversary: `af643b58713f9af99`
- Rust/FFI Adversary: `a4c0e63ceea4b5cfc`
- IPC/State Adversary: `abb7f11d944e6bf5c`
- Security Adversary: `afa120420112893c1`
- Concurrency/Lifecycle Adversary: `a98b01062116a8ea0`

---

## Версия и метаданные

- **Версия protected:** v0.24.0 build 20 (как в `apps/macos/project.yml`)
- **Дата аудита:** 2026-05-17
- **Метод:** 6 параллельных Claude Opus агентов, read-only (без правок кода)
- **Известные fixes, исключённые из отчёта:** MuxBars infinite collapse, TailView placeholder collapse, follow-tail anchor, TOCTOU в STATE, startCompletionHandler без NSLock, stopTunnel не awaits outboundTask, env::set_var из client-apple, serde::Error sanitized, LogFileWriter в App Group container с 0600, `VpnProfile.sanitizedForProviderConfiguration`.
