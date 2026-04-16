---
name: Android APK deployment workflow
description: При каждой загрузке нового APK на телефон автоматически создавать клиента "spongebob" и выдавать conn string
type: feedback
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
При каждой сборке и загрузке нового APK пользователя на телефон (`adb install` через SSH тунель) **автоматически**:
1. Удалить старого клиента `spongebob` если есть (`DELETE /api/clients/spongebob`)
2. Создать нового: `POST /api/clients {"name":"spongebob","expires_days":365}`
3. **Инжектировать профиль прямо в приватное хранилище приложения** (НЕ давать conn string на скан):
   - Декодировать conn_string base64url → JSON
   - Сгенерировать UUID для профиля
   - `adb shell am force-stop com.ghoststream.vpn`
   - `adb push` cert, key, profiles.json в `/data/local/tmp/`
   - `adb shell run-as com.ghoststream.vpn mkdir -p files/profiles/<uuid>`
   - `run-as cp` файлы в `files/profiles/<uuid>/{client.crt,client.key}` и `files/profiles.json`
   - Формат `profiles.json`: `{"profiles":[{id,name,serverAddr,serverName,insecure:false,certPath,keyPath,tunAddr,adminUrl,adminToken}],"activeId":uuid}` (пути абсолютные: `/data/user/0/com.ghoststream.vpn/files/profiles/<uuid>/client.crt`)
   - `adb shell monkey -p com.ghoststream.vpn -c android.intent.category.LAUNCHER 1` — запустить приложение

**Why:** Пользователь явно попросил: "в будущем при загрузке нового приложения сразу подкидывай моего клиента". После `adb install` старые сертификаты из предыдущей установки могут быть невалидны (новая подпись / очистка данных при uninstall), поэтому проще выдавать свежий клиент каждый раз.

**How to apply:** Срабатывает при workflow "собрать APK → залить на телефон". Делать это ДО того, как сообщить пользователю что APK установлен — выдавать ему conn string в том же сообщении. `relay-ru` не трогать (infrastructure client для RU hop).

**Admin API endpoint:** `http://10.7.0.1:8080` (только через VPN тунель, но Claude Code запущен на NL сервере = уже в сети 10.7.0.x)
**Admin token:** в `/opt/phantom-vpn/config/server.toml` под `[admin] token`
