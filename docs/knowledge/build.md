---
updated: 2026-10-26
---

# Сборка и деплой

Всё про то, где что собирается, как деплоится и как релизится. Хосты, команды, релизный процесс Android.

---

## Среда разработки

**Claude Code работает на локальной машине разработчика** (macOS, а также Windows — см. [Сборка с Windows-хоста](#сборка-с-windows-хоста)). Репозиторий клонирован локально, сборка идёт локально, на серверы ходим по SSH. Никакой Claude-сессии «прямо на сервере» нет — все команды из разделов про сервер выполняются **после `ssh`**.

Что где собирается:

| Артефакт | Где собирают |
|---|---|
| `phantom-server`, `phantom-relay`, Linux CLI/GUI | локально `cargo` (Linux/macOS-хост) или CI |
| Android `.so` + APK/AAB | локально `tools/ship-android.sh` (нужен Android SDK/NDK + JDK 17) или CI |
| macOS `.app`/`.dmg` | только macOS-хост, `apps/macos/scripts/ship-macos.sh` |
| Windows `.exe` | Windows-хост с MSVC-тулчейном (см. ниже) или CI |
| OpenWrt | только CI (cross/zigbuild) |

## Хосты

Канонический список с ролями и оговорками — таблица «Хосты» в [CLAUDE.md](../../CLAUDE.md) (корень репо). Коротко:

| Алиас | IP | Роль | DNS |
|-------|-----|------|-----|
| `vdsina` | 89.110.109.128 | NL exit-нода (phantom-server `:8443` + nginx frontend). Из РФ фильтруются порты 22 и 443 — upstream реле только `:8443` | `tls.nl2.bikini-bottom.com` |
| `vps_balancer` | 158.160.135.140 | **боевой RU relay** — `phantom-relay` на `127.0.0.1:5443` за nginx-stream (`ssl_preread`) | `balancer.bikini-bottom.com` |
| — | 89.169.175.55 | резервный RU relay, из тракта выведен (оператор режет IP до ~15 КБ/с) | `relay.bikini-bottom.com` |

Прежний RU relay `193.187.95.128` из ротации выведен. SSH-алиасы — в `~/.ssh/config`.

**Инвариант тракта:** `клиент → balancer.bikini-bottom.com:443 (SNI=tls.nl2.bikini-bottom.com) → 89.110.109.128:8443`.

---

## Rust — Server / Linux клиент (локально)

Собирается локально в корне репозитория, бинарь потом уезжает на хост по `scp`/CI.

```bash
cd <корень репозитория>
cargo build --locked --profile release-server -p phantom-server   # и phantom-relay
cargo build --release -p phantom-client-linux
```

Серверные бинари (`phantom-server`, `phantom-keygen`, `phantom-relay`) собираются профилем `release-server` (`panic = "unwind"`: паника в одном соединении не роняет процесс) и лежат в `target/release-server/`; клиенты — в `target/release/`. Про Linux-клиент (CLI/GUI/helper) — см. [platforms/linux.md](platforms/linux.md).

---

## Android .so (cargo ndk)

Rust-ядро для Android собирает сам gradle: `preBuild` зависит от задачи `buildRustAndroid` (`cargo ndk ... -o app/src/main/jniLibs`). Каталог `jniLibs/` в git не хранится. Нужны `cargo-ndk`, NDK (`ANDROID_NDK_HOME` или NDK внутри SDK) и rustup-таргеты `aarch64-linux-android` (+ `armv7-linux-androideabi` для 32-битных TV). `tools/ship-android.sh` делает то же самое + ставит APK на устройство (только Unix-хост, см. ниже).

## Android APK (локально)

JDK 17 обязателен (gradle требует) — путь берётся из системы (`JAVA_HOME` уже настроен, либо `JAVA_HOME=$(/usr/libexec/java_home -v17)` на macOS, `/usr/lib/jvm/java-17-*` на Linux).

```bash
cd apps/android && ./gradlew assembleDebug --no-daemon
# APK: apps/android/app/build/outputs/apk/debug/app-debug.apk
```

Про Android-архитектуру целиком — [platforms/android.md](platforms/android.md).

---

## Сборка с Windows-хоста

Что нужно поставить один раз:

| Что | Зачем |
|---|---|
| `rustup target add x86_64-pc-windows-msvc` | целевой тулчейн (GNU-таргет не поддерживается) |
| **Visual Studio Build Tools** с workload «Desktop development with C++» | линкер + `rc.exe` (ресурсы `app.rc`/`app.manifest`) |
| **cmake**, **NASM**, **Perl** (Strawberry или ActivePerl) — все в `PATH` | без них не собирается `boring-sys`: `boring`/`tokio-boring` — безусловные зависимости `crates/client-common` (uTLS-fingerprint по ADR [0014](decisions/0014-transport-policy-pushable.md)) |
| `wintun.dll` (amd64) с [wintun.net](https://www.wintun.net/) | TUN-адаптер; кладётся **рядом с .exe**, fallback — `C:\Windows\System32\wintun.dll`. CI берёт `wintun-0.14.1.zip` и сверяет SHA256 |
| Терминал **от администратора** | адаптер и маршруты требуют прав; в манифесте приложения `requestedExecutionLevel level="requireAdministrator"` |

```powershell
cargo build --release -p ghoststream-windows
# .exe: target\release\ghoststream-windows.exe — рядом положить wintun.dll
```

**Ship-скрипты (`tools/ship-android.sh`, `apps/macos/scripts/*.sh`) — только для Unix-хоста**: bash + adb/xcodebuild/notarytool. С Windows Android собирается напрямую через `gradlew.bat`, macOS-сборка невозможна в принципе — только через CI.

Код Windows-клиента (`apps/windows/`, `crates/client-windows-core/`) живёт на ветке `feature/windows-client` и в master не влит. Детали — [platforms/windows.md](platforms/windows.md).

---

## Развёртывание сервера

| Что | Где (на сервере) |
|---|---|
| Runtime | `/opt/phantom-vpn/` |
| Сервис | `phantom-server.service` (systemd, с sandboxing) |
| Конфиг | `/opt/phantom-vpn/config/server.toml` |
| Keyring | `/opt/phantom-vpn/config/clients.json` |
| Клиентские серты | `/opt/phantom-vpn/config/clients/<name>/client.{crt,key}` |

Деплой — одной командой с локальной машины (на не-Linux хосте сборка идёт на сервере):

```bash
server/scripts/deploy.sh vdsina ~/.ssh/personal            # --dry-run третьим аргументом — только показать
server/scripts/deploy-relay.sh vps_balancer ~/.ssh/bot      # RU relay
```

`deploy.sh` собирает `--locked --profile release-server`, кладёт новые бинари рядом как `*.new`, останавливает сервис только на время замены (прежние остаются `.prev`), ждёт, пока начнёт слушаться порт `[h2]`, и **сам откатывает** бинарь и unit, если не дождался. `deploy-relay.sh` никогда не перезаписывает `relay.toml` на хосте. Детали — [platforms/server.md](platforms/server.md).

```bash
# Статус и логи — на сервере
systemctl status phantom-server.service
journalctl -u phantom-server.service -n 50 -f
```

### Сертификат exit: продление и контроль срока

`phantom-server` читает LE-сертификат **только при старте** — certbot обновит файл, а сервер продолжит отдавать старый, и через ~90 дней все клиенты разом упадут с «таймаутом». Поэтому на vdsina в `/etc/letsencrypt/renewal/tls.nl2.bikini-bottom.com.conf`, секция `[renewalparams]`:

```ini
renew_hook = systemctl restart phantom-server
```

Рестарт рвёт сессии раз в ~60 дней, клиенты переподключаются сами. Если хук уже был настроен на хосте — ничего не менять.

Ежедневная проверка того, что сервер **реально отдаёт** — [`server/scripts/check-cert.sh`](../../server/scripts/check-cert.sh) (ненулевой код и сообщение, если до истечения меньше 14 дней). Ставится на balancer: проверяется тот же `89.110.109.128:8443`, куда ходит реле.

```bash
install -m 0755 server/scripts/check-cert.sh /usr/local/bin/check-cert.sh   # на balancer
# crontab -e: письмо на MAILTO или своя отправка алерта по ненулевому коду
MAILTO=you@example.com
0 9 * * * /usr/local/bin/check-cert.sh >/dev/null
```

Вывод в stderr уходит в письмо cron только при проблеме. Вместо почты можно `|| curl -s "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id=$ID -d text="phantom cert"`.

---

## Docker deploy (server + relay)

Альтернативный путь развёртывания — pull-and-go через docker compose. Подходит
для свежих хостов когда не хочется возиться с cargo/systemd/iptables вручную, и
для быстрого восстановления (`tar` бэкап `/config` → mount на новом хосте →
старые ghs:// клиентов работают). Bare-metal схема выше остаётся валидной для
legacy и для случаев когда docker недоступен.

Полное описание — ADR [`0010`](decisions/0010-docker-deploy.md). Сами файлы — `docker/server/` и `docker/relay/`.

**Что в репе:**

```
docker/
  server/                  # phantom-server (NL exit)
    Dockerfile             # rust:1-bookworm → debian:bookworm-slim
    entrypoint.sh          # self-bootstrap: CA + server.toml from env, LE-серт обязателен
    compose.example.yml    # network_mode: host, privileged, /dev/net/tun, /etc/letsencrypt:ro
    .env.example           # SERVER_NAME, GHCR_OWNER, TAG, WAN_IFACE, ADMIN_TOKEN
    README.md
  relay/                   # phantom-relay (RU SNI passthrough)
    Dockerfile             # non-root UID 10001
    entrypoint.sh          # render relay.toml from env
    compose.example.yml    # bridge, ports "443:5443/tcp"
    .env.example           # UPSTREAM_ADDR, EXPECTED_SNI
    README.md
```

**Быстрый старт (свежий хост):**

```bash
certbot certonly --standalone -d <SERVER_NAME>   # только exit: без LE-серта bootstrap падает
git clone https://github.com/<owner>/phantom-vpn.git
cd phantom-vpn/docker/server   # или docker/relay
cp compose.example.yml compose.yml
cp .env.example .env
$EDITOR .env                   # SERVER_NAME (server) / UPSTREAM_ADDR+EXPECTED_SNI (relay), TAG
docker login ghcr.io           # пакеты ghcr.io/patrickredstar/* приватные
docker compose up -d
grep token config/server.toml  # ADMIN_TOKEN — в server.toml (0600), в логи не печатается
```

Клиент всегда проверяет серт сервера (ADR 0011), поэтому exit в Docker поднимается **только с Let's Encrypt** (`/etc/letsencrypt` хоста монтируется read-only). После продления — `renew_hook = docker restart phantom-server` (см. `docker/server/README.md`).

**Создать первого клиента:**

```bash
docker exec -it phantom-server keys     # интерактивное меню keys.py
```

**Восстановление со старого хоста:**

```bash
# На старом сервере (если bind-mount был ./config):
tar czf phantom-state-$(date +%F).tar.gz -C /path/to/docker/server config/
scp phantom-state-*.tar.gz new-host:~

# На новом сервере:
git clone ... && cd phantom-vpn/docker/server
cp compose.example.yml compose.yml && cp .env.example .env
mkdir -p ./config
tar xzf ~/phantom-state-*.tar.gz -C ./config --strip-components=1
docker compose up -d           # entrypoint видит существующий server.toml, пропускает bootstrap
```

Новый IP, тот же SNI/CA/fingerprint'ы — старые `ghs://` ссылки клиентов работают.

**Образы:**

CI собирает на `git push --tag v*` через `.github/workflows/docker.yml`. Push в `ghcr.io/patrickredstar/ghoststream-server` и `ghcr.io/patrickredstar/ghoststream-relay`, multi-arch (linux/amd64,linux/arm64), теги `X.Y.Z`, `X.Y` и `latest` (только на релизных, не pre-release тегах; ручной прогон — тег по имени ветки). В `.env` держать конкретный `TAG`, не `latest`. На новом хосте — `docker compose pull && up -d`.

**Когда НЕ нужен docker:**

- Бокс уже работает на bare-metal — не трогать.
- OpenWrt / embedded — там docker нет, отдельная схема (`apps/openwrt/`).

---

## Релизный процесс Android

При каждом новом релизе **обязательно** обновить `apps/android/app/build.gradle.kts`:

```kotlin
versionCode = <N+1>          // инкремент целого числа
versionName = "X.Y.Z"        // семантическая версия
buildConfigField("String", "GIT_TAG", "\"vX.Y.Z\"")
```

### Таблица версий (для расчёта versionCode)

**Источник истины — `apps/android/app/build.gradle.kts`** (`versionCode` / `versionName`). Таблица ниже — только история, при расхождении верить файлу.

| Tag | versionCode |
|-----|-------------|
| v0.8.5 | 11 |
| v0.8.6 | 12 |
| v0.8.7 | 13 |
| v0.8.8 | 14 |
| v0.8.9 | 15 |
| v0.9.0 | 16 |
| v0.10.0 | 17 |
| v0.18.5 | 48 |
| v0.19.0 | 49 |
| v0.19.1 | 50 |
| v0.19.2 | 51 |
| v0.19.3 | 52 |
| v0.19.4 | 53 |
| v0.20.0 | 54 |
| v0.21.0 | 55 |
| v0.22.1 | 56 |
| v0.22.2 | 57 |
| v0.22.4 | 59 |
| v0.23.0 (Android 0.22.6) | 61 |
| v0.23.1 | 62 |
| v0.23.4 | 65 |
| v0.24.0 | 66 |
| v0.24.4 | 70 |
| v0.25.1 | 73 |
| v0.26.8 (Android 0.26.7) | 81 |
| v0.26.22 | 100 |
| v0.27.0 | 102 |
| v0.28.4 | 122 |
| **v0.28.5** | **123** ← текущий в `build.gradle.kts` |

Для нового релиза: взять текущий `versionCode` из `build.gradle.kts` и прибавить 1. Монотонность обязательна — Play не примет AAB с уже использованным кодом.

`applicationId` = `io.ghoststream.vpn` (debug-сборка получает суффикс `.debug`). Пакет `com.ghoststream.vpn` — legacy-установка из Play Market, её не трогаем.

### Процедура релиза

```bash
# Всё сразу — bump версии, сборка Rust + APK, чистая установка на устройство:
tools/ship-android.sh --bump          # только локально
tools/ship-android.sh --bump --tag    # + тег и запуск CI
```

`--tag` = релиз в Play production, поэтому скрипт: отказывается при незакоммиченных правках (в Play уходит закоммиченное, а не то, что стоит на телефоне), перед пушем спрашивает «Проверил на устройстве? [y/N]», без локального NDK падает (CI-only сборка — только явно, `--tag --ci-only`).

Перед тегом в `CHANGELOG.md` должна быть секция `## [Android X.Y.Z]` с тем же `versionName`: из неё берётся «Что нового» для Play, без неё (или если тег ≠ `vX.Y.Z` из `build.gradle.kts`) Android-джоба падает.

Вручную (если ship-скрипт недоступен — например, с Windows-хоста):

```bash
# 1. Обновить build.gradle.kts (versionCode++ + versionName; GIT_TAG подставляется из versionName)
# 2. Собрать APK
cd apps/android && ./gradlew assembleDebug --no-daemon

# 3. Коммит + тег + пуш
git add apps/android/app/build.gradle.kts ...
git commit -m "feat: vX.Y.Z ..."
git tag vX.Y.Z
git push origin master && git push origin vX.Y.Z

# 4. Установить на телефон (для smoke-теста; НЕ трогать com.ghoststream.vpn)
adb uninstall io.ghoststream.vpn.debug 2>/dev/null
adb install apps/android/app/build/outputs/apk/debug/app-debug.apk
```

### GitHub Actions

В master три workflow: `ci.yml`, `release.yml` и `docker.yml`.

`ci.yml` — на каждый push в master: `cargo test --locked` по `phantom-core`, `phantom-client-common`, `client-core-runtime`, `ghoststream-gui-ipc`, `phantom-relay`, `phantom-server` и `cargo audit` по `Cargo.lock`. Тег его не ждёт — смотреть, что master зелёный, до тега.

`release.yml` — триггер тег `v*` или `workflow_dispatch`, собирает всё и делает GitHub Release.

| Job | Runner | Артефакт |
|-----|--------|---------|
| `build-linux` | ubuntu-latest | `phantom-client-linux` (x86_64) |
| `build-server` | ubuntu-latest | `phantom-server`, `phantom-keygen` (профиль `release-server`) |
| `build-android` | ubuntu-latest | `testDebugUnitTest` + подписанные `.apk` + `.aab`; **по тегу AAB публикуется в Google Play, трек `production`, `status: completed`** |
| `build-linux-gui` | ubuntu-24.04 | `ghoststream-linux-gui-x86_64` (tarball: GUI + helper) |
| `build-macos` | macos-latest | `.dmg` (Developer ID + notarize .app и .dmg) |
| `build-openwrt` | ubuntu-latest | matrix: `openwrt-{mipsel,armv7,aarch64,x86_64}` (musl) |
| `release` | ubuntu-latest | GitHub Release со всем, что собралось, + установщик OpenWrt, netifd-скрипт и LuCI-файлы |

⚠️ Публикация в Play идёт **сразу в production** — тег `v*` = релиз для всех пользователей. `workflow_dispatch` ничего не публикует.

GitHub Release создаётся, даже если упала одна из платформ (`if: !cancelled()`): упавшую догонять через «Re-run failed jobs». Токен сборочных джоб — только на чтение (`contents: write` есть у одной `release`), сторонние actions закреплены по SHA — обновлять их сознательно, вместе с SHA.

`docker.yml` — по тегу `v*` собирает и пушит multi-arch образы `ghcr.io/patrickredstar/ghoststream-{server,relay}`.

Отдельного `openwrt.yml` нет — OpenWrt собирается job'ом внутри `release.yml`. `windows-ci.yml` существует пока только на ветке `feature/windows-client` (в master не влит).

---

## После релиза — не забыть

- Запись в [history/timeline.md](history/timeline.md) — коротко, что за релиз.
- Если был архитектурный выбор — ADR в `decisions/NNNN-<slug>.md`.
- `npx gitnexus analyze` — обновить код-граф (обычно автоматически через post-commit hook).

## Troubleshooting сборки

Частые проблемы и решения — в [troubleshooting.md](troubleshooting.md): `JAVA_HOME`, `git push github` vs `origin`, versionCode mismatch, `adb uninstall` перед install и прочее.
