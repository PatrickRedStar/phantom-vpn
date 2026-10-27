---
updated: 2026-10-27
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

## Consequences

- Нет публичной ссылки: каждого человека заводит владелец в App Store Connect.
- Раз в ≤90 дней нужна новая сборка, иначе приложение у друзей перестанет запускаться.
- Метаданные App Store, скриншоты, экран раскрытия данных по 5.4 и privacy
  policy пока не нужны; понадобятся, если вернёмся к организации.
- `ITSAppUsesNonExemptEncryption = NO` годится для внутреннего тестирования;
  перед любым внешним распространением пересмотреть (свой TLS 1.3 в VPN —
  стандартное, но не «OS-provided» шифрование).
