---
updated: 2026-10-26
---

# Troubleshooting

Типичные проблемы, команды диагностики, куда смотреть первым делом. Постмортемы отдельных инцидентов — в [incidents/](incidents/).

---

## Частые ошибки и решения

| Проблема | Решение |
|----------|---------|
| `JAVA_HOME not set` при сборке APK | Указать JDK 17 из системы: macOS `export JAVA_HOME=$(/usr/libexec/java_home -v17)`, Linux `/usr/lib/jvm/java-17-*`, Windows — путь установленного JDK 17 |
| `git push github` fails | Remote называется `origin`, не `github` |
| `adb install` fails signature mismatch | `adb uninstall com.ghoststream.vpn` перед install (нужно при смене подписи или очистке данных) |
| Android: `versionCode` не совпадает | Обновить `apps/android/app/build.gradle.kts` перед тегом — таблица в [build.md](build.md) |
| Срок подписки не отображается в UI | Берётся из `/api/me` после подключения (поля `expires_at`, `enabled`). Сервер старше v0.29.0 их не отдаёт — обновить сервер |
| MCP `gitnexus_*` tools missing | См. `~/.claude/projects/.../memory/project_mcp_setup.md` — чаще всего `npx` вместо прямого биннаря → timeout. Установить глобально: `npm install -g gitnexus@latest` |

---

## Ошибки клиента

Ядро переподключается само и бесконечно; ошибку (`state=error`) показывает
только когда ретрай не поможет ([ADR 0018](decisions/0018-rust-owns-reconnect.md)).

| Что видит пользователь | Причина | Что делать |
|---|---|---|
| **«Доступ отозван»** | Сервер отклонил клиентский серт в рукопожатии (алерт `certificate_revoked`): клиент выключен, удалён или его нет в `clients.json`. Истёкшая подписка выглядит так же — сервер выключает клиента. Клиент не переподключается | Проверить клиента в админке или боте (`enabled`, `expires_at`). Удалённому — выпустить новую строку подключения. После правки — нажать Connect |
| **«Срок действия доступа истёк»** | Истёк срок клиентского сертификата (алерт `certificate_expired`); подписка тут ни при чём | Выпустить новую строку подключения |
| **«Сертификат сервера недействителен на текущую дату — проверьте дату и время на устройстве»** | Серт exit'а «просрочен» или «ещё не действует» с точки зрения часов устройства. Почти всегда — сбитые часы | Включить автоматические дату и время. Если часы верные — истёк LE-серт exit'а: `server/scripts/check-cert.sh` с balancer, `renew_hook` на vdsina ([build.md](build.md#сертификат-exit-продление-и-контроль-срока)) |
| **«Нет связи»** (Android, уведомление через 25 с) | Ядро не достучалось до сервера. TUN держится как kill switch — трафик заблокирован, ретраи идут сами | 1) «Отключить» и проверить, есть ли интернет без VPN. 2) Wi-Fi с входом — подсказка «Wi-Fi требует входа», войти и переподключиться. 3) Реле: `journalctl --namespace=phantom-relay -f` на balancer. 4) Exit: `check-cert.sh` и `nc -vz 89.110.109.128 8443` с balancer. Когда путь починится, туннель поднимется сам |
| Подключено, но имена не резолвятся при строгом Private DNS (Android) | До v0.29.0 туннель объявлял `::/0` без IPv6-адреса, и DoT по IPv6 зависал | В v0.29.0 исправлено: IPv6 в туннеле не объявляется, DNS идёт по IPv4. На старой версии — обновить приложение |
| «Деградация: k/n стримов» (Android), «Деградация: живы k из n потоков» (iOS) | Часть стримов умерла, ядро переоткрывает их по одному (1–10 с) | Ждать. Если висит минутами — в логах `stream.retry` / `stream.open_failed`, затем реле |

---

## Команды диагностики (server-side)

⚠️ **Всё ниже выполняется НА СЕРВЕРЕ, после `ssh vdsina`** — не локально. Claude Code работает на машине разработчика, локально этих сервисов нет.

```bash
# Статус и логи сервиса (на vdsina)
systemctl status phantom-server
journalctl -u phantom-server -n 50 -f

# Текущий keyring / клиенты
cat /opt/phantom-vpn/config/clients.json

# Admin API на самом сервере: loopback-listener, plain HTTP + Bearer
# (Bearer принимается только с 127.0.0.1; 10.7.0.1:8080 — только mTLS-серт клиента)
curl -H "Authorization: Bearer <token>" http://127.0.0.1:8081/api/status
curl -H "Authorization: Bearer <token>" http://127.0.0.1:8081/api/clients

# Боевой RU relay — отдельный хост (SSH-алиас vps_balancer, порт 9083)
ssh vps_balancer

# На RU relay — состояние phantom-relay (тоже по SSH, не локально)
systemctl status phantom-relay
journalctl --namespace=phantom-relay -n 50 -f   # свой namespace, хранится ≤2 суток

# Срок серта, который exit реально отдаёт (с balancer)
server/scripts/check-cert.sh
```

Актуальные хосты/алиасы — таблица «Хосты» в [CLAUDE.md](../../CLAUDE.md).

Про устройство Admin API (mTLS listener vs loopback listener) — [architecture/admin-api.md](architecture/admin-api.md).

---

## Android логи

Требует подключённого устройства и `adb` из Android SDK — с Windows-хоста без установленного SDK недоступно (тогда логи забирать через Debug share в приложении).

```bash
# Все логи GhostStream VpnService
adb logcat -s GhostStreamVpn

# Rust-логи приходят push'ем через PhantomListener.onLogFrame → LogsScreen.
# Уровни: TRACE/DEBUG/INFO/WARN/ERROR, иерархические (показываем уровень и выше).
# Подробный уровень ядра — только пока открыт журнал; Log.d — только в DEBUG-сборке.
```

Debug share в приложении (`SettingsViewModel.shareDebugReport`) собирает: версия + git tag, Android OS/модель, профиль без ключей, VPN state, конфиг, последние 500 строк Rust-логов. Файл в `cache/debug/ghoststream-debug.txt` через FileProvider + `ACTION_SEND`.

Подробнее про Android — [platforms/android.md](platforms/android.md).

---

## iOS логи

NSLog/os_log для Swift, Rust-логи пробрасываются через FFI log callback. Console.app → фильтр по process `GhostStream` или `PacketTunnelProvider`.

Подробнее про iOS — [platforms/ios.md](platforms/ios.md).

---

## Windows

Заготовка — по мере эксплуатации дополнять. Детали клиента — [platforms/windows.md](platforms/windows.md).

| Симптом | Что делать |
|---|---|
| `wintun.dll not found` | DLL ищется рядом с `.exe`, fallback — `C:\Windows\System32\wintun.dll`. Положить amd64-версию с [wintun.net](https://www.wintun.net/) рядом с бинарём. |
| Приложение стартует и сразу падает / нет прав на адаптер | Запускать от администратора: в манифесте `requireAdministrator`, при отказе UAC процесс не поднимется. |
| Defender утащил `.exe` в карантин | Сборка не подписана — добавить исключение для папки с билдом либо забирать артефакт из CI. |
| Адаптер завис после аварийного завершения (нет сети / старые маршруты) | Снести адаптер GhostStream в «Диспетчере устройств» → сетевые адаптеры, проверить остатки: `route print`. |
| Ошибки `netsh` / `route ADD` при подъёме туннеля | Маршруты ставятся через `route ADD` (host-exclude на сервер) и `netsh interface ipv4 add route` (сплит `0.0.0.0/1` + `128.0.0.0/1`). Причины: не админ, конфликт с другим VPN, неопределившийся физический шлюз. |

---

## MCP gitnexus missing tools

Симптом: в сессии нет `gitnexus_query`, `gitnexus_impact`, `gitnexus_callers` и прочих.

Причина (2026-04-17): MCP config использовал `npx -y gitnexus@latest mcp`. На cold start npx тянет ~300 пакетов (tree-sitter deps) → 30+ секунд → Claude Code MCP handshake timeout → tools не загружаются.

Фикс:
1. `npm install -g gitnexus@latest` (бинарь появится в `/opt/homebrew/bin/gitnexus` на macOS или `~/.npm-global/bin/gitnexus` на Linux).
2. В `~/.claude.json` под проектом выставить:
   ```json
   {"type": "stdio", "command": "gitnexus", "args": ["mcp"]}
   ```
3. Перезапустить сессию.
4. Проверить `which gitnexus` → должен вернуть путь к бинарю.
5. Если всё ещё пусто — `.gitnexus/meta.json` в корне репо должен существовать (иначе индекс пуст). Переиндексировать: `gitnexus analyze`.

Полный контекст — [tools/gitnexus.md](tools/gitnexus.md).

---

## Куда копать дальше

- **Регрессия производительности** → ищи похожий коммит в [history/timeline.md](history/timeline.md) (например, `5a72d6e` — revert pipeline collapse).
- **Странное поведение handshake / TLS** → [architecture/handshake.md](architecture/handshake.md) + [architecture/crypto.md](architecture/crypto.md).
- **Stream fell apart** → [architecture/sessions.md](architecture/sessions.md) (attach/detach logic).
- **DPI блокировка** → [architecture/dpi-tspu.md](architecture/dpi-tspu.md), [architecture/transport.md](architecture/transport.md) (SNI passthrough, паддинг первых кадров).
- **Инцидент стоил >2ч** → завести запись в [incidents/YYYY-MM-DD-<slug>.md](incidents/).
