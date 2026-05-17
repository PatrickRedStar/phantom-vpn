---
title: macOS tunnel instant-cancel из-за санитайза cert/key (Round 1 → Round 6)
date: 2026-05-17
type: incident
severity: critical (release blocker)
detection-delay: ~6 hours, 5 audit rounds
fixed-in: v0.25.0 build 22
---

# 2026-05-17 — macOS cert/key Keychain regression

## TL;DR

Round 1 audit нашёл реальный security gap (cert/key хранились в plaintext `providerConfiguration` plist под `/Library/Preferences/com.apple.networkextension*.plist`). Implementer C "починил" через `VpnProfile.sanitizedForProviderConfiguration` + ожидание, что extension возьмёт PEM из shared Keychain. **Это не работает на macOS**: system extension запускается как **root** и не имеет access к user's Data Protection Keychain, куда `ProfilesStore.save` пишет.

Результат: `Connect` → extension стартует → TUN создаётся → `Keychain.get` возвращает nil → `ConnStringBuilder.build` возвращает nil → `BridgeError.encoding` через 5ms → instant cancel. UI показывает "Disconnected" без ошибки, логи в TailView пустые (extension не успевает ничего залогировать до crash).

**5 audit→fix rounds не отловили это**, потому что adversary-агенты делали статический code review. Никто ни разу не запустил `install + Connect` smoke-test между rounds.

## Хронология

| Время | Событие |
|---|---|
| 2026-05-17 ~14:00 | Round 1 audit: 115 находок. Среди них **SEC-C2** (Keychain fallback в default keychain) и поведенческая претензия что PEM кладётся в plaintext в `providerConfiguration`. |
| ~15:00 | Round 1 fix wave: Implementer C добавляет `VpnProfile.sanitizedForProviderConfiguration` и Provider hydrate'ит cert/key из Keychain в `loadProfile`. Все 4 implementer'а build SUCCEEDED. |
| ~16:00 | Round 2 re-hunt: 104 находки. Adversary "Security" замечает SEC-R2-N07 (Keychain.set fail swallowed in ProfilesStore) — но как UX issue, не как причину сломанного tunnel. Связь не установлена. |
| ~17:30 | Round 3 fix wave: AppDelegate hook, build-xcframework auto-rebuild. iOS bundle id sync. |
| ~18:30 | Round 4 re-hunt: 30 регрессий. Никто не запустил Connect. |
| ~19:00 | Round 5 fix wave: withTimeout, ⌘⌫, theme reactivity. |
| ~21:00 | Tag macos-v0.25.0 + ship pipeline. DMG `0.25.0-21-macOS.dmg` готов. notarized + stapled. |
| ~22:20 | Пользователь устанавливает v21, нажимает Connect → **instant cancel, пустые логи**. |
| ~22:25 | Orchestrator (Claude) начинает diag: `systemextensionsctl list` → extension activated. `scutil --nc list` → manager есть, Disconnected. Logs only show RunningBoard noise. |
| ~22:35 | Find в Console logs: `startTunnel failed: PhantomKit.BridgeError error 1 (encoding)` сразу после `event=created mtu=1350 tun_addr=10.7.0.12/24`. |
| ~22:40 | Сравнение BridgeError enum: case 1 = `.encoding`. `PhantomBridge.start` throws encoding когда `connStr` nil. ConnStringBuilder возвращает nil без cert/key. |
| ~22:42 | `security find-generic-password -s com.ghoststream.client` → **empty**. Под `com.ghoststream.vpn` (legacy) — 4 stale items для других profile.id. |
| ~22:45 | Анализ: host app sandboxed + `kSecUseDataProtectionKeychain = true` → user DP keychain. Extension running as root → нет user keychain access. **Items недоступны через границу процессов** даже с правильным `kSecAttrAccessGroup`. |
| ~22:48 | Round 6 hotfix: revert sanitize, ship cert/key через `providerConfiguration` (как было до Round 1). Build 22. |
| ~22:50 | DMG `0.25.0-22-macOS.dmg` готов. notarized + stapled. |
| ~22:52 | Пользователь устанавливает v22 → "Заработало". |

## Root cause

Два composite issue:

1. **Технический:** на macOS у `NEPacketTunnelProvider` (как `system-extension`) другой security context чем у host app:
   - Host: sandboxed user process, access к user's Data Protection Keychain.
   - Extension: запускается launchd'ом как **root** через `com.apple.system-extension`. Не имеет access к user keychain даже с правильным `keychain-access-groups` entitlement.
   - Apple docs про DP keychain sharing явно не упоминают этот edge case для system extensions.

2. **Процессный:** 5 раундов adversary audit'ов не имели runtime gate. Каждый round:
   - Static code review → находит "issues"
   - Implementer пишет fix → `xcodebuild ... build` passes
   - Cherry-pick в master
   - **Никогда** не запускали `install + Connect`.

   В итоге каждый round добавлял compensation patterns (withTimeout, withStateLock, debounce, watchdog) которые сами добавляли surface для bugs, не замечая что **happy path всё ещё сломан**.

## Что должно было поймать это раньше

| Защита | Поймала бы | Почему не сработало |
|---|---|---|
| Smoke test после fix wave | ✅ за 30s после Round 1 | Не было такого скрипта |
| Explicit error в Provider если cert nil | ✅ ускорило бы диагностику | Был silent `BridgeError.encoding`, без хука в `tunnel.lastError` |
| Code review поинт-то-поинт runtime trace | возможно | Adversary prompts не требовали "запустить Connect и убедиться" |
| Test profile в repo с автоматическим Connect | ✅ | Не было |

## Меры по предотвращению (внедрены)

1. **`apps/macos/scripts/smoke-test.sh`** — автоматический Connect verify через `scutil --nc start` + polling 45s. PASS только если `.connected`. На fail дампит `log show` ghoststream subsystem за 2 минуты в `/tmp/ghoststream-smoke-fail.log`.

2. **Inline инвариант в `VpnTunnelController.swift`** перед `JSONEncoder().encode(providerProfile)` — большой комментарий что **не санитизировать** cert/key на macOS, со ссылкой на этот документ и на ADR 0009.

3. **Explicit error в `PacketTunnelProvider.loadProfile`** — если cert/key nil **после** Keychain fallback → log.error без `<private>` redaction + `throw ProviderError.decodeFailed("VPN credentials missing — re-import the ghs:// URL")`. Пользователь видит actionable error в `tunnel.lastError` вместо instant cancel.

4. **ADR 0009** (`docs/knowledge/decisions/0009-cert-pem-providerConfiguration.md`) — задокументированное решение что cert/key идут через `providerConfiguration`. Будущий audit увидит документ и не попытается "пофиксить" то же самое.

5. **Memory entry для оркестратора** (`memory/feedback_runtime_smoke_after_fix.md`) — process discipline: после каждого fix wave **обязательно** smoke-test.sh до следующего audit round.

## Меры которые НЕ внедрены (отложены)

- **CI integration** smoke-test после ship-macos.sh — требует macOS runner с signing identity. Отложено.
- **Diagnostic Export в UI** (zip с last hour logs + snapshot + sanitized entitlements) — отдельная фича, ~2 часа.
- **Host XPC bridge** для forward'а cert/key в extension on demand — правильное долгосрочное решение SEC-C2. Требует refactor IPC layer. Отложено в backlog.

## Что считаю критичным запомнить

1. **System extensions на macOS = root context.** Apple keychain sharing работает между **user processes** того же App Group. Root extension к user DP keychain доступа не имеет.
2. **Static analysis lies для cross-process Apple APIs.** Только runtime smoke-test catches это.
3. **5 rounds of static fixes — antipattern.** После 1-2 rounds без runtime verification — STOP, install + test, иначе fix waves накапливают регрессии быстрее чем починки.
4. **Trade-off acknowledged:** plaintext cert/key в `/Library/Preferences/...` доступно sudo'd процессам. Это **известный** security gap; решение принято осознанно в пользу working tunnel'а до правильного XPC bridge fix.

## Связи

- Commit с hotfix: `16fe77e fix(macos): Round 6 hotfix — ship cert/key in providerConfiguration`
- ADR: `docs/knowledge/decisions/0009-cert-pem-providerConfiguration.md`
- Round 1 audit: `docs/knowledge/audits/2026-05-17-macos-bug-hunt.md`
- Round 2 audit: `docs/knowledge/audits/2026-05-17-macos-bug-hunt-round2.md`
- Smoke test: `apps/macos/scripts/smoke-test.sh`
