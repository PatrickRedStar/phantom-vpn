---
title: macOS GhostStream — Round 2 Re-Hunt после Round 1 fixes
date: 2026-05-17
type: audit
status: open
prior-audit: 2026-05-17-macos-bug-hunt.md
fix-commits-round1: 32d8842, aa1b401, 630671e, af9e1fa
---

# Round 2 Bug Hunt — макОС GhostStream

## Как собрано

После Round 1 fix wave (4 параллельных implementer'а в worktrees, merged в master), запустили 6 опус adversary-агентов снова. Каждый сравнивал свою зону с Round 1 фиксами и искал:
- **Регрессии** (что-то починили — что-то сломали)
- **Не починенные** баги из Round 1 (остались открытыми)
- **Новые** баги вокруг изменённого кода

Из 6 агентов:
- ✅ **UI Adversary** — 11 регрессий + 28 новых
- ✅ **Provider Adversary** — 6 регрессий + 17 новых
- ❌ **Rust/FFI Adversary** — token limit hit (анализирован orchestrator'ом из commit diff)
- ❌ **IPC/State Adversary** — token limit hit
- ✅ **Security Adversary** — 9 новых + 6 регрессий/info
- ✅ **Concurrency/Lifecycle Adversary** — 14 находок
- ✅ **Operations Adversary** — 13 находок

**Итого ~104 находки в Round 2.**

## TL;DR — пофиксили много багов = создали новые

User intuition подтвердилась. Round 1 fixes:
- Решили исходные 26 CRITICAL (BridgeContext, IPv6 leak, completionHandler, migration, CI, keychain fallback, disconnect 75s, sleep/wake, StatusFrame, routeSettingsTask, IPC strict, filteredLogs)
- Создали несколько новых CRITICAL (миграция race, 9s sync stop, wake armHandshakeTimeout race, ⌘K collision, CONNECT disabled trap, Provider leak)
- Оставили несколько не починенными (handleAppMessage auth, supervise.rs anyhow leak, GHOSTSTREAM_LOG в release, WelcomeWindow рус)

## Топ-10 CRITICAL что чинить в Round 3

### 1. Миграция v0.23→v0.24 не работает — пустой state на первом запуске (OPS-R2-04 / SEC-R2-N01)

**Где:** `apps/macos/GhostStream/App/GhostStreamApp.swift:27-29` + `apps/macos/GhostStream/Service/VpnStateManager.swift:67-74` + `apps/ios/Packages/PhantomKit/Sources/PhantomKit/Storage/ProfilesStore.swift:39-52`

**Что:** `@State` SwiftUI инициализирует singletons **в порядке объявления**:
```swift
@State private var profiles = ProfilesStore.shared       // FIRST → читает пустой новый App Group
@State private var prefs    = PreferencesStore.shared
@State private var state    = VpnStateManager.shared     // ЗАПУСКАЕТ LegacyMigration.runIfNeeded()
```

ProfilesStore.init() читает new App Group → пусто → `profiles = []`. Затем VpnStateManager.init() запускает migration → копирует данные → но **ProfilesStore их не видит** (нет reload).

Save() позже **затирает** скопированные данные пустым массивом.

**Главная фича Round 1 — IPC-C4 миграция — НЕ РАБОТАЕТ.**

**Фикс:** перенести `LegacyMigration.runIfNeeded()` в `static let _ = LegacyMigration.runIfNeeded()` в `ProfilesStore` сам (до load), либо в `AppDelegate.applicationWillFinishLaunching(_:)` ДО SwiftUI App scene init.

### 2. build-release.sh / ship-macos.sh не пересобирают xcframework (OPS-R2-01)

**Где:** `apps/macos/scripts/build-release.sh`, `apps/macos/scripts/ship-macos.sh`

**Что:** Implementer B добавил FFI symbol `phantom_runtime_set_release_cb`. Xcframework на disk обновлён локально вручную (через `crates/client-apple/build-xcframework.sh`). НО ни один build script не вызывает rebuild автоматически.

**Что произойдёт:** Следующий `ship-macos.sh` после `cargo clean` или `git stash` или с другой машины → линкер `Undefined symbol: _phantom_runtime_set_release_cb` → release fail.

**Фикс:** добавить в начало `build-release.sh`:
```bash
echo "==> Rebuilding PhantomCore.xcframework"
"$REPO_ROOT/crates/client-apple/build-xcframework.sh"
```

### 3. iOS bundle id mismatch (OPS-R2-02)

**Где:** `apps/ios/project.yml` (vpn) vs `apps/ios/*.entitlements` (client) vs `Keychain.swift:22` (client)

**Что:** macOS мигрирован на `com.ghoststream.client`, PhantomKit/Keychain.swift тоже. **iOS** project.yml остался на `com.ghoststream.vpn`, entitlements `client` — рассинхрон. Codesign на iOS будет fail.

**Фикс:** sync iOS bundle id + App Group аналогично macOS, либо rollback `Keychain.swift` к configurable identifier.

### 4. Wake handler armHandshakeTimeout race → tunnel убивается через 30s после wake (PROV-R2-R02)

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:206-267, 254`

**Что:** `forceRuntimeReconnect("wake")` вызывает `armHandshakeTimeout()` **после** `try await PhantomBridge.shared.start(...)`. Но `.connected` callback (который зовёт `cancelHandshakeTimeout`) асинхронный — может выстрелить ДО строки 254. После — `armHandshakeTimeout()` ставит **новый таймер** на 30 сек, никто его не отменяет. Через 30 сек → `cancelTunnelWithError(err)` → tunnel падает.

**Фикс:** `armHandshakeTimeout()` ДО `bridge.start()`. Или установить флаг `handshakeConfirmed` + check в timeout closure: `if state == .connected { return }`.

### 5. stopTunnel chain до 14s превышает macOS 15 Sequoia deadline → SIGKILL (CONC-R2-N03)

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:129-168, 455-496` + `crates/client-apple/src/lib.rs:534-636`

**Что:** Apple deadline на `stopTunnel` — 3-5 секунд (macOS 15+). Round 1 сделал `phantom_runtime_stop` синхронным с join-timeout'ами: 5s supervisor + 2s status + 2s log = до 9s. Плюс `setTunnelNetworkSettings(nil)` 1-3s + outbound await — может быть 12-14s total. После 5s → **SIGKILL extension** → snapshot.json не записан → host видит "Connected" навсегда.

**Фикс:** уменьшить timeout'ы: supervisor 2s + forwarders 0.5s = 3s max. Или async stop с deadline 3s, force-return после.

### 6. outboundLoop strong ref на self.packetFlow → Provider leak (PROV-R2-N03)

**Где:** `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:1036-1049`

**Что:** `scheduleRead()` capture'ит `self` strongly через `self.packetFlow.readPackets { ... scheduleRead() ... }`. После stopTunnel — packetFlow держит callback закрытие → Provider жив. На каждый Connect/Disconnect цикл — leak. За день работы — много зомби-Provider'ов.

**Фикс:** `[weak self] _ = self else { return }` в scheduleRead closure.

### 7. ⌘K shortcut collision: CONNECT (Dashboard) vs Clear Logs (TailView) (UI-R2-R01)

**Где:** `apps/macos/GhostStream/UI/Dashboard/DashboardView.swift:257` + `apps/macos/GhostStream/UI/Logs/TailView.swift:234`

**Что:** Оба `.keyboardShortcut("k", modifiers: .command)`. Ровно одновременно живы в UI tree (Dashboard + detached Logs window). ⌘K непредсказуемо: connect или clear buffer.

**Фикс:** Dashboard ⌘K (primary action) оставить. Clear logs → ⌘⇧Backspace или ⌘⌥K.

### 8. CONNECT disabled во время connecting → нет cancel mid-handshake (UI-R2-N20)

**Где:** `apps/macos/GhostStream/UI/Dashboard/DashboardView.swift:229-258`

**Что:** Round 1 UI-H1 fix disabled CONNECT кнопку при `busy = connecting || reconnecting`. Но это **единственный** способ отменить handshake. Если TLS зависает (CONC-C1 ещё актуально для slow servers) — кнопка disabled 75 сек, нет cancel.

**Фикс:** при `state == .connecting/.reconnecting` показывать кнопку "CANCEL…" вместо disabled, вызывать `tunnel.stop()` (force cancel).

### 9. UI-H3 hack чистит lastError на `.error → .disconnected` (UI-R2-R03)

**Где:** `apps/macos/GhostStream/UI/Dashboard/DashboardView.swift:58-62` + `MenuBarPopover.swift:68-72`

**Что:** Round 1 hack `.onChange(of: state) { if newState == .disconnected { tunnel.lastError = nil } }` — но real-world flow `.connecting → .error → .disconnected` → ошибка чистится через миллисекунду после её появления. Пользователь не понимает почему отвалилось.

**Фикс:** очищать lastError только при переходе **через** `.connected`:
```swift
.onChange(of: state) { old, new in
    if old == .connected && new == .disconnected {
        tunnel.lastError = nil
    }
}
```

### 10. CommandPalette overlay не блокирует underlying shortcuts (UI-R2-R02)

**Где:** `apps/macos/GhostStream/UI/Window/MainConsoleWindow.swift:31-34`

**Что:** Палитра как ZStack overlay. SwiftUI `.keyboardShortcut` на underlying tree (CONNECT с ⌘K, TailView clear с ⌘K) остаётся активным. Юзер печатает в палитре, accidentally ⌘K → CONNECT toggle / clear buffer.

**Фикс:** обернуть в `if !router.commandPaletteOpen { detailPane }` или `.disabled(router.commandPaletteOpen)`.

## Полный список регрессий и новых багов (compact)

### UI (39 находок)

**Регрессии Round 1:**
- UI-R2-R01: ⌘K collision Dashboard vs TailView (HIGH)
- UI-R2-R02: CommandPalette overlay не блокирует underlying shortcuts (HIGH)
- UI-R2-R03: UI-H3 hack clobbers error на .error→.disconnected (HIGH)
- UI-R2-R04: UI-H3 чистит ошибки от других источников (MEDIUM)
- UI-R2-R05: 300ms debounce регекса vs синхронный regexSearchError (MEDIUM)
- UI-R2-R06: ⌘L semantic change (clearFilters → ⌘K clearLogs) (MEDIUM)
- UI-R2-R07: rosterStatusTtlTask не cancel'ится onDisappear (LOW)
- UI-R2-R08: stateDot всегда `.dark` palette даже в light mode (LOW)
- UI-R2-R09: menu placeholder используется как menu title (LOW)
- UI-R2-R10: "Open Logs" hardcoded English (LOW)
- UI-R2-R11: footer ⌘⇧L hint не работает в popover (MEDIUM)

**Новые:**
- UI-R2-N01: двойная аллокация cachedFilteredLogs (~25 MB) при detached + inline TailView (MEDIUM)
- UI-R2-N02: actionStatus в TailView без TTL (LOW)
- UI-R2-N10: regexSearch toggle без debounce — 200ms freeze (MEDIUM)
- UI-R2-N15: ⌘1..⌘4 ломают text input в CommandPalette (MEDIUM)
- UI-R2-N20: **HIGH** — нет cancel во время connecting/reconnecting
- UI-R2-N22: NavigationSplitView a11y (MEDIUM)
- UI-R2-N23: Welcome ⌘W trap — застрял в onboarding (MEDIUM)
- UI-R2-N05/06/07/08/09/11/12/13/14/16/17/18/19/21/24/25/26/27/28: разные LOW UX edges

### Provider / Extension (23 находки)

**Регрессии:**
- PROV-R2-R01: **CRITICAL** — `handshakeTimeoutTask` race без lock
- PROV-R2-R02: **CRITICAL** — wake → tunnel kill через 30s
- PROV-R2-R03: cancelTunnelWithError в .disconnect → double teardown (HIGH)
- PROV-R2-R04: NWPathMonitor не детектит SSID change (HIGH)
- PROV-R2-R05: Double cancelTunnelWithError в start failure paths (MEDIUM)
- PROV-R2-R06: LogFileWriter timezone не updates на runtime (MEDIUM)

**Новые:**
- PROV-R2-N01: **CRITICAL** — setTunnelNetworkSettings(nil) без timeout блокирует stopTunnel
- PROV-R2-N02: **CRITICAL** — нет watchdog на застрявшее `.reconnecting`
- PROV-R2-N03: **CRITICAL** — outboundLoop strong ref → Provider leak
- PROV-R2-N04: **HIGH** — NWPathMonitor flap storm → battery drain + timeout убийство
- PROV-R2-N05: **HIGH** — wake reconnect до того как сеть готова
- PROV-R2-N06: **HIGH** — RoutePolicyApplier zombie applies после stop
- PROV-R2-N07: **HIGH** — forceRuntimeReconnect не cancel outboundTask
- PROV-R2-N08: **HIGH** — ULA prefix `fd00:6768:6f73:7473::1/64` может конфликтовать с локальной сетью
- PROV-R2-N09: **HIGH** — JSON encode `try?` → nil → silent IpcError.badResponse
- PROV-R2-N10: **MEDIUM** — IPv6 manual CIDRs дублируются → IPv6 leak через limit
- PROV-R2-N11: recentLogFrames не очищается на disconnect (MEDIUM)
- PROV-R2-N15: Sandbox + Keychain group mismatch (MEDIUM)
- PROV-R2-N17: OSLogCategoryPool lock contention (MEDIUM)

### Security (15 находок)

- SEC-R2-N01: **HIGH** — LegacyMigration race (см. топ-1)
- SEC-R2-N02: **HIGH** — Migration sweep accepts attacker-poisoned *.json без integrity check
- SEC-R2-N03: **HIGH** — Keychain re-import supply-chain (TeamID match)
- SEC-R2-N04: **HIGH** — snapshot.json race window между atomic write и setAttributes
- SEC-R2-N05: **HIGH** — handleAppMessage всё ещё без auth (SEC-H3 не починен)
- SEC-R2-N06: **HIGH** — FFI-H5 не починен в supervise.rs (`format!("{:#}", e)` leak userinfo bytes)
- SEC-R2-N07: **MEDIUM** — Keychain.set fail-closed swallowed by ProfilesStore — UX confusion + PEM leak via user workaround
- SEC-R2-N08: Migration flag в user-writable UserDefaults (LOW)
- SEC-R2-N09: LogFileWriter timezone NTP step → file collision (LOW)
- SEC-R2-R02: SEC-M3 GHOSTSTREAM_LOG bypass не починен (INFO)
- SEC-R2-R03: CI provisioning profiles requires re-generation (LOW)
- SEC-R2-R04: PROV-C2 — split routing leaves IPv6 outside tunnel (INFO/documented)
- SEC-R2-R05: handshake timeout 15s slow loris DoS (INFO)
- SEC-R2-R06: forceRuntimeReconnect on wake — confirmed safe (no regression)

### Concurrency (14 находок)

- CONC-R2-N01: **CRITICAL** — wake/path reconnect storm без throttle
- CONC-R2-N02: **CRITICAL** — PhantomBridge.stop() блокирует actor thread 9s
- CONC-R2-N03: **CRITICAL** — stopTunnel chain до 14s превышает Apple deadline → SIGKILL
- CONC-R2-N04: **CRITICAL** — Unmanaged.passRetained double-release race (UAF window)
- CONC-R2-N05: **HIGH** — Provider fields без lock (outboundTask, activeProfile, routeSettingsTask)
- CONC-R2-N06: **HIGH** — .disconnect → cancelTunnelWithError → double teardown
- CONC-R2-N07: RoutePolicyApplier actor structurally redundant (MEDIUM)
- CONC-R2-N08: previousPathStatus cross-queue write (MEDIUM)
- CONC-R2-N09: armHandshakeTimeout Task race с completion (HIGH)
- CONC-R2-N10: **HIGH** — LegacyMigration блокирует main thread 1-3s
- CONC-R2-N11: VpnStateManager.rewireStatusObserver concurrent race (MEDIUM)
- CONC-R2-N12: OnceLock comment misleads (LOW)
- CONC-R2-N13: AsyncStream silent drops без observability (MEDIUM)
- CONC-R2-N14: OutboundDispatcher sync C call abort window (MEDIUM)

### Operations (13 находок)

- OPS-R2-01: **CRITICAL** — build scripts не пересобирают xcframework
- OPS-R2-02: **CRITICAL** — iOS bundle id mismatch
- OPS-R2-03: **CRITICAL** — LegacyMigration копирует несуществующие файлы (dead code, не сломан, но сигнал)
- OPS-R2-04: **CRITICAL** — migration runs after ProfilesStore.load (= топ-1)
- OPS-R2-05: **HIGH** — Debug provisioning profile names не verified
- OPS-R2-06: **HIGH** — .env содержит stale iOS bundle ids
- OPS-R2-07: **HIGH** — iOS stopTunnel 5s deadline (см. топ-5 macOS, ещё хуже на iOS)
- OPS-R2-08: **HIGH** — panic="abort" + `catch_unwind` = no-op (catch_unwind врёт)
- OPS-R2-09: Cross-platform check OK (MEDIUM)
- OPS-R2-10: PhantomBridge release_cb installer lazy init (MEDIUM)
- OPS-R2-11: project.yml версия не bumped (MEDIUM)
- OPS-R2-12: ship-macos.sh notarize OK (LOW info)
- OPS-R2-13: Sparkle в derived data (LOW)

## Минимальный action plan для Round 3

### Блокеры для next release (v0.25.0):
1. **Migration race (топ-1)** — переместить LegacyMigration в ProfilesStore.init() pre-load
2. **xcframework rebuild (топ-2)** — auto в build-release.sh
3. **iOS bundle id (топ-3)** — sync apps/ios/project.yml + entitlements
4. **Wake armHandshakeTimeout race (топ-4)** — arm до start
5. **Stop chain timeout (топ-5)** — reduce join timeouts to 3s total
6. **Provider leak (топ-6)** — weak self в scheduleRead

### Высокий приоритет UX:
7. ⌘K collision (топ-7)
8. CONNECT cancel mid-handshake (топ-8)
9. UI-H3 fix proper (топ-9)
10. CommandPalette overlay block (топ-10)

### Security hardening:
11. handleAppMessage sender auth (SEC-R2-N05)
12. supervise.rs anyhow Display sanitize (SEC-R2-N06)
13. snapshot.json umask race (SEC-R2-N04)

---

## Открытые вопросы

1. **Migration flag location:** если перенесём LegacyMigration в `ProfilesStore.init`, флаг должен быть в new App Group UserDefaults — но Keychain access может потребоваться раньше. Pre-load до Keychain? Pre-load после?

2. **iOS bundle id sync** — потребует Apple Developer Portal action (новый App ID `com.ghoststream.client` для iOS, новый provisioning profile, App Group registration). Юзер должен это сделать вручную.

3. **panic = "unwind"** — стоит ли менять для Apple профиля? Размер binary +200KB, но catch_unwind станет реальным.

4. **stopTunnel iOS deadline** — 3s force return. После этого Rust продолжает (orphan) — leak forwarders. Acceptable trade-off?
