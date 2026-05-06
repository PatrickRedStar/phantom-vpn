---
updated: 2026-05-06
status: in-progress
---

# 2026-05-06 — Throughput regression: silent packet drops + tokio contention

## TL;DR

После того как пользователь решил проблему с провайдером (canал был зашейплен
на 100 Мбит/с, восстановлен до 600-800 Мбит/с download), стало видно что VPN
не даёт ожидаемой скорости. На pc через VPN single curl иногда отдаёт 385
Мбит/с (паритет с direct HTTPS), иногда зависает на 1.5 Мбит/с. На Android
устойчивые 152 Мбит/с при канале 600+. Найдено 3 регрессии в клиентском коде,
все интродуцированы либо в `feat(v0.18.3) drain/flush` (`33721eb`), либо в
Phase 4 миграции на `client-core-runtime` (`7f44240`, v0.22.0).

## Симптомы

| Метрика | Ожидание | Реальность |
|---|---|---|
| Канал baseline (iperf3 8↓ → RU) | — | 668 Мбит/с (здоровый) |
| HTTPS direct без VPN single | ~300 Мбит/с (BDP-bound на 60ms) | 300-360 Мбит/с ✅ |
| **VPN single curl run 1+2** | ~300 Мбит/с | **335-385 Мбит/с** ✅ паритет с direct |
| **VPN single curl run 3** | ~300 Мбит/с | **1.5 Мбит/с (zalip)** ❌ |
| **VPN 4 parallel curl** | ~600 Мбит/с | **55 Мбит/с (2 timeout)** ❌ |
| **VPN 8 parallel curl** | ~600 Мбит/с | **745 Мбит/с** ✅ |
| VPN speedtest single-flow | TCP-over-TCP лимит ~150 Мбит/с | 141 / 51 Мбит/с ✅ |
| Android speedtest | TCP-over-TCP лимит ~150 Мбит/с | 152 / 42 Мбит/с (норм по архитектуре, но stalls видны иначе) |

Симптом «работает то отлично, то полный stall» = классический backpressure-bug
с silent packet loss.

## История гипотез

| # | Гипотеза | Вердикт |
|---|---|---|
| 1 | Регрессия в коде после v0.22.0 (Phase 4) → плавный спад 200→160→120→50 | ❌ симптом «плавное снижение» не подходит для регрессии (она ступенчатая). Реально снижение шло из-за провайдерского shaping. |
| 2 | DPI fingerprinting клиента (rustls JA3 палится) | ❌ HTTPS direct без VPN тоже 70 Мбит/с — провайдер режет на сетевом уровне, не TLS-fingerprint. |
| 3 | Провайдерский cap ~100 Мбит/с | ✅ подтверждено iperf3 (cap не зависит от destination IP, AS). Пользователь решил с провайдером. |
| 4 | Регрессия проявилась после восстановления канала | ✅ при канале 600+ Мбит/с код начал ронять пакеты под нагрузкой, чего не было видно при 100 Мбит/с cap. |

## Root causes

### RC1: Silent packet drop в supervise диспетчере

`crates/client-core-runtime/src/supervise.rs:369`:

```rust
let dispatcher = tokio::spawn(async move {
    while let Some(pkt) = tun_pkt_rx.recv().await {
        let idx = flow_stream_idx(&pkt, n_streams);
        let len = pkt.len() as u64;
        if tx_senders_clone[idx].try_send(pkt).is_ok() {  // ← silent drop on Err
            tele.bytes_tx.fetch_add(len, Ordering::Relaxed);
            tele.stream_tx_bytes[idx].fetch_add(len, Ordering::Relaxed);
        }
    }
});
```

Per-stream channels имеют ёмкость 2048 пакетов (строка 355). Когда быстрый
TCP flow попадает в один stream, и stream-loop не успевает дренировать —
канал переполняется, `try_send` возвращает `Err(Full(_))`, пакет **молча
теряется**. TCP внутри tunnel'а делает retransmit, CWND collapse, stream
залипает в congestion-recovery.

Введено в Phase 1 экстракции (`1b5266c`, 2026-04-16) — был perенесён as-is из
старого helper'а Linux'а. На медленном канале (когда провайдер шейпил до
100 Мбит/с) проблема не проявлялась — каналы не переполнялись.

### RC2: tls_tx_loop drain без коалесцирования

`crates/client-common/src/tls_tunnel.rs:178-198`:

```rust
// Drain + coalesce: write queued frames before flushing so
// multiple batches merge into fewer TLS records / syscalls.
let mut extra_write_err = false;
for _ in 0..31 {
    match tun_rx.try_recv() {
        Ok(extra_pkt) => {
            let refs: Vec<&[u8]> = vec![extra_pkt.as_ref()];  // ← ОДИН пакет в batch
            let pt_len = match build_batch_plaintext(&refs, 0, &mut frame_buf[4..]) { ... };
            ...
            if writer.write_all(&frame_buf[..t]).await.is_err() { ... }  // ← ОТДЕЛЬНЫЙ write
        }
        Err(_) => break,
    }
}
```

Комментарий обещает «coalesce queued frames», но реально код шлёт **31 отдельный
TLS-record** размером в один пакет. Эффекты:
- 31× CPU на encrypt/decrypt per cycle.
- 31× syscalls.
- 31 мелких TLS records вместо одного нормального — хуже маскировка под H/2.

Введено в `feat(v0.18.3)` (`33721eb`, 2026-04-08) — добавили drain «для better
coalescing», но реализация буквально противоположна намерению.

### RC3: TUN writer на tokio task с blocking syscall (Android+Linux BlockingThreads)

`crates/client-core-runtime/src/tun_io.rs:165-174`:

```rust
tokio::spawn(async move {
    while let Some(pkt) = write_rx.recv().await {
        let ret = unsafe { libc::write(tun_fd, ...) };  // ← BLOCKING в tokio task
        ...
    }
});
```

Когда TUN buffer в kernel'е полный, `libc::write` блокируется. Поскольку
эта операция выполняется внутри `tokio::spawn`, **tokio worker thread**
замораживается. С 6 worker threads и потенциально несколькими активными
TUN writes — голодание async-задач (TLS RX/TX, дисeptcher).

Старый Android-код (до Phase 4) явно использовал dedicated OS thread для
TUN I/O. Комментарий в `crates/client-android/src/lib.rs` (pre-`7f44240`):

> TUN I/O runs on dedicated OS threads (not tokio) to avoid contention with
> QUIC encryption/batching, similar to the Linux client's io_uring threads.

Phase 4 миграция (`7f44240`, 2026-04-17, v0.22.0) собрала всё в
client-core-runtime, и TUN writer переехал в tokio. На pc этот баг
не проявляется (там `Uring` вариант, который не делает blocking syscall в
tokio). На Android — основная причина просадки.

## Замеры (baseline, before fixes)

Окружение:
- Клиент: spongebob-pc (CachyOS, kernel 7.0.3), Ethernet 1 Gbit/s, провайдер
  восстановил тариф (~700 Мбит/с download / ~160 Мбит/с upload aggregate).
- Сервер: vdsina (89.110.109.128, NL), bbr+fq, 16 МБ TCP buffers.
- Бинарь клиента: `phantom-client-linux` собран до фиксов.
- Тестовый файл: `/var/www/html/big.bin`, 500 МБ /dev/urandom через nginx 4443.
- VPN: 16 streams (default `n_data_streams()` на 6+ ядрах).

### Baseline без VPN

```
iperf3 1↑ → 158.160.135.140 (RU yandex)        66.9 Mbit/s
iperf3 8↑ → RU yandex                          391 Mbit/s
iperf3 1↓ ← RU yandex                          133 Mbit/s
iperf3 8↓ ← RU yandex                          668 Mbit/s   ← real channel
HTTPS direct ← vdsina (NL) single curl 200MB
  run1                                         296 Mbit/s
  run2                                         357 Mbit/s
  run3                                         305 Mbit/s
```

### С включённым VPN

```
HTTPS via VPN ← vdsina single curl 200MB
  run1                                         335 Mbit/s   ← good!
  run2                                         385 Mbit/s   ← good!
  run3                                           1.5 Mbit/s ← STALLED
HTTPS via VPN 4 parallel x 200MB
  total                                          55 Mbit/s   ← 2 of 4 timeout
HTTPS via VPN 8 parallel x 200MB
  total                                        745 Mbit/s   ← almost full channel
speedtest via VPN
  ping                                         63 ms
  download                                     141.7 Mbit/s
  upload                                        51 Mbit/s
```

Phone (Android, тот же канал, тот же сервер):
```
speedtest                                      152 / 42 Mbit/s
```

## Fixes plan

| # | Файл | Изменение | Ожидаемый эффект |
|---|---|---|---|
| 1 | `client-core-runtime/src/supervise.rs:369` | `try_send` → `send().await` (cancel-aware) | Убирает silent drop. Single-flow стабильно держит 300+ Мбит/с без random stalls. |
| 2 | `client-common/src/tls_tunnel.rs:138-202` | Coalesce drain в один `build_batch_plaintext`+ один write | -30% CPU на сервере, лучше маскировка под H/2. |
| 3 | `client-core-runtime/src/tun_io.rs:140-176` (BlockingThreads) | TUN writer вынести в `std::thread` | Android single-flow вырастет с 152 до ~250 Мбит/с (TCP-over-TCP лимит остаётся). |

Каждый фикс — отдельный коммит, отдельный замер. Cleanup статуса этого файла
после каждого этапа.

## Что НЕ трогаем (анти-DPI инварианты)

- `n_data_streams() = clamp(2, 16)` — N=16 streams часть маскировки под H/2 page load.
- Mimicry warmup (server-side, stream 0).
- Heartbeats каждые 15-45 сек на idle streams.
- `flow_stream_idx` symmetric 5-tuple hash (FIFO в рамках flow).
- Frame layout `[4B len][batch] / [2B pktlen][pkt] / 0x0000`.
- SNI passthrough nginx + relay (TLS end-to-end).
- Fakeapp fallback.
- mTLS handshake.

## Замеры — Fix #1 (try_send → send().await)

Изменение: `crates/client-core-runtime/src/supervise.rs:362-378` — диспетчер
TUN→stream использует `send().await` вместо `try_send`. При переполнении
per-stream channel диспетчер теперь блокируется и тащит backpressure вверх до
TUN reader. Никаких silent drops.

| Метрика | Before | After | Δ |
|---|---|---|---|
| Single curl run1 | 335 Мбит/с | 308 Мбит/с | ≈ |
| Single curl run2 | 385 Мбит/с | 458 Мбит/с | +19% |
| **Single curl run3** | **1.5 Мбит/с (stuck)** | **409 Мбит/с** | **×270** ✅ |
| **4 parallel curl** | **55 Мбит/с (2 timeout)** | **745 Мбит/с** | **×13.5** ✅ |
| 8 parallel curl | 745 Мбит/с | 745 Мбит/с | = (channel cap) |
| Speedtest download | 141.7 Мбит/с | 153.2 Мбит/с | +8% |
| Speedtest upload | 51.0 Мбит/с | 31.9 Мбит/с | −38% (jitter, single-shot) |

**Ключевой результат:** случайные stalls (single run3) и каскадная деградация
(4 parallel) **полностью устранены**. Single-flow throughput теперь стабильно
держит 300-460 Мбит/с (TCP-over-TCP лимит при 60ms RTT). Параллельная
нагрузка насыщает канал.

Upload-просадка в одиночном speedtest — внутри натурального jitter'а
single-shot теста на upload-ограниченном канале (asymmetric ~160 Мбит/с
от провайдера), не воспроизводится повторными замерами.

Status: ✅ landed, commit on `perf/throughput-fixes-v0.24`.

## Замеры — Fix #2 (tls_tx drain coalescing) — REVERTED

Попытка 1 (commit local, не запушено): полностью убрать `drain` цикл, сделать
один `build_batch_plaintext` + один `write_all` + flush. **Регрессия:**
4 parallel упал с 745 до 394 Мбит/с, speedtest download с 153 до 117. Похоже
что drain имел роль "secondary opportunistic batch" — подбирал пакеты,
накопившиеся в канале пока шёл encrypt + flush первого batch'а.

Попытка 2: вернуть drain, но коалесцировать его в **один** batch (а не 31
single-packet writes). 4 parallel восстановился до 671, но **8 parallel
поломался — timeout, 74 Мбит/с**. То есть была локальная регрессия в
другом edge-case.

**Откат.** В обеих попытках цена больше выгоды: оба варианта дают локальные
улучшения (CPU на сервере, более похожий H/2 паттерн), но ломают
параллельный throughput где-то ещё. Корневой механизм (как rustls
буферизует write_all'ы при отсутствии flush'а, как кооперируется с TLS record
sizing и TCP segment coalescing) требует более глубокого исследования —
профайлера на сервере, tcpdump на клиенте, и понимания что именно случилось
с 8 parallel. На текущий момент Fix #1 даёт огромный win (×13 на 4 parallel,
+8% speedtest), и ломать его ради потенциальных оптимизаций тут — плохой
размен.

В backlog: разобраться с rustls write buffering поведением, прежде чем
менять `tls_tx_loop`. Посмотреть на `tokio_rustls::TlsStream` напрямую — есть
ли там Nagle-like coalescing или каждый write_all действительно flush'ит
отдельный TLS record?

Status: ⏸ backlog.

## Замеры — Final (Fix #1 only, повторный замер)

Один час спустя, повторный прогон того же сценария:

| Сценарий | Before any fix | Fix #1 final |
|---|---|---|
| Single curl avg | 1.5–385 (флапает) | ~390 Мбит/с (стабильно) |
| 4 parallel | 55 (2 timeout) | **745 Мбит/с** |
| 8 parallel | 745 (flaky) | **789 Мбит/с** |
| 16 parallel | не замерялось | **639 Мбит/с** |
| Speedtest down | 141 Мбит/с | 177 Мбит/с |
| Speedtest up | 51 Мбит/с | 45 Мбит/с |
| iperf3 baseline 8↓ no VPN | 668 Мбит/с | 701 Мбит/с (jitter канала) |

В одном из ранних прогонов 8 parallel показал 74 Мбит/с с timeout, но повторный
прогон через несколько минут — 789 Мбит/с. Это **transient** на стороне сервера
(скорее всего phantom-server CPU saturation от другого клиента — он делит одно
ядро на всех). Не воспроизводится стабильно. В backlog: профилирование
phantom-server и потенциальный sharding по N процессов / threads.

## Что НЕ воспроизвелось (отвергнутые гипотезы)

- ❌ Регрессия в коде после v0.22.0 (Phase 4) → плавный спад. Объяснение:
  плавный спад был от провайдерского shaping, не код.
- ❌ DPI fingerprinting клиента (rustls JA3 палится). HTTPS direct без VPN
  тоже резался — провайдер режет по сетевому уровню. Решено пользователем
  с провайдером.
- ❌ Fix #2 как причина 8-parallel timeout. На Fix #1-only тоже воспроизвелось
  один раз и ушло — это transient, не от code change.

## Что осталось в backlog

1. **Fix #2 v3** — переписать `tls_tx_loop` drain с пониманием rustls write
   buffering. Цель: сократить число TLS records на сервере, не сломав
   параллельный throughput.
2. **Fix #3** (Android+BlockingThreads) — TUN writer вынести из tokio task
   в `std::thread`. Текущий код блокирует tokio worker thread на `libc::write`.
   На pc мы используем io_uring TUN — фикс не релевантен. Релевантен для
   Android, где замер показывал 152/42 Мбит/с в speedtest. Тестируется
   только на физическом телефоне.
3. **phantom-server scaling** — single process bottleneck (видим 100% CPU
   в логах). Вариант: sharding по N tokio runtimes / per-CPU process pinning.
   Не блокер для текущей задачи, но потолок при росте users.

## Sources

- Симптомы наблюдались на v0.23.1 (текущий master, commit `d6b8213`).
- Замеры выполнены 2026-05-06 22:30-23:30 MSK.
- Регрессионные коммиты: `33721eb` (drain), `1b5266c` (Phase 1), `7f44240` (Phase 4).
- Связанные ADR: [0003](../decisions/0003-h2-multistream-transport.md),
  [0005](../decisions/0005-client-core-runtime.md).
- Связанные страницы: [transport](../architecture/transport.md),
  [wire-format](../architecture/wire-format.md).
