# GhostStream Windows Client — QA Fix Sprint

**Created:** 2026-05-17
**Branch:** `feature/windows-client`
**Worktree:** `/Users/p.kurkin/ghoststream-windows`

## Context

QA3 sweep (три параллельных Explore-агента: code review, Wintun specifics,
архитектурная валидация) обнаружил 11 классов проблем разной критичности в
ветке `feature/windows-client` после восьми коммитов из одной сессии
(620390c…04f9c2d). Этот sprint закрывает их все. Цель — после этого
сделать UTM VM smoke (Phase 5) с минимумом сюрпризов.

## Задачи

Все задачи — в одной ветке `feature/windows-client`. Каждая = отдельный
коммит. Зависимости отмечены явно. Dispatcher выполняет последовательно,
паузы только на BLOCKED.

---

### Task 1 — Routing infrastructure (P0-1 + P0-2 + P1-1 + P1-5)

**Зачем:** Wintun adapter поднят и имеет IP, но без явных маршрутов Windows
ничего через него не отправит. Кроме того, IPv6 трафик минует VPN, и
TLS-пакеты к самому серверу (89.110.109.128:443) пойдут в туннель —
рекурсия, handshake умирает.

**Что делать:**
1. Создать `crates/client-windows-core/src/routing.rs`. Чистый Rust, под
   `cfg(windows)`. На не-Windows — пустой stub чтобы тесты на Mac
   компилились.
2. Функции (все используют `std::process::Command::new("netsh")`):
   - `discover_default_gateway() -> Result<Ipv4Addr>` — через
     `route print -4 | findstr 0.0.0.0` или прямой Windows API
     `GetBestRoute2` через `windows-rs` (proще через netsh для MVP).
   - `add_host_route_via_gateway(dest: Ipv4Addr, gw: Ipv4Addr) -> Result<()>`
     — `netsh interface ipv4 add route <dest>/32 <iface> <gw> metric=5`
     (для server-IP исключения).
   - `add_default_route_via_adapter(adapter_idx: u32) -> Result<()>` —
     `netsh interface ipv4 add route 0.0.0.0/1 ... ` и `128.0.0.0/1 ...`
     с metric=1. Использование /1+/1 вместо /0 — стандартный VPN-паттерн,
     перевешивает существующий 0.0.0.0/0 без удаления.
   - `set_adapter_metric(adapter_idx, metric: u32)` — `netsh interface
     ipv4 set interface <idx> metric=<metric>`.
   - `block_ipv6_route()` — `netsh interface ipv6 set route ::/0
     <wintun_idx> publish=yes` чтобы IPv6 default тоже пошёл в Wintun;
     если IPv6 не нужен, лучше `netsh interface ipv6 set global
     defaultcurhoplimit=...` отключающий. Берём **проще**: пускаем
     IPv6 в Wintun по дефолту, чтобы не закидывать его в physical.
   - Все функции возвращают `anyhow::Result<()>`, логируют через
     `tracing::info!` каждую команду + её exit code.

3. Структура: `RouteScope` struct, который хранит список применённых
   маршрутов и в Drop откатывает их (`netsh interface ipv4 delete
   route ...`). Возвращается из `apply_tunnel_routes()`.

4. `WintunBackend::new()` — НЕ применяет маршруты сам. Это слишком много
   ответственности. Маршруты применяются отдельно из `controller.rs`
   после успешного создания backend'а.

5. `controller.rs::start_real_tunnel`:
   ```rust
   let backend = WintunBackend::new(&cfg).context("create wintun backend")?;
   let gw = routing::discover_default_gateway().context("default gw")?;
   let mut scope = routing::RouteScope::new();
   let server_ip = parse_server_ip_from_conn_string(&profile.conn_string)?;
   scope.add_host_via(server_ip, gw)?;
   scope.add_default_via_adapter(backend.adapter_index()?)?;
   scope.set_metric(backend.adapter_index()?, 1)?;
   // store scope inside ActiveTunnel so Drop cleans up on Disconnect
   ```

6. `WintunBackend::adapter_index() -> Result<u32>` — нужен новый метод
   через `_adapter.get_adapter_index()` (есть в wintun 0.5.1, см.
   adapter.rs:190).

**Files:**
- new: `crates/client-windows-core/src/routing.rs`
- mod-добавление: `crates/client-windows-core/src/lib.rs`
- new method: `crates/client-windows-core/src/tun_backend.rs`
- integration: `apps/windows/gui/src/controller.rs`

**Acceptance criteria:**
- `cargo check --target x86_64-pc-windows-gnu -p client-windows-core` ✅
- `cargo check -p client-windows-core` на Mac ✅ (routing.rs stub)
- `cargo test -p client-windows-core` ✅ (новые тесты для RouteScope mock)
- `RouteScope::drop` корректно откатывает все маршруты (unit test через mock)

**Зависимости:** независима

**Commit message:** `fix(windows): P0/P1 routing — default + server exclude + IPv6 + metric`

---

### Task 2 — Backend lifecycle: Drop + graceful shutdown (P0-3 + P1-4)

**Зачем:** Persistent reader thread в Backend match arm блокируется в
`WintunBackend::read()` и **никем не пробуждается** при cancel. Adapter
остаётся в зомби-состоянии, при следующем Connect ошибки. И на kill -9
adapter вообще не cleanup'ится — остаётся в "Сетевых подключениях".

**Что делать:**
1. `crates/client-windows-core/src/tun_backend.rs`:
   - `WintunBackend::shutdown(&self) -> Result<()>` — уже есть, оставить.
   - `impl Drop for WintunBackend` под cfg(windows):
     ```rust
     fn drop(&mut self) {
         let _ = self.session.shutdown();
         // Note: adapter.delete() consumes self, but Arc<Adapter> drops
         // automatically — wintun crate handles teardown. Logging only.
         tracing::info!(category = "tun", "wintun backend dropped");
     }
     ```

2. `crates/client-core-runtime/src/lib.rs` — Backend match arm:
   - Хранить `Arc<dyn TunBackend>` в outer scope.
   - После `supervise()` завершения (внутри tokio::spawn) — вызвать
     `backend.shutdown_hint()` через новый trait method
     `TunBackend::shutdown_hint(&self)` (default impl: no-op).
   - Read loop проверяет `cancel_flag: Arc<AtomicBool>` между итерациями,
     чтобы exit'нуть на cancel даже без packet.
   - shutdown_hint пробуждает блокирующий read (для Wintun это
     `session.shutdown()` — `receive_blocking` вернёт Err).

3. `TunBackend` trait в `tun_io.rs`:
   ```rust
   pub trait TunBackend: Send + Sync + 'static {
       fn read(&self, buf: &mut [u8]) -> std::io::Result<usize>;
       fn write(&self, packet: &[u8]) -> std::io::Result<usize>;
       /// Hint that the reader thread should wake up and exit. Default
       /// is a no-op; backends that block in `read()` should override.
       fn shutdown_hint(&self) {}
   }
   ```

4. `WintunBackend::shutdown_hint` импл — вызывает `self.session.shutdown()`.

5. `MockBackend::shutdown_hint` — no-op (mock не блокирует).

**Files:**
- `crates/client-core-runtime/src/tun_io.rs` (trait + default)
- `crates/client-core-runtime/src/lib.rs` (Backend arm — wakeup + cancel
  flag, передаётся в reader thread через `Arc<AtomicBool>`)
- `crates/client-windows-core/src/tun_backend.rs` (impl shutdown_hint
  для WintunBackend и MockBackend, Drop)

**Acceptance criteria:**
- `cargo test -p client-windows-core` ✅
- Все targets cargo check ✅
- Существующие 3 теста client-windows-core зелёные
- Новый тест: после cancel reader thread выходит за < 1с (mock-based)

**Зависимости:** независима

**Commit message:** `fix(windows): P0 graceful shutdown — TunBackend::shutdown_hint + Drop`

---

### Task 3 — Wintun blocking event read (P1-2)

**Зачем:** Сейчас `WintunBackend::read()` использует `try_receive()` +
10мс sleep на WouldBlock. Это polling. Wintun экспортирует
`session.get_read_wait_event()` — Win32 HANDLE для blocking. Polling
жжёт CPU на idle и добавляет 10мс latency.

**Что делать:**
1. Добавить в `WintunBackend::read()` блокирующий путь через
   `WaitForSingleObject(handle, INFINITE)` (через `windows-rs` или
   через wintun crate если он экспортит wrapper).
2. На cancel — `session.shutdown()` пробудит wait (это уже сделано в
   Task 2 через `shutdown_hint`).
3. Альтернатива (проще): использовать `session.receive_blocking()` если
   мы уверены что `shutdown_hint` пробудит его. Проверить в wintun
   crate session.rs:104-148 — `receive_blocking` использует
   `wait_event` под капотом.

**Решение:** использовать `receive_blocking()`. Если `session.shutdown()`
пробуждает блокирующий вызов (документация говорит "cancels any active
calls to receive_blocking"), то это самый чистый путь.

**Files:**
- `crates/client-windows-core/src/tun_backend.rs` (заменить try_receive
  на receive_blocking, убрать 10ms sleep в runtime Backend arm)
- `crates/client-core-runtime/src/lib.rs` (упростить Backend arm reader
  loop — нет больше WouldBlock retry, прямой break на Err)

**Acceptance criteria:**
- `cargo check --target x86_64-pc-windows-gnu` ✅
- Логика shutdown'а: после `shutdown_hint` reader thread выходит без
  10мс задержки (mock-based: MockBackend.read() возвращает Err при
  shutdown_hint).

**Зависимости:** Task 2 (shutdown_hint)

**Commit message:** `perf(windows): P1 Wintun blocking event вместо polling`

---

### Task 4 — Mutex poison handling (P1-3)

**Зачем:** Сейчас `.expect("tray state poisoned")` упадёт если panic
произойдёт в любом forwarder/tray operation. UI crash при первой ошибке.

**Что делать:**
1. В `apps/windows/gui/src/tray.rs:88`: заменить
   `self.state.lock().expect("tray state poisoned")` на
   `self.state.lock().unwrap_or_else(|e| e.into_inner())`.
2. Проверить остальные `.expect()` на Mutex в crate'е:
   - `apps/windows/gui/src/controller.rs` — search для `.lock()`
   - `apps/windows/gui/src/main.rs` — search
   - Замены везде.
3. **Не** добавлять parking_lot — std Mutex с graceful recovery
   достаточно. Минимальный diff.

**Files:**
- `apps/windows/gui/src/tray.rs`
- Любые другие если найдены через grep

**Acceptance criteria:**
- `cargo check` ✅
- Все `.lock().expect(...)` заменены на `.lock().unwrap_or_else(...)`

**Зависимости:** независима

**Commit message:** `fix(windows): P1 mutex poison handling — graceful recovery`

---

### Task 5 — Client IP + MTU + Server из conn_string (P1-6 + P1-7)

**Зачем:** Сейчас `WintunConfig` hardcoded 10.7.0.2/30, MTU 1350, и
server IP захардкоден `89.110.109.128` в комментариях. На самом деле
эти значения берутся из `conn_string` который parse'ит
`client_common::helpers::parse_conn_string`.

**Что делать:**
1. В `controller.rs::start_real_tunnel`:
   ```rust
   let cfg = client_common::helpers::parse_conn_string(&profile.conn_string)
       .context("parse conn_string")?;
   let tun_addr: Ipv4Addr = cfg.network.tun_addr.parse()?;
   let mtu = cfg.network.mtu.unwrap_or(1350);
   let server_addr: SocketAddr = cfg.network.server_addr.parse()?;

   let wintun_cfg = WintunConfig {
       adapter_name: "GhostStream".into(),
       tunnel_type: "GhostStream Tunnel".into(),
       dll_path,
       address: tun_addr,
       netmask: Ipv4Addr::new(255, 255, 255, 252), // /30 от GhostStream
       mtu,
       dns_servers: vec![], // Task 6 заполнит из handshake response
   };
   ```
2. Аналогично в `start_simulated_tunnel` — но без `parse_conn_string`
   (симулятор не валидирует). Установить fake server_addr для UI.
3. Проверить структуру `parse_conn_string` output — какие поля у
   `cfg.network`? Прочитать `crates/client-common/src/helpers.rs`.

**Files:**
- `apps/windows/gui/src/controller.rs`

**Acceptance criteria:**
- `cargo check` ✅
- Connect → если conn_string невалидный → ошибка раньше (на parse) с
  понятным сообщением в UI (P1-9 закрывается здесь же).

**Зависимости:** независима (но интегрируется с Task 1 для routing)

**Commit message:** `fix(windows): P1 client IP + MTU + server из conn_string`

---

### Task 6 — DNS push (P0-4)

**Зачем:** Сейчас `dns_servers: vec![]`. Сервер push'ит DNS в handshake
response — мы их игнорируем. DNS queries идут через physical adapter
→ leak.

**Что делать:**
1. Изучить как сервер передаёт DNS клиенту. Прочитать:
   - `crates/client-common/src/helpers.rs` — `parse_conn_string`
   - `server/server/src/` — какой response сервер шлёт после mTLS
2. Если DNS в `conn_string` (например `dns=1.1.1.1,8.8.8.8`):
   - Извлечь в Task 5 (то же место где `tun_addr`).
3. Если DNS только в runtime handshake response (через H2 stream):
   - Это сложнее — нужен callback из `client_core_runtime::run()` с
     `on_handshake_complete` который передаёт DNS list. **Если такого
     механизма нет, добавить:** новый `mpsc::Sender<NetworkInfo>` в
     `run()` signature (опциональный, default None).
4. После получения DNS — вызвать `_adapter.set_dns_servers(&dns)`.

**Files:**
- `apps/windows/gui/src/controller.rs`
- возможно `crates/client-core-runtime/src/lib.rs` (если нужен callback)
- возможно `crates/client-core-runtime/src/supervise.rs`

**Acceptance criteria:**
- `cargo check --target x86_64-pc-windows-gnu` ✅
- Логирование: при connect видно "applied DNS: [...]"

**Зависимости:** Task 5 (parsing infrastructure)

**Commit message:** `fix(windows): P0 DNS push — применяем сервер-DNS на Wintun adapter`

---

### Task 7 — UI streams ModelRc update (P2-1)

**Зачем:** `streams: ModelRc<StreamBar>` в UI всегда пустой. Mux bars в
дизайне (предусмотрены в mockup.html) не покажут активность.

**Что делать:**
1. В `apps/windows/gui/src/bridge.rs::apply_status_to_ui`:
   ```rust
   let stream_bars: Vec<StreamBar> = (0..status.n_streams as usize)
       .map(|i| StreamBar {
           activity: status.stream_activity[i],
           label: SharedString::from(format!("s{}", i)),
           alive: i < status.streams_up as usize,
       })
       .collect();
   w.set_streams(ModelRc::new(Rc::new(VecModel::from(stream_bars))));
   ```
2. **Однако** в `main.slint` сейчас нет UI элементов которые рендерят
   `streams`. Mockup имеет mux bars блок, но он не перенесён в .slint.
   Решение: либо добавить mux-block в .slint (полный feature), либо
   только update model (data ready, UI follow-up). Для MVP — только
   model update + TODO для UI добавления.

**Files:**
- `apps/windows/gui/src/bridge.rs`

**Acceptance criteria:**
- `cargo check` ✅
- Логически streams_up/n_streams корректно проходят через бридж

**Зависимости:** независима

**Commit message:** `fix(windows): P2 update streams ModelRc в bridge — data ready для UI`

---

### Task 8 — CI download hardening (P2-2)

**Зачем:** `Invoke-WebRequest -Uri https://www.wintun.net/builds/wintun-0.14.1.zip`
без error handling. Если URL вернёт 404 / network issue — workflow упадёт
с малопонятным сообщением.

**Что делать:**
1. В `.github/workflows/windows-ci.yml`:
   - Добавить `-ErrorAction Stop -UseBasicParsing`.
   - Проверить hash скачанного ZIP против знакомого SHA256.
   - Проверить что путь `wintun-extracted/wintun/bin/amd64/wintun.dll`
     существует ПЕРЕД `Copy-Item`.
   - Fail fast с explicit message если что-то не так.

**Files:**
- `.github/workflows/windows-ci.yml`

**Acceptance criteria:**
- YAML валиден (нет syntax errors)
- Логика проверки exit code в PowerShell

**Зависимости:** независима

**Commit message:** `ci(windows): P2 wintun.dll download с проверкой hash`

---

### Task 9 — Tray timer leak (P2-3)

**Зачем:** `std::mem::forget(timer)` в `tray::install_event_pump` —
явная утечка. На рестарт процесса слот в timer registry не освобождается.

**Что делать:**
1. В `apps/windows/gui/src/tray.rs`:
   - Заменить `std::mem::forget(timer)` на хранение в `OnceLock`:
     ```rust
     static TRAY_TIMER: std::sync::OnceLock<slint::Timer> = std::sync::OnceLock::new();
     let _ = TRAY_TIMER.set(timer);
     ```
   - Слинт `Timer` не `Send`/`Sync`, поэтому `OnceLock` может не работать
     напрямую. Альтернатива: `thread_local!` в UI thread (timer ВСЕГДА
     в UI thread).

**Files:**
- `apps/windows/gui/src/tray.rs`

**Acceptance criteria:**
- `cargo check` ✅
- Никаких `std::mem::forget` в crate'е

**Зависимости:** независима

**Commit message:** `fix(windows): P2 убрать std::mem::forget(tray timer)`

---

## Порядок исполнения

```
Task 1  ─┐
Task 2  ─┼─ независимые, можно в любом порядке
Task 4  ─┤
Task 7  ─┤
Task 8  ─┤
Task 9  ─┘

Task 3 ── после Task 2 (зависит от shutdown_hint)
Task 5 ── независима, но влияет на Task 6
Task 6 ── после Task 5 (parsing infra)
```

Рекомендуемая последовательность: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9.

Каждая задача = отдельный commit. После всех 9 — финальный code review
для всей implementation.

## Acceptance criteria для всего sprint

После всех 9 задач:
- `cargo test -p client-windows-core` ✅
- `cargo check -p client-windows-core -p ghoststream-windows` (Mac native) ✅
- `cargo check --target x86_64-pc-windows-gnu -p client-windows-core -p ghoststream-windows` ✅
- `cargo check -p phantom-client-android -p phantom-client-apple -p phantom-client-linux` ✅ (нет регрессий)
- Все QA findings закрыты:
  - P0: 1, 2, 3, 4 → ✅
  - P1: 1, 2, 3, 4, 5, 6, 7, 9 → ✅ (P1-8 verification only)
  - P2: 1, 2, 3 → ✅
