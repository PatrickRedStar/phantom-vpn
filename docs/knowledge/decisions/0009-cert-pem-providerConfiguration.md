---
title: macOS — cert/key передаются через NEManager.providerConfiguration (НЕ через Keychain)
date: 2026-05-17
status: accepted
supersedes: SEC-C2 (sanitization) из audit 2026-05-17-macos-bug-hunt.md
related-incident: docs/knowledge/incidents/2026-05-17-cert-pem-keychain-regression.md
---

# ADR-0009: macOS — cert/key через providerConfiguration

## Контекст

Round 1 audit 2026-05-17 нашёл что host пишет PEM (cert + key) в `NETunnelProviderProtocol.providerConfiguration["profile"]`, который Apple persists в **plaintext** под `/Library/Preferences/com.apple.networkextension*.plist` (root-owned, доступно sudo).

Implementer C сделал "fix" SEC-C2:
- `VpnProfile.sanitizedForProviderConfiguration` убирает certPem/keyPem/connString.
- `ProfilesStore.save` пишет cert/key в shared Keychain под service `com.ghoststream.client` + access group `UPG896A272.group.com.ghoststream.client`.
- `PacketTunnelProvider.loadProfile` hydrate'ит cert/key из Keychain через `Keychain.get`.

## Что пошло не так

На macOS у `NEPacketTunnelProvider` declared as `system-extension`:
- Host (`com.ghoststream.client`) — **sandboxed user process** под текущим userID.
- Extension (`com.ghoststream.client.tunnel`) — запускается **launchd под root** через `com.apple.system-extension`.

Host пишет в **user's Data Protection Keychain** (через `kSecUseDataProtectionKeychain = true` в `Keychain.swift:applyPlatformOptions`). Это user keychain.

Extension под root — **не имеет access к user keychain**. Apple keychain sharing через `kSecAttrAccessGroup` работает между user processes того же App Group. Root extension даже с правильным `keychain-access-groups` entitlement в provisioning profile **не видит user-scoped items**.

Результат: `Keychain.get` в extension возвращает nil → `ConnStringBuilder.build` возвращает nil → `PhantomBridge.BridgeError.encoding` → instant tunnel cancel через ~5ms.

5 раундов audit→fix не отловили — bug surface'ит только at runtime, static analysis всё показывало OK.

## Решение

Cert/key **передаются через `providerConfiguration`** на macOS. `VpnProfile.sanitizedForProviderConfiguration` **не используется** в `VpnTunnelController.installOnly`. Host encode'ит полный `VpnProfile` через `JSONEncoder().encode(providerProfile)` (БЕЗ sanitize).

Provider читает profile из `providerConfiguration["profile"]` напрямую — никаких `Keychain.get` calls в happy path. Keychain hydration **остаётся как fallback** для legacy profiles (где `profileId` в `providerConfiguration` без cert) — это не нарушает behaviour, только не используется в обычном flow.

## Trade-off

| Аспект | До (sanitized) | После (full provider config) |
|---|---|---|
| Tunnel works | ❌ instant cancel | ✅ works |
| PEM в `/Library/Preferences/com.apple.networkextension*.plist` | ❌ нет | ⚠️ да, plaintext |
| Кто читает PEM на disk | — | sudo-privileged processes |
| Логи без redaction | — | риск утечки в diagnostic reports |

Trade-off **осознанный**. Working tunnel важнее theoretical privacy gap которая закрывается только полноценной XPC bridge от host к extension (см. "Долгосрочное решение").

## Альтернативы рассмотрены

1. **Shared Keychain через root → user impersonation.** Extension вызывает `SecKeychainSetUserInteractionAllowed(false)` + специальные API. Нестабильно, Apple docs молчат. Отказ.

2. **System Keychain (`kSecUseSystemKeychain`).** Требует write access от root host (а host под user). Не подходит для двунаправленного sharing.

3. **`com.apple.security.application-groups` файл вместо Keychain.** Cert/key в `~/Library/Group Containers/group.com.ghoststream.client/secrets.json`. Sandbox разрешает чтение из обоих процессов. Но **файл shared in plaintext** — тот же risk что и `providerConfiguration` + ещё одна копия данных. Без выгод. Отказ.

4. **Host XPC bridge: extension вызывает host через XPC за каждым `phantom_runtime_start`.** Host достаёт cert/key из своего DP keychain, передаёт через `NSXPCConnection` в extension. Cert/key никогда не на disk plaintext.
   - **Pro:** правильное решение.
   - **Con:** требует XPC service внутри host, IPC protocol, lifecycle management (что если host не запущен когда extension стартует). Большой рефактор, 1-2 дня работы.
   - **Решение:** **долгосрочное TODO** в backlog. См. "Долгосрочное решение".

## Долгосрочное решение

Host XPC bridge:
1. Host регистрирует `NSXPCListener` через `NEMachServiceName` (уже есть `group.com.ghoststream.client`).
2. Extension при `startTunnel`: `NSXPCConnection(machServiceName: "group.com.ghoststream.client", options: [])`.
3. Запрос `fetchProfilePem(profileId:)` → host достаёт cert/key из DP keychain → возвращает.
4. Если host не запущен — extension записывает explicit error "Open GhostStream.app first" в `tunnel.lastError`.

Pre-requisite: launchd plist для host если хотим extension без host (после reboot). Решает несколько других issues (status sync, log delivery, etc).

## Invariants для будущих agents

1. **НЕ санитизировать cert/key из `providerConfiguration` на macOS** без замены на работающий shared secret transport (XPC bridge или эквивалент).
2. **Если меняешь это место** — обязательно прогон `apps/macos/scripts/smoke-test.sh` после изменения. Static check недостаточно.
3. **iOS отличается:** на iOS extension running in **same sandbox as host** (другой security model). Shared keychain через DP keychain — работает. ADR 0009 specific к macOS.

## Code references

- Host: `apps/macos/GhostStream/Service/VpnTunnelController.swift` (поиск INVARIANT)
- Extension: `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:loadProfile` (поиск INVARIANT)
- Keychain shared util: `apps/ios/Packages/PhantomKit/Sources/PhantomKit/Storage/Keychain.swift`
- Smoke test: `apps/macos/scripts/smoke-test.sh`

## Status

**Accepted** 2026-05-17. Tunnel v0.25.0/22 проверен пользователем на real device.
