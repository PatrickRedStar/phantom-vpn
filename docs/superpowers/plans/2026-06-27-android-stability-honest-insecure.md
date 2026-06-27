# 2026-06-27 — Android: честный статус + уведомления, стабильность, удаление Insecure

Источник: многоагентное расследование (workflow `ghoststream-android-deep-investigation`,
9 агентов) + живая диагностика устройства/серверов. Согласованный с пользователем scope.

## Контекст (что выяснили)

- Устройство `io.ghoststream.vpn.debug` v0.26.23-debug (vc101) — сборка **уже с** фиксом
  concurrent-open / RX_IDLE=75 (коммит `d2faea0`), просто **не тегнута** (последний тег v0.26.22).
  Прямо сейчас подключено и здорово (8/8 стримов, health=healthy на профиле s25). Значит
  оставшиеся жалобы — **отдельные реальные баги**, а не «фикс не доехал».
- Активный профиль `s25` = direct `82.38.66.138:8443`, relay off — худший случай для DPI
  (повтор инцидента 2026-06-13). Серверная сторона poland **здорова**.
- NL-exit `vdsina` полу-мёртв (TCP:443 жив, TLS/SSH немы) → профиль `spongebob` нерабочий.
- `insecure=true` полностью выключает проверку серверного серта (MITM-вектор), UI про это врёт.

## Scope этого захода

- **A. Честный статус + уведомления** (Kotlin)
- **B. Стабильность — code-bugs** (Rust core: `client-core-runtime`, `client-common`)
- **C. Удалить Insecure TLS** через TOFU/SPKI-пиннинг серверного серта в Rust

## Вне scope (отложено, согласовано)

- Универ «только :443» + поднятие relay под poland / возврат `vdsina` — отдельной задачей
  («вероятно relay активируем»).
- Тяжёлый Doze-код (AlarmManager.setExactAndAllowWhileIdle, приёмник ACTION_DEVICE_IDLE_MODE_CHANGED)
  — **после** воспроизведения off-charge на устройстве. В этом заходе только дешёвый
  проактивный battery-exemption перед Connect (часть B).

## Инварианты — НЕ нарушать (ради них всё и затевалось)

- N стримов = числу ядер; **все N обязательны для Connected** (никакого partial-quorum).
- Транспорт H2/TLS1.3/TCP; нет UDP. Не снижать HANDSHAKE_TIMEOUT.
- `:8443` loopback-only (на NL); relay не терминирует TLS; SNI passthrough.
- ALPN h2; mimicry warmup только на stream_idx==0 && is_new; stream0-first сохранить.
- Honest-state (ADR 0009) — **усиливать**, не маскировать.
- Минимальный diff; не плодить feature flags; verify before/after на общем core.

---

## A. Честный статус + уведомления (Kotlin, design-approval до кода)

Файлы: `apps/android/.../service/GhostStreamVpnService.kt`,
`.../service/VpnStateManager.kt`, `.../ui/dashboard/DashboardScreen.kt`,
`crates/gui-ipc` (если в StatusFrame нет `stream_activity` — проверить, оно вроде есть).

A1. **Нотификация читает health.** Добавить ОДИН collector в сервисе на
`VpnStateManager.derivedVpnState` (он уже честный — учитывает Dead/Stale/Throttled/Reconnecting
через `deriveUiState`). Расширить `buildNotification(...)` принимать state+health+bytes.
`setOnlyAlertOnce(true)` чтобы частые обновления bytes не звенели.
Тексты (черновик, на утверждение): Healthy→`Защищено · ↓X ↑Y`, Stale→`Канал замолчал (Nс)`,
Throttled→`Скорость ограничена (N kbps)`, Reconnecting→`Переподключение N/8`,
Dead→`Связь потеряна, восстанавливаю`.

A2. **Статус-бар/иконка** — источником сделать `derivedVpnState`, НЕ строку `state`.
Watchdog **не трогаем** (он остаётся триггером teardown; reconnect в Kotlin не дублируем —
это сломало бы per-category backoff Rust-стороны).

A3. **Инфографика не врёт.** `muxCardSection` читать `frame.streamsUp/frame.nStreams`
вместо литералов `8,8`. Добавить `streamActivity: List<Float>` в `StatusFrameData.fromJson`
(массив `stream_activity` уже в StatusFrame), строить `barHeights` из него, обрезая по `nStreams`.
Пороги `derive_health` НЕ трогать.

A4. **Уведомление об обрыве** (отдельный алерт, не ongoing): отдельный канал importance DEFAULT
+ единичный `notify` на переходе health→Dead/Reconnecting + запрос `POST_NOTIFICATIONS`
(Android 13+) в onboarding. **Требует утверждения дизайна нотификации.**

**Гейт:** HTML-макет состояний нотификации + дашборда → явный approve → код.

## B. Стабильность — code-bugs (Rust core, verify before/after)

Файлы: `crates/client-core-runtime/src/supervise.rs`, `.../telemetry.rs`,
`crates/client-common/src/tls_tunnel.rs`, `apps/android/.../GhostStreamVpnService.kt` (B4).

B1. **TX-only зомби.** Добавить TX-liveness watchdog рядом с death-watcher. Условие реконнекта —
**расхождение**, не чистый idle: TX-очередь непуста (есть неотправленные пакеты), но
`telemetry.last_tx_unix_ms` не двигается дольше порога (> HEARTBEAT_MAX=45 + slack, по аналогии
с RX_IDLE=75, строго >45). Чистый idle (юзер не качает) НЕ реконнектить.

B2. **Degraded K/N → teardown.** Ветку `alive < half` (после короткого grace-окна на штатную
пересборку стримов) сделать триггером **полного** teardown+reconnect всех N (НЕ partial-quorum).
Grace чтобы не рвать в момент legitimate-пересборки.

B3. **Арм dispatcher в главный select!** `drive_tunnel` сейчас не реагирует на завершение
dispatcher (TUN→stream). Добавить арм на его завершение → остановка TX ведёт к teardown сразу,
а не через окольный RX_IDLE(75с).

B4. **Проактивный battery-exemption** (дешёвая часть Doze). Перед первым Connect показать
системный запрос `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, если ещё не выдан (сейчас он спрятан
пассивным баннером в Settings). Без UDP, без понижения N.

B5. (косметика, опц.) per-stream `Instant` в момент успешного open вместо общего
`stream_started_at` — для корректного `lifetime_ms` в логах.

**Verify:** перед правкой — impact (callers) + полное чтение затрагиваемых функций; после —
`cargo check/clippy/test` + workflow-ревью общего core (правило пользователя).

## C. Удалить Insecure TLS через пиннинг (Rust core + security)

Файлы: `crates/core/src/tls.rs` (`SkipVerification`, `build_root_store`),
`crates/core/src/h2_transport.rs` (`make_h2_client_tls`), `client-core-runtime/src/supervise.rs:175`,
`crates/core/src/config.rs`, `crates/client-common/src/helpers.rs`,
Kotlin: `SettingsScreen.kt`/`SettingsViewModel.kt`/`ConnStringParser.kt`/`VpnProfile.kt`,
сервер: `server/server/src/admin.rs` (build_conn_string), ADR 0004 + glossary.

Порядок строгий (verify-before/after на общем core):

C1. Реализовать кастомный rustls `ServerCertVerifier` в `crates/core/src/tls.rs`: сверяет
SHA-256 пина leaf-серта (как уже делает `AdminHttpClient.kt` для admin API), hostname **не**
проверяет — это сохраняет SNI-override для обхода DPI. MITM невозможен (атакующий не знает
приватный ключ серверного серта).

C2. Пробросить пин per-profile тем же каналом, что cert/key (JNI/providerConfiguration).
Первый коннект = TOFU (принять, посчитать fingerprint, сохранить), дальше строгая сверка.
Точный аналог admin-flow.

C3. Убедиться что s25/spongebob поднимаются с пиннингом (verify на устройстве на s25 — exit жив).

C4. **Только потом** убрать `insecure`: из UI (SettingsScreen/ViewModel/VpnProfile),
парсера `helpers.rs`, `ConnStringParser.kt`, серверного `build_conn_string`. `SkipVerification`
не удалять мгновенно — сначала перевести путь на пиннинг.

C5. Обновить ADR 0004 (или новый ADR) + glossary, вернуть honest UI (убрать «skip hostname check /
mTLS остаётся» — это вводило в заблуждение).

Открытый вопрос: пин = SHA-256 leaf (как admin сейчас) vs SPKI-pin (устойчив к ротации серта
при том же ключе). Решить до C1 — рекомендую leaf-SHA-256 для консистентности с admin TOFU,
SPKI как follow-up.

---

## Релиз (по окончании)

- versionCode++ (с 101 → 102), versionName bump в `apps/android/app/build.gradle.kts` + GIT_TAG.
- Сборка/установка через `tools/ship-android.sh` (Rust .so + Kotlin + clean install).
- Тест на устройстве (s25 — exit жив): Connect, проверить честность статуса/нотификации/инфографики,
  logcat. Off-charge Doze-тест отдельно (для будущей тяжёлой Doze-задачи).
- Тег `vX.Y.Z` → дождаться `release.yml` зелёным.
- Документация: ADR (insecure→pinning), обновить `platforms/android.md` (нотификация/honest-state),
  запись в `history/timeline.md`. Инцидент Doze — постмортем после repro.

## Порядок исполнения

1. Макет UI (A) → approve.
2. C (insecure→pinning) — самостоятельная security-зона, общий core, verify before/after.
3. B (стабильность) — общий core, verify before/after.
4. A (UI) — после approve макета.
5. Релиз + тест на устройстве + CI.

(C перед B т.к. обе трогают core; делаем по очереди с отдельными verify, чтобы не мешать diff'ы.)
