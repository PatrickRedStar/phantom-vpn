---
updated: 2026-10-27
status: accepted
---

# 0013 — Админка и relay на macOS: паритет с Android через PhantomKit

## Context

Android-клиент давно умеет две вещи, которых на macOS не было:

1. **Админка** — управление клиентами сервера через mTLS HTTP API
   (`https://<tun-gateway>:8080`, доступен только сквозь туннель): список
   клиентов, создание/удаление, вкл/выкл, admin-флаг, подписки, выдача
   `ghs://`, статистика и лог направлений. См. [admin-api](../architecture/admin-api.md).
2. **Relay** — дополнительный хоп между клиентом и exit-сервером
   (SNI-passthrough, шифрование end-to-end). У Android это два поля профиля
   (`relayEnabled` + `relayAddr`); клиент просто подключается к relay-адресу
   вместо серверного.

iOS-таргет уже содержал рабочую реализацию админки (`AdminHttpClient` с
mTLS + TOFU-пиннингом, `AdminViewModel`), но она жила в самом iOS-приложении,
а не в общем пакете — macOS не мог её переиспользовать.

## Decision

### Админка — общий код в PhantomKit

`AdminHttpClient` (+ DTO: `AdminStatus`, `AdminClient`, `AdminSelfInfo`,
`ClientStat`, `ClientLog`) и `AdminViewModel` вынесены в
`PhantomKit/Sources/PhantomKit/Admin/`. iOS-таргет переключён на общий код;
macOS получает его бесплатно. В iOS-таргете остался только
`ProfileEntitlementRefresher` — он зависит от iOS-специфичных
`VpnStateManager` / `VpnTunnelController` / `AppStrings`.

Хелпер `AdminGateway.adminBaseURL(for:)` (раньше жил внутри iOS-only
`ProfileEntitlementRefresher`) переехал в общий `AdminGateway`, чтобы
`AdminViewModel` в пакете от него не зависел.

**Подписка и `enabled` берутся из `/api/me`** (с 2026-10): сервер отдаёт там
`expires_at` и `enabled` для своего серта, так что срок видят и не-админы.
Прежний путь — найти себя в админском `/api/clients` по tun-IP
(`AdminGateway.sameTunIP`) — удалён: не-админ получал 403 и срока не видел.
Флаг админа и подписка сохраняются в кэш профиля до запросов админки; старый
сервер без этих полей кэш не трогает.

**macOS UI**: новая вкладка `ADMIN` (⌘5) в главной консоли — desktop-раскладка
(Table клиентов + панель деталей справа со спарклайном трафика, последними
направлениями и действиями по подписке), шит «Новый клиент». Вкладка
**identity-gated**: рендерится только когда `activeProfile.cachedIsAdmin == true`.
Флаг (и подписка) подтягивается через `/api/me` фоновым `EntitlementRefresher` (macOS-twin
iOS-рефрешера) — своя каденция, потому что на десктопе нет per-view refresh,
на который можно опереться (меню-бар-попап может не открываться).

**Ed25519 на Apple**: `URLSession + SecIdentity` не принимают Ed25519
клиентские сертификаты — админ-серт должен быть ECDSA P-256
(`phantom-keygen --key-type ecdsa`). Сам туннель работает с Ed25519 (rustls +
ring в `client-apple`), ограничение только у URLSession-админки. Ошибка ведёт
к `mtlsUnavailable`-баннеру, а не к падению.

### Relay — два поля профиля, подмена адреса host-side

`VpnProfile` получил `relayEnabled: Bool?` + `relayAddr: String?`
(`decodeIfPresent`, старые профили декодятся без миграции). Вычисляемое
`effectiveServerAddr` возвращает relay-адрес, когда relay включён и адрес
непустой, иначе серверный.

Подмена происходит **на стороне host-приложения** в
`VpnTunnelController.installOnly`, до сериализации в `providerConfiguration`:

```swift
providerProfile.serverAddr = profile.effectiveServerAddr
```

После этого весь downstream (route-policy snapshot с exclude сервера /32,
`proto.serverAddress`, extension'овский `ConnStringBuilder`) видит уже
фактическую точку входа. **Extension и Rust-рантайм не меняются** — для них
relay это просто другой `serverAddr`.

**iOS** (2026-10): там в `providerConfiguration` едет только `profileId`,
extension читает профиль из App Group сам, поэтому подмена — в extension:
`VpnProfile.withRelayEndpoint` (PhantomKit) меняет `serverAddr` и authority
`ghs://` на relay, SNI не трогает.

**SNI (`serverName`) НЕ подменяется** — relay форвардит сырой TLS по SNI
(passthrough), сквозное шифрование терминируется на exit-сервере. ClientHello
обязан нести имя exit'а, иначе relay не найдёт upstream.

**Без гео-привязки**: технология relay — это просто +1 хоп. В UI никаких
«РФ»/страновых формулировок: тумблер «Relay», описание «дополнительный хоп
перед exit-сервером».

## Consequences

- macOS достиг паритета с Android по админке и relay без дублирования логики
  админ-клиента (один `AdminHttpClient` на iOS+macOS).
- Relay-подмена — минимальный диатез: одна строка перед существующим путём
  сериализации, cert/key-инвариант ([ADR 0009](./0009-cert-pem-providerConfiguration.md))
  не затронут (подмена не касается PEM/Keychain/FFI-конфига).
- `providerConfiguration` теперь несёт relay-поля профиля, но подмена уже
  случилась host-side — extension получает готовый `serverAddr`, relay-поля
  для него информационные.
- RTT-зонд в СПИСКЕ и endpoint в меню-баре/дашборде показывают фактическую
  точку входа (`effectiveServerAddr`); при relay — бейдж `RELAY`.

## Alternatives rejected

- **Relay-параметр в ghs://**: отвергнут (паритет с Android) — relay это
  настройка развёртывания, а не идентичность профиля; conn-string остаётся
  переносимым между «прямо» и «через relay».
- **Оставить админ-код в приложениях (дублировать на macOS)**: два
  расходящихся `AdminHttpClient` = двойные баги в mTLS/PKCS8-разборе.
