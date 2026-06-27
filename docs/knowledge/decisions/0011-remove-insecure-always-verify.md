---
updated: 2026-06-27
status: accepted
---

# 0011 — Удаление `insecure` TLS: всегда проверяем серверный серт (webpki), без пиннинга

## Context

В клиенте существовал флаг `insecure` (он же `skip_verify`), который через
`SkipVerification` (rustls `ServerCertVerifier`) **полностью** отключал проверку
серверного сертификата — и цепочку, и подпись, и hostname. Он был
реинтродьюсен в работе W12 (метки `v0.27.0`) вопреки уже зафиксированному
[ADR 0004](0004-ghs-url-conn-string.md) («`insecure` не нужен, всегда
валидируем») и глоссарию (`conn_string` не несёт `insecure`).

Проблемы:

1. **MITM-вектор.** При `insecure=true` любой, кто перехватит TCP (а на прямом
   иностранном IP под ТСПУ это реальный сценарий), может выдать себя за сервер.
   mTLS этого **не** закрывает: mTLS аутентифицирует **клиента перед сервером**,
   а не наоборот. Комментарии в коде/UI («mTLS всё равно аутентифицирует
   identity», «skip hostname check») вводили в заблуждение.
2. **UI врал** (нарушение honest-state, [ADR 0009](0009-android-honest-state-and-resilience.md)):
   тоггл назывался «не проверять сертификат / skip hostname», тогда как
   выключалась вся серверная верификация.
3. `openwrt` клиент хардкодил `skip_verify = true` с тем же ошибочным
   обоснованием.

При расследовании (2026-06-27) выяснилось решающее: **серверы отдают настоящий
Let's Encrypt сертификат** (подтверждено на `vps_poland`: leaf CN=
`poland.bikini-bottom.com`, issuer `Let's Encrypt`). Приватная `PhantomVPN CA`
из `phantom_keygen` подписывает **только клиентские** серты (mTLS), не серверный.
Поэтому профили с `insecure=false` и так подключались — стандартная webpki-
проверка проходила. `insecure` был нужен лишь для одного кейса: подмена SNI на
чужой домен (DPI-маскировка), когда hostname-проверка падала.

## Decision

**Полностью убрать `insecure`/`skip_verify`. Серверный серт проверять ВСЕГДА**
через webpki public root store против `server_name`. mTLS-identity клиента
сохраняется.

- `phantom_core::h2_transport::make_h2_client_tls` лишился параметра
  `skip_server_verify`. Всегда `with_root_certificates(build_root_store(server_ca))`.
- `SkipVerification` удалён из `phantom_core::tls`.
- `ClientNetworkConfig.insecure` удалён; `parse_conn_string` игнорирует
  `insecure` как unknown-param (старые `ghs://...&insecure=1` ссылки парсятся,
  флаг просто отбрасывается — backward-compat, есть тест).
- Kotlin: тоггл «Insecure TLS / skip server cert check» убран сквозно
  (UI, VpnProfile, ConnStringParser, сервис, PreferencesStore).
- `openwrt` клиент перестал хардкодить `skip_verify`.

### Почему НЕ SHA-256 / SPKI пиннинг (хотя рассматривался)

Пиннинг серверного leaf-серта **ломался бы при каждой ротации Let's Encrypt**
(~60–90 дней) → периодические обрывы у всех пользователей. SPKI-pin переживает
ротацию только если ключ переиспользуется (LE по умолчанию — нет). Поскольку
сервер уже отдаёт публично-доверенный LE-серт, webpki + hostname-проверка —
строже (нельзя подсунуть валидный серт чужого домена) и без эксплуатационной
хрупкости. TOFU-пиннинг остаётся **только** для admin HTTP API
(`AdminHttpClient`, `cachedAdminServerCertFp`) — там серт самоподписан и
долгоживущий.

### Self-signed деплои

Если конкретный деплой ставит самоподписанный серверный серт (не LE), клиент
должен получить CA через `ca_cert_pem` в профиле (`load_server_ca` это уже
поддерживает) — серт добавится в root store. Прод (NL/poland) на LE, поэтому
`server_ca=None` и достаточно webpki.

### SNI-маскировка (DPI evasion) — отложено

Возможность слать ClientHello с «безобидным» SNI, отличным от реального имени
серта, была единственным легитимным применением `insecure`. Безопасная замена —
**развязать wire-SNI и имя для проверки**: слать произвольный SNI, но
валидировать серт против реального `server_name` (кастомный verifier поверх
webpki, hostname НЕ берётся из wire-SNI). Это отдельная задача в составе работ
по сети «только :443» / университет — НЕ через отключение проверки.

## Consequences

**Плюсы:** закрыт MITM-вектор; honest-state восстановлен; openwrt стал
безопасным; меньше поверхность конфигурации; соответствие ADR 0004 + глоссарию.

**Минусы / риски:** деплои с самоподписанным серверным сертом без `ca_cert_pem`
в профиле перестанут подключаться (нужно добавить CA или перейти на LE) —
для текущего прода неактуально (LE везде). Текущие профили (`s25`, `spongebob`)
уже `insecure=false` → поведение для них не меняется (это ровно тот путь, что
уже работал).

## References

- `phantom_core::h2_transport::make_h2_client_tls`, `phantom_core::tls`
- `client-core-runtime::supervise::drive_tunnel`
- `client_common::helpers::parse_conn_string` (+ тест `legacy_insecure_param_is_ignored`)
- Связан: [ADR 0004](0004-ghs-url-conn-string.md) (conn_string, исходное «insecure не нужен»),
  [ADR 0009 honest-state](0009-android-honest-state-and-resilience.md),
  [ADR 0002 noise→mTLS](0002-noise-to-mtls.md).
- Расследование: workflow `ghoststream-android-deep-investigation` (2026-06-27).
