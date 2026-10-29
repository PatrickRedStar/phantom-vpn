---
updated: 2026-10-29
status: accepted
---

# 0020 — iOS распространяется только через внутренний TestFlight

## Context

iOS-клиент ожил (v0.29.0, build 3) и должен дойти до друзей. Аккаунт Apple
Developer — на физлицо (UPG896A272, Petr Kurkin). Guideline 5.4 App Review
(редакция 2026-10-16): VPN-приложения «may only be offered by developers enrolled
as an organization». Под App Review попадают App Store, Unlisted, Custom Apps и
внешний TestFlight — для физлица закрыто всё. ИП Apple не принимает как
организацию, нужно ООО или иностранная компания + D-U-N-S; из РФ это недели
санкционных проверок и проблемы с оплатой. Плюс РКН в 2026 году снимает из
российского App Store именно клиентов «своих конфигов» (V2Box, Streisand, Happ).

## Decision

Только **внутренний TestFlight**: друзья добавляются пользователями App Store
Connect (роль Marketing или Developer, до 100), App Review нет. Сборка живёт 90
дней — новую выкладывает `apps/ios/scripts/ship-ios.sh`. Приложение в App Store
Connect — «GhostStream Tunnel» (`com.ghoststream.client`).

## Alternatives

- **Оформить организацию** и выйти в App Store / Unlisted без российской витрины —
  отложено: деньги, недели, исход проверок не гарантирован, а в РФ приложение
  всё равно сняли бы.
- **Ad Hoc по UDID** (100 iPhone в год, без TestFlight) — запасной вариант, если
  внутренний TestFlight начнут ограничивать.

## Проверка модерацией (2026-10-29)

Попытки выйти за пределы внутреннего TestFlight закончились одинаково —
**4.3(a) Spam** («similar binary, metadata, and/or concept as apps … by other
developers»):
- App Store, запись «GhostStream» (`com.ghoststream.vpn`), май 2026 —
  отказ, апелляция в App Review Board отклонена 2026-06-03;
- внешний TestFlight, «GhostStream Tunnel», сборка 1 (2026-05-19) и сборка 10
  (2026-10-28, заметки «клиент к своему серверу, open source, не xray») —
  отказ; во втором письме предупреждение: повторные подачи → extended review,
  аккаунт могут исключить из Apple Developer Program.

Правило 5.4 (организация) при этом не всплывало — упираемся в «концепт»
(клиент обхода блокировок с импортом конфигов), а не в тип аккаунта, так что
организация не помогла бы. **Больше на App Review не подаём**: потеря аккаунта
убьёт и внутренний TestFlight. `ship-ios.sh` оставляет
`testFlightInternalTestingOnly = true`, чтобы сборку нельзя было отправить
внешним тестировщикам по ошибке. Предел раздачи — 100 человек (внутренний
TestFlight или Ad Hoc по UDID).

## Consequences

- Нет публичной ссылки: каждого человека заводит владелец в App Store Connect.
- Раз в ≤90 дней нужна новая сборка, иначе приложение у друзей перестанет запускаться.
- Метаданные App Store, скриншоты, экран раскрытия данных по 5.4 и privacy
  policy пока не нужны; понадобятся, если вернёмся к организации.
- `ITSAppUsesNonExemptEncryption = NO` годится для внутреннего тестирования;
  перед любым внешним распространением пересмотреть (свой TLS 1.3 в VPN —
  стандартное, но не «OS-provided» шифрование).
