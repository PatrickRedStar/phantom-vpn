---
title: Android `InvalidTrailingPadding` при импорте ghs:// — copy-paste mangling
date: 2026-06-05
status: resolved
severity: high
affected: Android v0.26.7 (Google Play) + любая версия с long ghs:// (>1 KB)
related-adr: ../decisions/0010-docker-deploy.md
---

# Incident: Android рвал `ghs://` при копировании из терминала

## Симптом

После развёртывания phantom-server v0.26.x на vps_poland (docker, self-signed CA от
phantom-keygen) попытка connect с Android клиента v0.26.7 систематически падает
с этой ошибкой в logcat:

```
{"level":"ERR","msg":"error","category":"tunnel",
 "fields":{"error":"tls identity: Failed to parse inline client TLS certificate: InvalidTrailingPadding",
          "phase":"tls_identity"}}
```

Tunnel поднимался (`nativeStart: tunnel started OK`), но через миллисекунду
схлопывался (`status watcher: channel closed`) ещё до открытия TCP-сокета.
Сервер connection вообще не видел.

## Где появился `InvalidTrailingPadding`

Не в `rustls-pemfile`. Это `rustls-pki-types` v1.14.0 `base64.rs:143` — base64
decoder отказывается принимать payload, длина которого `% 4 == 1` или содержит
лишние `=` после base64-данных. Поверхностный путь:
`parse_pem_identity` → `rustls_pemfile::certs` → `rustls-pki-types base64` →
ошибка.

## Root cause

Длинный `ghs://` (1.2 KB — embedded cert+key как base64url userinfo) при
копировании из терминала / мессенджера получает **embedded whitespace**:

- Терминал переносит длинную строку (даже `print(url)` без явных переносов
  попадает на wrap'ивающие emulators при копировании прямоугольного выделения)
- Telegram/любой IM может вставить zero-width chars при url unfurling
- Clipboard managers на некоторых Android (MIUI, Samsung) sanitise long base64
  блоки

Android `Base64.decode(URL_SAFE | NO_WRAP)` **молча игнорирует whitespace**
(`URL_SAFE` ⇒ принимает оба алфавита `+/` и `-_` и пропускает `\n\r\t `). Decode
не падает, но **байты сдвигаются** относительно оригинала: внешние PEM-маркеры
`-----BEGIN CERTIFICATE-----` остаются на месте, Kotlin `ConnStringParser.parse`
успешно их находит и сплитит, выходит "валидный" cert PEM blob — но **внутренний**
base64 body сертификата сдвинут на 1-3 байта.

Когда Rust `parse_pem_identity` → `rustls_pemfile::certs` парсит base64 body
этого "вроде бы PEM" — `len % 4 == 1` → `InvalidTrailingPadding`.

## Что НЕ было причиной

Эти варианты были отброшены тремя параллельными агентами-инспекторами
(см. transcript 2026-06-05):

1. **PEM формат cert/key.** phantom-keygen выдаёт валидные PKCS#8 + EC cert,
   `openssl x509/ec` парсит без ошибок, `parse_pem_identity` напрямую с этих
   файлов работает.
2. **EC PRIVATE KEY vs PRIVATE KEY (SEC1 vs PKCS#8).** Оба формата поддерживаются
   `rustls-pemfile`.
3. **Line endings (LF vs CRLF), trailing newlines.** Воспроизведено локально —
   `rustls-pemfile` whitespace-tolerant, не падает.
4. **JNI string conversion Kotlin → Rust.** Передаётся UTF-8 JSON, JNI
   `get_string` корректно.
5. **`Base64.NO_WRAP` строгость в Kotlin parse.** Изначально подозревали, но
   декодер при `URL_SAFE` flag принимает whitespace silently.

Полный roundtrip (server cert → keys.py base64url → Kotlin parse → File.writeText
→ File.readText → ConnStringParser.build → Rust parse_conn_string →
parse_pem_identity) воспроизведённый локально в `crates/core/tests/`
**проходит чисто**. Mangling происходит ровно на одном узле — **между терминалом
оператора и Android clipboard**.

## Воспроизведение

```sh
# серверная сторона
ssh vps_poland 'docker exec phantom-server keys'   # option 4 → s25
# скопируй ghs:// строку мышью из терминала на Mac → вставь в Android Settings
# через 1-2 секунды после Connect:
adb logcat -d --pid=$(adb shell pidof io.ghoststream.vpn) | grep "tls identity"
# → InvalidTrailingPadding
```

## Fix-around (immediate, без обновления APK)

Доставлять `ghs://` через `adb push` файла, **минуя clipboard**:

```sh
ssh vps_poland 'printf "4\n1\n0\n" | docker exec -i phantom-server keys 2>&1' \
  | awk '/^ghs:\/\//{print; exit}' > /tmp/ghs.txt
adb push /tmp/ghs.txt /sdcard/Download/ghoststream.txt
# на телефоне: Files app → Download → открыть txt → Select All → Copy → Import в GhostStream
```

sha256 файла на Mac совпадает с файлом на phone после `adb push` — байт-в-байт.

## Code fix (для следующих APK билдов)

Strip non-base64url-alphabet chars из userinfo **до** `Base64.decode`. Зеркальный
fix на обеих сторонах:

- `apps/android/app/src/main/kotlin/com/ghoststream/vpn/data/ConnStringParser.kt`
  — `parse()` filter'ит userinfo: оставляет только `[A-Za-z0-9-_=]`.
- `crates/client-common/src/helpers.rs` — `parse_conn_string()` то же
  (defensive — даже если bot/keys.py добавит whitespace при генерации).

Commit: `76436c1 fix(client+keys): strip non-base64url chars from ghs:// userinfo before decode`.

3 unit-теста в `crates/client-common` прошли. Когда CI собрался — образ
`ghcr.io/patrickredstar/ghoststream-server` обновится и для серверной стороны
тоже. APK с этим fix'ом нужно отдельно собрать и поднять Play-релиз.

## Уроки

1. **Длинные ghs:// конец concept'а** для UX. Для embedded cert+key 1+ KB всегда
   будет случаться copy-paste mangling. Долгосрочное решение —
   `ghs://<short-id>@host:port` где `short-id` это short hex token, и client
   фетчит cert+key через первый HTTPS-запрос к admin endpoint (используя short
   token как Bearer). Это плановая задача, не сделана.

2. **`Base64.decode(URL_SAFE)` lenient в Android** — это документированное
   поведение, но контр-интуитивное. На приёме *всегда* strict-filter ввод до
   decode. На отправке тот же strict-filter не нужен (мы знаем что генерим
   правильно), но defensive не вредит.

3. **Mid-payload base64 corruption неотличим от valid PEM-обвёртки** при
   декодировании. Любой парсер, который сначала строит "PEM blob", затем парсит
   inner blocks по `-----BEGIN`, не поймает байтовый сдвиг — нужен или CRC, или
   валидация на стадии base64-декода. Современные `rustls-pki-types` правильно
   строгие — поймали нас в `InvalidTrailingPadding`. Старые версии могли бы
   silently вернуть corrupt cert.

4. **Не делать debug loops без local repro.** На `InvalidTrailingPadding`
   потратили 6+ часов прыгая по гипотезам. Три параллельных subagent'а с
   независимыми investigation в один заход эту же проблему сузили до ~30 минут
   точного root cause. Чем длиннее `ghs://` — тем выше шанс copy-paste mangling,
   и единственный надёжный путь debug — **локально воспроизвести с тех же
   байтов что лежат на устройстве** (`adb pull` для debuggable, sha256 diff для
   release).

## Followups

- Telegram-bot должен доставлять ghs:// как **прикреплённый файл `.txt`**, а
  не как inline-сообщение в чат (Telegram гарантированно режет длинные строки).
- Рассмотреть переход на short-id ghs:// схему — план в `docs/superpowers/plans/`.
- В release notes Android v0.27.0+ упомянуть defensive filter в parser.

## Postscriptum (2026-06-05, тот же вечер): второй баг — SEC1 vs PKCS#8

После того как фикс copy-paste padding'а заставил tunnel подняться, обнаружился
**второй**, независимый баг — **admin badge не появлялся** в Android UI даже при
успешно подключённом VPN. Сервер возвращал `{"is_admin":true,"name":"phone"}`
для прямого curl, но Android никогда не вызывал `/api/me`.

**Root cause:** Android Java `KeyFactory` поддерживает только PKCS#8 формат
private key (`-----BEGIN PRIVATE KEY-----`). `keys.py` шеллил `openssl ecparam`,
который выдаёт **SEC1** (`-----BEGIN EC PRIVATE KEY-----`). `AdminHttpClient.build`
кидал `IllegalStateException: unsupported private key algorithm` в момент
`parsePemPrivateKey(keyPem)` → попадал в silent `catch (_: Exception) {}` в
`fetchProfileSubscription` → `cachedIsAdmin` оставался `null` → long-press
admin menu не показывался.

Почему spongebob (vdsina) раньше работал, а phone (docker poland) нет —
spongebob выпускался через **admin HTTP API** (`crates/server/src/admin.rs::
generate_client_cert`), который использует `rcgen` → **PKCS#8** native.
phone был выпущен через **keys.py → openssl** → SEC1. rustls на server'е
парсит оба формата без проблем, поэтому tunnel handshake проходил — но
Android Java криптография строже.

**Fix (`server/scripts/keys.py:generate_client_cert`):** после `openssl ecparam`
конвертировать SEC1 → PKCS#8 через `openssl pkcs8 -topk8 -nocrypt`. Все новые
client.key теперь PKCS#8; существующие можно конвертировать тем же `openssl
pkcs8 -topk8` — fingerprint cert'а не меняется, только key encoding.

**Параллельный fix в Android (debug APK v0.26.20):**
- `AdminHttpClient` — timeout 5s → 30s (mobile network через VPN tunnel может
  быть медленным для первого handshake).
- `SettingsViewModel` — `fetchAllSubscriptions()` в `init {}` был race-condition
  (ProfilesStore.profiles ещё async загружается). Переписан на
  `profilesStore.profiles.collect{}` — fetch при любом обновлении списка.
- Логирование через `Log.i("AdminProbe", ...)` в catch блоках — больше никаких
  silent exceptions.

**Урок:** Android Java security stack строже чем rustls. Server-side cert
generation pipeline должен валидироваться на **обоих** клиентах (mobile +
desktop) **отдельно**, иначе один формат может тихо работать в одном и падать
в другом. Это второй раз когда openssl CLI vs rcgen/rustls дала субтильное
расхождение (см. также incident про PEM line endings).
