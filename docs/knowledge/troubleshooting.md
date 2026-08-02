---
updated: 2026-08-02
---

# Troubleshooting

Типичные проблемы, команды диагностики, куда смотреть первым делом. Постмортемы отдельных инцидентов — в [incidents/](incidents/).

---

## Частые ошибки и решения

| Проблема | Решение |
|----------|---------|
| `JAVA_HOME not set` при сборке APK | Указать JDK 17 из системы: macOS `export JAVA_HOME=$(/usr/libexec/java_home -v17)`, Linux `/usr/lib/jvm/java-17-*`, Windows — путь установленного JDK 17 |
| `git push github` fails | Remote называется `origin`, не `github` |
| `adminUrl`/`adminToken` не сохраняются в профиле | Исправлено в v0.8.7: `ProfilesStore` теперь сериализует оба поля |
| `adb install` fails signature mismatch | `adb uninstall com.ghoststream.vpn` перед install (нужно при смене подписи или очистке данных) |
| Android: `versionCode` не совпадает | Обновить `apps/android/app/build.gradle.kts` перед тегом — таблица в [build.md](build.md) |
| Подписка не отображается в UI | Требует `adminUrl` + `adminToken` в профиле (нужна строка подключения v0.7+) |
| MCP `gitnexus_*` tools missing | См. `~/.claude/projects/.../memory/project_mcp_setup.md` — чаще всего `npx` вместо прямого биннаря → timeout. Установить глобально: `npm install -g gitnexus@latest` |

---

## Команды диагностики (server-side)

⚠️ **Всё ниже выполняется НА СЕРВЕРЕ, после `ssh vdsina`** — не локально. Claude Code работает на машине разработчика, локально этих сервисов нет.

```bash
# Статус и логи сервиса (на vdsina)
systemctl status phantom-server
journalctl -u phantom-server -n 50 -f

# Текущий keyring / клиенты
cat /opt/phantom-vpn/config/clients.json

# Admin API из VPN-туннеля (loopback listener, plain HTTP + Bearer token)
curl -H "Authorization: Bearer <token>" http://10.7.0.1:8080/api/status
curl -H "Authorization: Bearer <token>" http://10.7.0.1:8080/api/clients

# Боевой RU relay — отдельный хост (SSH-алиас vps_balancer, порт 9083)
ssh vps_balancer

# На RU relay — состояние phantom-relay (тоже по SSH, не локально)
systemctl status phantom-relay
journalctl -u phantom-relay -n 50 -f
```

Актуальные хосты/алиасы — таблица «Хосты» в [CLAUDE.md](../../CLAUDE.md).

Про устройство Admin API (mTLS listener vs loopback listener) — [architecture/admin-api.md](architecture/admin-api.md).

---

## Android логи

Требует подключённого устройства и `adb` из Android SDK — с Windows-хоста без установленного SDK недоступно (тогда логи забирать через Debug share в приложении).

```bash
# Все логи GhostStream VpnService
adb logcat -s GhostStreamVpn

# Rust-логи идут через JNI в `nativeGetLogs(sinceSeq)` → LogsScreen.
# Уровни: TRACE/DEBUG/INFO/WARN/ERROR, иерархические (показываем уровень и выше).
# Buffer: Rust кольцевой, 10 MB, `nativeSetLogLevel("trace"|"debug"|"info")`.
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
- **DPI блокировка** → [architecture/transport.md](architecture/transport.md) (SNI passthrough, mimicry warmup).
- **Инцидент стоил >2ч** → завести запись в [incidents/YYYY-MM-DD-<slug>.md](incidents/).
