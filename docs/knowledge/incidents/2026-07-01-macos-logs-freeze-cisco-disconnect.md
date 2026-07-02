---
updated: 2026-07-02
status: resolved (v0.25.1 build 25)
---

# 2026-07-01 — macOS: зависание вкладки логов + instant-disconnect на Cisco-пресете

## Симптомы

1. После долгой работы на вкладке логов приложение «висло», казалось что пропадает интернет.
2. Split routing на пресете «Cisco/work VPN first» (layeredAuto): туннель подключался и сразу сбрасывался.
3. (Найдено попутно) Анимация открытия menubar-попапа зациклилась — «шторка» бесконечно выезжала/заезжала.

## Root cause (несколько независимых, усиливавших друг друга)

### Логи

- **Самоподпитка**: провайдер эмитил DBG `ipc request/response` на каждый IPC — включая сам лог-полл (1.5 с) и getStatus. Каждый полл рождал ≥2 новых фрейма → буфер UI рос даже в полном простое, за длинный день до cap 50k.
- **Замерзание на cap**: trim держал `logs.count` ровно 50 000 → `onChange(of: count)` (TailView) переставал срабатывать → tail замерзал навсегда.
- **Всё на main thread**: фильтр 50k строк со строковыми операциями на каждый фрейм — каждые 1.5 с.
- **`LogFrame.id` не уникален** (без fields) — дубли ломали diff ForEach.
- **µs/мс курсор**: `subscribeLogs(sinceMs)` со строгим `>` терял фреймы той же миллисекунды.
- **event=connected каждую секунду**: провайдер эмитил INF-событие на каждый connected-фрейм рантайма (1/с), а не на переход (+3600 фреймов/час).

### «Интернет пропадает»

- Inbound-пакеты доставлялись через актор `PhantomBridge` (Task-per-packet), где конкурировали с лог/статус-колбэками; `writeSnapshot` (sync file I/O + `defaults.synchronize()`) выполнялся на акторе на каждый StatusFrame (StatusBroadcastGate был только на iOS). Под лог-нагрузкой data-path голодал.

### Cisco / layeredAuto

Замер на живой машине: Cisco utun держал 597 CIDR динамического split-include (AWS /32 добавляются на лету).

- **Нет лимита IPv4** (у IPv6 cap 256): комплемент 597 CIDR = **4713 includedRoutes** в `setTunnelNetworkSettings` — уже на старте (installOnly запекал свежий снапшот).
- **16 КиБ FFI-обрыв**: `MAX_FFI_CSTR_LEN` — при большем входе `phantom_compute_vpn_routes` возвращал NULL, Swift молча отдавал `[]` → туннель без маршрутов.
- **Дребезг routeHash**: каждый новый /32 менял hash → `updateRoutePolicy` каждые 5 с → NE reasserting → рвались все соединения.
- **Гонка при старте**: policy применялась уже в `.connecting` параллельно стартовому apply (`RoutePolicyApplier` — пустой реентерабельный актор, ничего не сериализовал).
- **Вечное зависание монитора**: ветки cancel/nil-self в `.updateRoutePolicy` не вызывали completionHandler; `TunnelIpcBridge.send` был без таймаута.

### Шторка попапа

`PulseDot` запускал пульс через `withAnimation(.repeatForever)` в `onAppear` — транзакция накрывала раскладку окна MenuBarExtra при первом рендере, и анимация окна наследовала repeatForever. Рецидив класса «phantom popover» (Wave 5, 763edb68); виден только в connected/connecting — то есть проявился ИМЕННО после починки Cisco-коннекта.

## Fixes (v0.25.1, коммиты 74b01b1 → HEAD)

Batch A (логи), B (routing: `RoutePolicySnapshot.aggregatedUpstreamCidrs` /24→/20→/16 cap 192 + гистерезис + apply только в .connected + FFI-лимит 256 КиБ + таймаут IPC), C (data-path: inbound напрямую с Rust-потока, submitInbound nonisolated, StatusBroadcastGate + serial snapshot-очередь на macOS, teardown ≤4.5 с), D (HostLogMirror, dock-claims, guard двойного connect, MIG-whitelist и пр.), PulseDot scoped-анимация + тест-инвариант `MenuBarAnimationInvariantTests`.

## Инфраструктурные грабли (важно для будущих релизов)

- **Версия бандла была захардкожена** в Info.plist/project.yml `info.properties` — бамп только `CURRENT_PROJECT_VERSION` ничего не менял, sysextd отвечал `alreadyActive`. Теперь версии тянутся из `$(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION)`.
- **Ненотаризованный system extension не активируется**: sysextd вечно висит в `waiting for external validation`. Debug-сборкой обновить extension НЕЛЬЗЯ — только нотаризованной (ship-macos.sh). Блокировавший нотаризацию Apple PLA подписан 2026-07-02.
- Debug-профили `ghoststream`/`ghoststream-2` — Developer ID (cert 15C9F8C7…, до 2044); с базовым «Apple Development» они несовместимы → в Debug-конфиге стоит `CODE_SIGN_IDENTITY: Developer ID Application`.
- **`log` в zsh юзера перекрыт алиасом** — unified log «молчал»; использовать `/usr/bin/log`.
- **smoke-test.sh давал ложный FAIL**: pipefail + `head -1` → SIGPIPE у scutil → `|| echo Unknown` дописывал строку к статусу.
- Extension пишет в group-контейнер **root'а** (`/var/root/...`) — sandbox не пускает его в контейнер пользователя. snapshot.json канал маскируется IPC; runtime.log для пользователя даёт host-side `HostLogMirror`.

## Верификация

- PhantomKit: 57 тестов зелёные (в т.ч. 6 на агрегацию, 1 инвариант анимаций).
- `cargo check`/`cargo test routing` зелёные.
- smoke-test.sh: **PASS, Connected за 3 с** (build 24/25, профиль poland), 10/10 стримов.

## Post-scriptum (2026-07-02, build 29)

Первый живой прогон layeredAuto с настоящим Cisco показал, что агрегация
маршрутов из Batch B — сама по себе баг: супернеты /16 вокруг корп-/32
вырезали из GhostStream публичные CDN-диапазоны, и этот трафик уходил
голым через en0 (мимо обоих VPN) под ТСПУ. Вычитание заменено на
longest-prefix-модель — см. [ADR 0012](../decisions/0012-layered-routing-longest-prefix.md);
`aggregatedUpstreamCidrs` удалена, `detectedUpstreamCidrs` исключены из
`routeHash`. Верифицировано на живых двух VPN (speedtest/ytimg 200 через
GhostStream, корп-хост через Cisco, 93 маршрута вместо 732).
