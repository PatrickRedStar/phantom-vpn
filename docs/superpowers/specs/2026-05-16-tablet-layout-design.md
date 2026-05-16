# GhostStream Android — adaptive layouts for tablet + foldable

**Status:** Design approved, awaiting implementation plan
**Target release:** v0.26.0
**Author:** brainstorming session 2026-05-16

## Context

Приложение сейчас полностью оптимизировано под телефонный portrait ~360 dp width. На Samsung Tab S11 (11", ~1280 dp landscape / ~800 dp portrait) и на foldable устройствах (Z Fold unfolded ~850 dp, Z Flip cover ~340 dp height) UI выглядит как растянутая телефонная версия: bottom-nav capsule 240 dp висит маленькой плашкой по центру внизу, state headline 54sp теряется в углу, ScopeChart растягивается на всю ширину теряя читабельность, Settings — длинный 1-column scroll с растянутыми на весь экран карточками профайлов.

Цель — холистическая адаптация под три window size class (Compact / Medium / Expanded) + foldable awareness, через Material 3 Adaptive scaffolds. На phone portrait ничего не должно измениться.

## Scope

Включается:
- Phone portrait (≤ 599 dp)
- Phone landscape, tablet portrait, foldable folded (600-839 dp)
- Tablet landscape, foldable unfolded landscape, большие планшеты (≥ 840 dp)
- Z Fold/Flip half-opened (book-mode posture)

Не включается (out-of-scope, отдельные задачи):
- DeX desktop mode
- ChromeOS
- Android TV (leanback)
- Wear OS

## Approach

**Material 3 Adaptive** артефакты (выбрано пользователем после сравнения с manual `BoxWithConstraints` и canonical Material `windowsizeclass`):

- `androidx.compose.material3.adaptive:adaptive-navigation-suite` — `NavigationSuiteScaffold` автоматически выбирает `NavigationBar` (bottom) на Compact, `NavigationRail` (left, 80 dp) на Medium, `PermanentNavigationDrawer` (left, 220 dp) на Expanded.
- `androidx.compose.material3.adaptive:adaptive-layout` — `NavigableListDetailPaneScaffold` для master-detail в Settings.
- `androidx.compose.material3.adaptive:adaptive` — `currentWindowAdaptiveInfo()` источник `WindowSizeClass` и `WindowPosture` (foldable info, в т.ч. `isTabletop`, `isBookMode`).

Под капотом эти библиотеки используют Jetpack WindowManager — отдельную dependency `androidx.window` тянуть не надо.

## Window size class breakpoints

| Width | SizeClass | Navigation component | Целевые устройства |
|---|---|---|---|
| < 600 dp | Compact | NavigationBar (bottom capsule, текущий стиль) | Phone portrait, Z Flip cover |
| 600-839 dp | Medium | NavigationRail (left, 80 dp) | Phone landscape, tablet portrait, Z Fold folded |
| ≥ 840 dp | Expanded | PermanentNavigationDrawer (left, 220 dp с лейблами) | Tab S11 landscape, Z Fold unfolded landscape |

Bottom nav capsule остаётся текущим `GhostBottomNav` композаблом (наш кастомный стиль), но прокидывается в `NavigationSuiteScaffold` через `navigationSuiteItems` slot. На Medium/Expanded — Material rail/drawer, заполненные нашими же иконками (pulse / terminal / Lucide gear из v0.23.4) и lime active state.

## Per-screen adaptive layouts

### Dashboard (`apps/android/.../ui/dashboard/DashboardScreen.kt`)

**Compact (phone portrait):** 1-column scroll, identical to current. Применяется `max-content-width = 480 dp` clamp чтобы при phone landscape не растягивалось чрезмерно.

**Medium portrait (tablet portrait 800 dp):** 1-column scroll с `max-content-width = 720 dp` clamp по центру. ScopeChart и MuxBars не растягиваются на полную ширину 800 dp — остаются читаемыми.

**Medium landscape / Expanded:** **2-column hero** layout, 42% / 58% split:
- Left pane: TUNNEL STATE cap → headline (увеличенный, см. Typography) → session timer → subscription → большая CONNECT кнопка
- Right pane: ScopeChart RX/TX → MuxBars → KV details (server addr, identity, route, assigned tun_addr)

**HALF_OPENED book-mode (Z Fold):** split по vertical hinge — status на левой странице, графика и details на правой.

### Settings (`apps/android/.../ui/settings/SettingsScreen.kt`)

**Compact:** 1-column scroll, identical to current. OEM autostart/battery prompts остаются inline cards в общем потоке.

**Medium portrait:** `NavigableListDetailPaneScaffold` в overlapping mode — один pane visible за раз, tap на профайл → slide-in detail, back gesture → возврат master.

**Medium landscape / Expanded:** `NavigableListDetailPaneScaffold` в side-by-side mode:
- Master pane (240 dp): сверху список endpoints (selectable cards) + add-endpoint CTA; ниже плоский список section headers (Tunnel / System / Diagnostic) — tap header = меняет detail на соответствующий content.
- Detail pane по default: первый endpoint в списке (поля server / identity / subscription / cached_is_admin) + ниже Tunnel settings rows (DNS / split routing / per-app VPN / IPv6 killswitch / auto-reconnect). При tap на System в master — detail pane заменяется на theme / language / app icon. При tap на Diagnostic — на share-logs / version-info / clear logs.

**Expanded optional 3-pane (only when width ≥ 1100 dp):** OEM autostart + battery exemption + version info переезжают в боковую колонку справа (180 dp). На Expanded меньше 1100 dp — остаются inline в detail pane как сейчас на phone.

### Logs (`apps/android/.../ui/logs/LogsScreen.kt`)

**Compact / Medium portrait:** 1-column scroll, current behaviour. Search-box сверху, горизонтальная chip-row, LazyColumn.

**Medium landscape / Expanded:** **2-pane** layout `(240 dp filters | rest list)`:
- Left pane: search-box, вертикальные chip'ы категорий (ALL / TUNNEL / NETWORK / HANDSHAKE / STREAM / SETTINGS), level toggles (Info/Warn/Err/Dbg/Trc)
- Right pane: log list с timestamp + level + cat badge + message; больше горизонтального места для full message text без обрезки

### QR scanner (`apps/android/.../ui/components/QrScannerScreen.kt`)

**Compact:** current — camera fills screen, viewfinder 240 dp center, paste CTA full-width bottom.

**Medium / Expanded (включая Medium portrait):**
- Viewfinder size = `min(maxWidth, maxHeight) * 0.4f.coerceIn(220.dp, 480.dp)` — пропорционально, не фикс. На Medium portrait 800 dp width / 1280 dp height → 320 dp viewfinder (входит в диапазон).
- Camera preview с aspect-ratio 4:3 (или auto от CameraX), центрируется. Side letterbox area затемнена `bg.copy(alpha = 0.78f)` — фокус на viewfinder, не на растянутую картинку.
- Paste-CTA центрируется с max-width 480 dp.
- Lock-on animation (v0.24.4) — same code, размер scales автоматически потому что corners draw relative к viewfinder size.

## Typography (`apps/android/.../ui/theme/Typography.kt`)

Responsive `stateHeadline` size по WindowSizeClass:

| SizeClass | stateHeadline |
|---|---|
| Compact | 54sp (current) |
| Medium | 72sp |
| Expanded | 96sp |

Все остальные text styles остаются прежними (label/hint/labelMono и т.д. в sp — system font-scale работает независимо). `stateHeadline` — единственный visual-anchor который имеет смысл масштабировать под device width.

## Manifest changes (`apps/android/app/src/main/AndroidManifest.xml`)

- `<activity android:resizeableActivity="true">` — позволяет multi-window/split-screen на Android 12+.
- Никаких `<supports-screens>` — он deprecated с 2014; resizeableActivity достаточно.
- `<activity android:configChanges="screenSize|smallestScreenSize|screenLayout|orientation|keyboardHidden">` — обрабатываем смены сами через Compose, не пересоздаём Activity при повороте.

## Foldable support

Через `currentWindowAdaptiveInfo().windowPosture`:
- `isTabletop = true` (Z Fold лежит наполовину открытый под 90°) — фронтэнд может перенести primary controls (CONNECT кнопка) на нижнюю половину; primary content на верхнюю. Реализуется только в Dashboard на v0.26.0.
- `isBookMode = true` (Z Fold открыт под 90° в portrait) — split по vertical hinge, реализуется в Dashboard и Settings.
- В остальных state — стандартный Medium/Expanded layout.

## Out of scope (другие циклы)

- Widget адаптации под планшет — отдельная задача.
- Quick Settings TileService — feature gap, не addressed здесь.
- DeX/ChromeOS desktop optimisations — отдельный цикл если приоритет.
- Master-detail navigation depth > 1 уровня (например drill в per-app picker внутри detail pane) — оставляем full-screen dialogs.
- Полная миграция Settings rotation state на rememberSaveable (P2-1 из v0.25.0 audit) — отдельная задача, не блокирует tablet layout.

## Implementation files

| File | Изменения |
|------|-----------|
| `apps/android/app/build.gradle.kts` | Добавить 3 артефакта material3-adaptive |
| `apps/android/app/src/main/AndroidManifest.xml` | resizeableActivity + configChanges на MainActivity |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/navigation/AppNavigation.kt` | Замена HorizontalPager на NavigationSuiteScaffold; backstack для master-detail в Settings |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/components/BottomNav.kt` | GhostBottomNav стиль (capsule, scanline-active) остаётся как кастомный composable. Новые `GhostNavigationRail` и `GhostNavigationDrawer` — самописные (не Material defaults), чтобы сохранить phosphor/terminal эстетику: lime active pill, mono labels, signal-dim logo. Внутри NavigationSuiteScaffold pluggable через `layoutType = NavigationSuiteType.Custom` или собственный wrapper. |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/dashboard/DashboardScreen.kt` | BoxWithConstraints branching: 1-col / 2-col hero / book-mode split. max-content-width clamps |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/settings/SettingsScreen.kt` | NavigableListDetailPaneScaffold; разнесение endpoints (master) vs profile detail (detail); optional 3-pane на Expanded |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/logs/LogsScreen.kt` | BoxWithConstraints: 1-col vs 2-pane filters/list |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/components/QrScannerScreen.kt` | Viewfinder size via BoxWithConstraints; camera letterbox area |
| `apps/android/app/src/main/kotlin/com/ghoststream/vpn/ui/theme/Typography.kt` | stateHeadline теперь @Composable property читающий WindowSizeClass и возвращающий 54/72/96 sp |

## Reusing existing utilities

- `GhostBottomNav` (`ui/components/BottomNav.kt`) — сохранить визуально, обернуть в NavigationSuiteScaffold для Compact.
- Bottom-nav иконки (`res/drawable/ic_nav_*.xml` из v0.23.4) — те же drawables для Rail и Drawer.
- `HeaderMeta` (`ui/components/GhostChrome.kt`) — без изменений, используется и в 1-col и в 2-col layouts.
- Lock-on animation в QrScanner — без изменений, scale-free.
- `derivedVpnState` flow (`service/VpnStateManager.kt`) — без изменений, тот же state-source.

## Verification

End-to-end проверки на устройствах:

| Сценарий | Устройство | Ожидание |
|----------|-----------|----------|
| Phone portrait — ничего не изменилось | S25 Ultra | bottom-nav capsule на месте, все блоки как сейчас |
| Phone landscape | S25 Ultra | NavigationRail слева, content max-width 720 dp |
| Tablet portrait | Tab S11 portrait | NavigationRail + content centered с 720 dp clamp |
| Tablet landscape | Tab S11 landscape | PermanentDrawer + Dashboard 2-col hero |
| Settings master-detail | Tab S11 landscape | Tap profile → detail обновляется без потери master |
| Settings overlap | Tab S11 portrait | Tap profile → slide-in; back gesture → master |
| QR scanner viewfinder size | Tab S11 landscape | Viewfinder ~400 dp в центре с letterbox-bg по бокам |
| Z Fold half-opened | Z Fold (если есть) | Dashboard split по hinge, Settings book-mode |
| Multi-window split-screen | Tab S11 50/50 split | resizeableActivity работает, Compose adapts |

## Migration / rollback

- Все changes — additive в новых artifact (material3-adaptive), не ломают существующий код. Если в production обнаружится crash на старых API/devices — feature flag (BuildConfig) для отключения adaptive поведения и fallback на текущий layout не нужен: NavigationSuiteScaffold gracefully fallback'нется на NavigationBar если SizeClass detection не сработает.
- AndroidManifest изменения (resizeableActivity) — backward compatible.

## Approved sections

- ✓ Section 1 — NavigationSuiteScaffold (NavigationBar / Rail / PermanentDrawer)
- ✓ Section 2 — Dashboard adaptive (1-col / 1-col clamped / 2-col hero / book-mode split)
- ✓ Section 3 — Settings master-detail (NavigableListDetailPaneScaffold + optional 3-pane)
- ✓ Section 4 — Logs adaptive (1-col / 2-pane filters/list)
- ✓ Section 5 — QR scanner adaptive (proportional viewfinder + letterbox)
