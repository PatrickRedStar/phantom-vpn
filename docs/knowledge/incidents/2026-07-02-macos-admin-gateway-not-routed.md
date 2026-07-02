---
date: 2026-07-02
platform: macOS
severity: medium
status: resolved
---

# macOS: админ-панель не появлялась — admin-gateway не маршрутизировался через туннель

## Симптом

После добавления вкладки ADMIN (build 34, [ADR 0013](../decisions/0013-macos-admin-relay-parity.md))
вкладка не появлялась даже для профиля, который на сервере помечен `is_admin`
(`macbook`, серт ECDSA P-256 — валиден для Apple URLSession). Туннель поднят,
обычный трафик идёт, exit IP правильный.

## Диагностика (по шагам, что сбивало с толку)

1. Проверил клиент: build 34 реально установлен и запущен (0.26.0/34),
   `cachedIsAdmin = None` у активного профиля → гейт вкладки `== true` ложен.
2. Проверил серт: ECDSA P-256 (не Ed25519) — версия «URLSession не принимает
   Ed25519» отпадает.
3. Проверил сервер: admin-listener жив (`10.7.0.1:8080`, curl **внутри
   контейнера** → HTTP 401), `[admin]` в конфиге есть, keyring: `macbook [admin]`.
4. **Ложный след:** `ping 10.7.0.1` с клиента **успешен** (10 ms) — казалось,
   gateway достижим. Но `curl --cert .../api/me` → таймаут (HTTP 000).
5. **Решающий факт:** `tcpdump -i tun1` НА СЕРВЕРЕ во время ping+curl не увидел
   НИ ОДНОГО пакета. Значит ping уходил **не в туннель**. Подтвердил:
   `route -n get 10.7.0.1` на клиенте → `interface: en0`, а не utun. Ответы на
   ping приходили из LAN/en0, а не от VPN-сервера.

## Root cause

macOS tun-интерфейс сконфигурирован **point-to-point с peer = собственным
адресом** (`inet 10.7.0.5 --> 10.7.0.5`). Из-за этого on-link маршрут для
tun-подсети (`10.7.0.0/24`) НЕ создаётся — единственный «прямой» хост это ты сам.
Достижимость любого другого адреса подсети (в т.ч. gateway `10.7.0.1`, где висит
admin-API) зависит ТОЛЬКО от `includedRoutes`:

- **global**: `includedRoutes = default (0.0.0.0/0)` → `10.7.0.1` накрыт → работало бы.
- **split / layeredAuto** (активный режим — сосуществование с Cisco): `includedRoutes`
  несёт лишь вычисленные ПУБЛИЧНЫЕ блоки. Приватный `10.7.0.0/24` туда не входит →
  `10.7.0.1` уходит в физический интерфейс → admin-API недостижим → `/api/me`
  таймаутит → `cachedIsAdmin` не проставляется → вкладки нет.

iOS этого не имел, потому что iOS-провайдер УЖЕ явно добавлял admin-gateway `/32`
в `includedRoutes` (и исключал его из server-direct excluded). macOS-провайдер
этот шаг не портировал — латентный дефект, всплывший только когда появилась
фича, которой нужен admin-API.

## Fix

Порт iOS-паттерна в `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift`:
`configureIPv4Routes` во ВСЕХ режимах добавляет `route(forIPv4Host: adminGateway)`
(`10.7.0.1/32`) в `includedRoutes`; `physicalServerExcludedRoutes(preservingHost:)`
не исключает gateway, даже если его накрывает серверный direct-CIDR. Добавлены
хелперы `route(forIPv4Host:)`, `cidrContainsIPv4Host`, `ipv4Range`, `ipv4Integer`.
Live-обновление (`updateRoutePolicy → makeNetworkSettings`) проходит тот же путь.

## Вторая причина (build 36): mTLS-identity через login-связку

После фикса маршрутизации (build 35) `route get 10.7.0.1 → utun6` и `curl --cert
.../api/me → 200` (проверено tcpdump'ом на сервере) — но вкладка ВСЁ РАВНО не
появилась, `cachedIsAdmin` оставался `None`. Всплыл keychain-запрос «GhostStream
хочет создать подпись, используя ключ **Apple Development: …**».

Root cause #2: `AdminHttpClient.buildIdentityViaKeychain` не указывал
`kSecUseDataProtectionKeychain`. На macOS (в отличие от iOS) это направляет
`SecItemAdd`/`SecItemCopyMatching` в файловую **login-связку**, где:
- использование приватного ключа для TLS-подписи гейтится ACL-запросом на КАЖДЫЙ
  connect (на iOS такого нет);
- запрос identity по `kSecAttrLabel` ненадёжен и вернул ЧУЖОЙ identity из
  login-связки («Apple Development») → mTLS шёл не тем ключом → сервер отвергал.

Fix #2: форс `kSecUseDataProtectionKeychain = true` во всех keychain-операциях
identity (app-scoped, без ACL-запроса, точный label-матч — паритет с iOS) +
`connectionProxyDictionary = [:]` на админ-URLSession (см. ниже). После build 36
`cachedIsAdmin=True`/`fp=True` проставляется через ~10 c после connect, вкладка
появляется без единого запроса пароля.

## Ложные следы (что дважды сбивало)

1. **`ping 10.7.0.1` «успешен»** на point-to-point tun — ICMP-ответ приходил из
   LAN по default-маршруту (en0), а не от VPN-сервера (tcpdump на tun1 пуст).
2. **`curl` из шелла шёл через `HTTPS_PROXY=127.0.0.1:10809`** (локальный прокси
   в окружении терминала) — HTTP 000 был от прокси, а не от туннеля. Проверять
   admin-API надо `curl --noproxy '*'`.

## Урок

- **`ping` через VPN обманчив на point-to-point tun** — ICMP-ответ может прийти
  из LAN по default-маршруту. Проверять достижимость нужно `route -n get <ip>`
  (какой интерфейс) + tcpdump на сервере, а не ping.
- **Шелл-прокси искажает `curl`-диагностику** приватных tun-IP — всегда
  `--noproxy '*'` при проверке туннельных сервисов.
- **Паритет платформ не бесплатен**: iOS-провайдер и iOS-keychain-путь накопили
  правки (admin-gateway route, DP keychain по умолчанию), которых нет в
  macOS-двойнике. При портировании фичи с админ-API сверять и
  `configureIPv4Routes`, и keychain-флаги обеих платформ.
- **URLSession к приватному tun-IP** должен явно отключать прокси
  (`connectionProxyDictionary = [:]`) — иначе системный/пользовательский прокси
  уводит запрос мимо туннеля.
