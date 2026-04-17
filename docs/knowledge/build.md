---
updated: 2026-04-17
---

# Сборка и деплой

Всё про то, где что собирается, как деплоится и как релизится. Хосты, команды, релизный процесс Android.

---

## Среда разработки

**Claude Code запущен прямо на сервере vdsina (`89.110.109.128`).** `cargo` установлен локально — сборка server/linux/android идёт напрямую на этом же хосте. APK собирается на домашнем ПК через SSH (тулчейн Android SDK/JDK там). SSH ключ для всех удалённых хостов — `~/.ssh/bot`, алиасы в `~/.ssh/config`.

## Хосты

| Алиас | IP | Роль | DNS |
|-------|-----|------|-----|
| `vdsina` | 89.110.109.128 | NL exit-нода (phantom-server + nginx frontend) | `tls.nl2.bikini-bottom.com` |
| — | 193.187.95.128 | RU relay-нода (phantom-relay, SNI passthrough) | `hostkey.bikini-bottom.com` |

SSH на RU relay (нет алиаса): `ssh -i ~/.ssh/bot root@193.187.95.128`.

---

## Rust — Server / Linux клиент (локально)

Собирается на vdsina, там же и деплоится.

```bash
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-server
cargo build --release -p phantom-client-linux
```

Бинарники в `target/release/`. Про Linux-клиент (CLI/GUI/helper) — см. [platforms/linux.md](platforms/linux.md).

---

## Android .so (cargo ndk, локально)

Rust-ядро для Android собирается прямо на vdsina, результат потом забирается домашним ПК при сборке APK (копируется в `apps/android/app/src/main/jniLibs/arm64-v8a/`).

```bash
export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
cargo ndk -t arm64-v8a --platform 26 build --release -p phantom-client-android
cp target/aarch64-linux-android/release/libphantom_android.so \
  apps/android/app/src/main/jniLibs/arm64-v8a/libphantom_android.so
```

## Android APK (домашний ПК)

JAVA 17 обязателен (gradle требует).

```bash
cd apps/android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon
# APK: apps/android/app/build/outputs/apk/debug/app-debug.apk
```

Про Android-архитектуру целиком — [platforms/android.md](platforms/android.md).

---

## Развёртывание сервера

| Что | Где |
|---|---|
| Исходники | `/opt/github_projects/phantom-vpn/` |
| Runtime | `/opt/phantom-vpn/` |
| Сервис | `phantom-server.service` (systemd) |
| Конфиг | `/opt/phantom-vpn/config/server.toml` |
| Keyring | `/opt/phantom-vpn/config/clients.json` |
| Клиентские серты | `/opt/phantom-vpn/config/clients/<name>.{crt,key}` |

```bash
# Сборка + деплой (всё локально на vdsina)
cd /opt/github_projects/phantom-vpn
cargo build --release -p phantom-server
install -m 0755 target/release/phantom-server /opt/phantom-vpn/phantom-server
systemctl restart phantom-server.service

# Статус и логи
systemctl status phantom-server.service
journalctl -u phantom-server.service -n 50 -f
```

Деплой RU relay — отдельная процедура (sshim на `193.187.95.128`, процесс аналогичен, сервис `phantom-relay.service`). Детали — [platforms/server.md](platforms/server.md).

---

## Релизный процесс Android

При каждом новом релизе **обязательно** обновить `apps/android/app/build.gradle.kts`:

```kotlin
versionCode = <N+1>          // инкремент целого числа
versionName = "X.Y.Z"        // семантическая версия
buildConfigField("String", "GIT_TAG", "\"vX.Y.Z\"")
```

### Таблица версий (для расчёта versionCode)

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
| **v0.21.0** | **55** ← последний прошитый в `build.gradle.kts` |

Для нового Android релиза: взять `55 + N` (N = число релизов после v0.21.0, у которых был APK).

### Процедура релиза

```bash
# 1. Обновить build.gradle.kts (versionCode++ + versionName + GIT_TAG)
# 2. Собрать APK (на домашнем ПК)
cd apps/android && JAVA_HOME=/usr/lib/jvm/java-17-openjdk ./gradlew assembleDebug --no-daemon

# 3. Коммит + тег + пуш
git add apps/android/app/build.gradle.kts ...
git commit -m "feat: vX.Y.Z ..."
git tag vX.Y.Z
git push origin master && git push origin vX.Y.Z

# 4. Установить на телефон (для smoke-теста)
adb uninstall com.ghoststream.vpn 2>/dev/null
adb install apps/android/app/build/outputs/apk/debug/app-debug.apk
```

### GitHub Actions

`.github/workflows/release.yml` — триггер тег `v*` или `workflow_dispatch`. Автоматически делает Release со всеми артефактами.

| Job | Runner | Артефакт |
|-----|--------|---------|
| `build-linux` | ubuntu-latest | `phantom-client-linux` (x86_64) |
| `build-android` | ubuntu-latest | `app-debug.apk` |
| `release` | ubuntu-latest | GitHub Release |

`.github/workflows/openwrt.yml` — cross-compile OpenWrt клиента (MIPS/ARM). Отдельный триггер.

---

## После релиза — не забыть

- Запись в [history/timeline.md](history/timeline.md) — коротко, что за релиз.
- Если был архитектурный выбор — ADR в `decisions/NNNN-<slug>.md`.
- `npx gitnexus analyze` — обновить код-граф (обычно автоматически через post-commit hook).

## Troubleshooting сборки

Частые проблемы и решения — в [troubleshooting.md](troubleshooting.md): `JAVA_HOME`, `git push github` vs `origin`, versionCode mismatch, `adb uninstall` перед install и прочее.
