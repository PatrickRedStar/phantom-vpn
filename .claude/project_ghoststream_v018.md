---
name: GhostStream v0.18 grail architecture + implementation matrix
description: Full design of v0.18 (RBT + mimicry + flow-affine io_uring + fake app-face), measured bottlenecks it fixes, remaining detection vectors, and exact code changes per file
type: project
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
# Контекст

Принято 2026-04-11 как план на v0.18. Базируется на измеренных bottleneck'ах v0.17.2 (см. reference_bottleneck_v0172.md) и анализе VPN landscape 2026 (см. reference_vpn_landscape_2026.md). Пользователь одобрил «сразу всё целиком» через параллельных агентов.

**Why:** v0.17.2 даёт 314/625 Mbit/s при потолке crypto ~26 Gbit/s — это значит bottleneck в tun_uring writer (1 syscall/packet), round-robin dispatcher (ломает flow affinity), и отсутствии batched send_many. Плюс архитектура уязвима к новой TSPU эвристике 15-20KB TCP lockout.

**How to apply:** v0.18 = RBT (Rolling Burst Transport) + mimicry pacing + flow-affine io_uring + fake HTTPS app-face. Всё вместе даёт +15-80% скорости и защищает от текущего поколения TSPU. Следующий этап v0.19 должен убрать mTLS и добавить multi-origin — эти две дыры v0.18 НЕ лечит.

---

# Финальная архитектура v0.18

## Рабочее имя

**GhostStream v0.18** = RBT (Rolling Burst Transport) поверх mTLS/1.3 с flow-affine io_uring backend.

## Что видит ТСПУ на проводе

```
Phone/PC ──► nginx stream:443 ──► phantom-server:8443
          TCP pool[N=max(nproc*2,8)]
          SNI=tls.nl2.bikini-bottom.com
          TLS 1.3 + mTLS
          каждый коннект = HTTP/1.1 POST /api/v1/telemetry chunked
          ~10 KB payload → close → новый
```

## Handshake пошагово

```
T+0ms    Client: TCP connect → vdsina:443
T+20ms   nginx: ssl_preread SNI → backend 127.0.0.1:8443
T+40ms   TLS 1.3 + mTLS (client cert → fingerprint → keyring lookup)
T+60ms   Client: POST /api/v1/telemetry HTTP/1.1
                 Transfer-Encoding: chunked
T+61ms   Client: [1B stream_idx][1B max_streams]   ← NEW v0.18 negotiation
T+65ms   Server: берёт effective_streams = min(client_N, server_N)
T+70ms   Mimicry warmup (first 5 sec):
           T+70ms:   2 KB
           T+400ms:  pause
           T+700ms:  8 KB
           T+900ms:  pause
           T+1100ms: 16 KB
           T+1300ms: 24 KB
T+5000ms Free-flow VPN на полной скорости, до ~10 KB limit → close → новый
```

## Steady state

- 8 параллельных TLS коннектов (на 2-core; `max(nproc*2, 8)`)
- Каждый живёт до 10 KB payload → close
- Rate ротации при 500 Mbit/s ≈ 6250 conn/sec через пул = каждый ~1.3 ms
- Packets inner flow распределены по `effective_streams` через `flow_stream_idx`
- TUN write: `IORING_OP_WRITEV` батчами 32-64 packets

## Ожидаемая производительность

| Метрика | v0.17.2 | v0.18 |
|---|---|---|
| Download | 625 Mbit/s | ~720 Mbit/s (+15%, WRITEV minus RBT overhead) |
| Upload | 314 Mbit/s | ~560 Mbit/s (×1.8, RX path fix) |
| CPU RX efficiency | 3.6 Mbit/%CPU | ~7.5 Mbit/%CPU (×2) |
| io_uring_enter/pkt | 0.67 | ~0.05 (batch=32) |
| Overhead ratio | 4.0× upload | ~2.3× |

Теоретический потолок ~900 Mbit/s на 2-core KVM, дальше упрёмся в crypto на одном rustls thread.

---

# Матрица изменений — file by file

## crates/core/src/wire.rs

**Текущее:**
```rust
pub const N_DATA_STREAMS: usize = 4;
pub const N_STREAMS: usize = N_DATA_STREAMS;
```

**v0.18:**
```rust
/// Capped by config, always >= 1.
pub const MAX_N_STREAMS: usize = 16;

/// Runtime-cached auto-detected stream count.
pub fn n_data_streams() -> usize {
    use std::sync::OnceLock;
    static CACHED: OnceLock<usize> = OnceLock::new();
    *CACHED.get_or_init(|| {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
            .clamp(1, MAX_N_STREAMS)
    })
}

/// Alias for backward compat with existing call-sites.
pub fn n_streams() -> usize { n_data_streams() }
```

Плюс `flow_stream_idx` оставить как есть — он уже нормальный.

## crates/core/src/tun_uring.rs

### Fix 1: WRITEV batching (lines 150-162)

**Текущее (ПРОБЛЕМА: 1 syscall per packet):**
```rust
for (i, pkt) in pending.iter().enumerate() {
    let entry = opcode::Write::new(fd_t, pkt.as_ptr(), pkt.len() as u32)
        .build().user_data(i as u64);
    unsafe { ring.submission().push(&entry).ok(); }
}
ring.submit_and_wait(pending.len())?;
```

**v0.18 (WRITEV batch — 1 syscall per batch):**
```rust
// Batch up to 32 packets into single writev
let iov: Vec<libc::iovec> = pending.iter().map(|pkt| libc::iovec {
    iov_base: pkt.as_ptr() as *mut _,
    iov_len: pkt.len(),
}).collect();
let entry = opcode::Writev::new(fd_t, iov.as_ptr() as *const _, iov.len() as u32)
    .build().user_data(0);
unsafe { ring.submission().push(&entry).ok(); }
ring.submit_and_wait(1)?;
```

⚠️ Внимание: writev на TUN записывает КАЖДЫЙ iov как отдельный IP packet (TUN ждёт по одному packet на write). На некоторых ядрах это работает, на некоторых — нет. Альтернатива: `IORING_OP_WRITE_FIXED` с zero-copy buffers. Проверить на vdsina ядре.

### Fix 2: flow-hash dispatcher (lines 219-230)

**Текущее (round-robin ломает flow affinity):**
```rust
let mut idx = 0usize;
while let Some(pkt) = rx.blocking_recv() {
    if writer_txs[idx].blocking_send(pkt).is_err() { break; }
    idx = (idx + 1) % n_queues;
}
```

**v0.18:**
```rust
use crate::wire::flow_stream_idx;
while let Some(pkt) = rx.blocking_recv() {
    let idx = flow_stream_idx(&pkt, n_queues);
    if writer_txs[idx].blocking_send(pkt).is_err() { break; }
}
```

### Fix 3: Zero-copy reader (lines 98-99)

**Текущее (extra memcpy):**
```rust
let mut bm = BytesMut::with_capacity(len);
bm.extend_from_slice(&bufs[idx][..len]);
```

**v0.18:** Использовать `IORING_REGISTER_BUFFERS` + `IORING_OP_READ_FIXED`. Буфер остаётся в kernel-registered pool, `Bytes::from_owner()` оборачивает его zero-copy. Требует структурной переработки ring setup.

## crates/server/src/h2_server.rs

### Fix 4: Batched send_many в tls_rx_loop (line 226)

**Текущее:**
```rust
for pkt in extract_batch_packets(&plaintext)? {
    tun_tx.send(pkt).await?;
}
```

**v0.18:**
```rust
let pkts = extract_batch_packets(&plaintext)?;
for pkt in pkts {
    // batch-drain: накопить до 32 и отправить одним send_many
    ...
}
// или: новый API tun_tx.send_many(pkts).await?
```

Требуется добавить `send_many` поверх mpsc (простая обёртка).

### Fix 5: Handshake negotiation

**Текущее:** читает 1 байт `stream_idx`.

**v0.18:** читает 2 байта `[stream_idx, max_streams_client]`, берёт `effective = min(server_n, client_n)`, проверяет `stream_idx < effective`.

### Fix 6: Mimicry warmup (первые 5 сек)

Новый модуль `crates/server/src/mimicry.rs`:
```rust
pub struct WarmupSchedule {
    steps: Vec<(Duration, usize)>, // (at, bytes)
}
impl WarmupSchedule {
    pub fn default_http_mimic() -> Self { ... }
    pub async fn run(&self, writer: &mut impl AsyncWrite) { ... }
}
```

Вставляется ДО первого frame'а в tls_write_loop. После `warmup_done = true` шейпинг отключается.

### Fix 7: Static fake HTTPS app-face

Новый модуль `crates/server/src/fakeapp.rs`:
- Роуты: `GET /`, `GET /favicon.ico`, `GET /robots.txt`, `GET /manifest.json`, `GET /api/v1/health`, `GET /api/v1/status`
- Каждый отдаёт правдоподобный content (HTML SPA bundle / PNG favicon / JSON health)
- Вызывается из h2_server.rs accept path когда приходит запрос БЕЗ правильного client cert ИЛИ без RBT POST

## crates/core/src/rbt.rs (новый файл)

RBT protocol definitions (shared между client и server):

```rust
pub const RBT_POST_PATH: &str = "/api/v1/telemetry";
pub const RBT_MAX_PAYLOAD: usize = 10 * 1024;  // 10 KB
pub const RBT_POOL_MIN: usize = 8;

pub fn rbt_pool_size() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get() * 2)
        .unwrap_or(RBT_POOL_MIN)
        .max(RBT_POOL_MIN)
}

// Wire format внутри chunked body:
//   [1B stream_idx][1B max_streams][frames...]
// Каждый frame:
//   [4B len][batch_plaintext]
```

## crates/client-common/src/rbt_client.rs (новый файл)

```rust
pub struct RbtPool {
    pool_size: usize,
    max_streams: usize,
    server_addr: String,
    tls_config: Arc<ClientConfig>,
    // outgoing frame channel shared между workers
    frame_rx: Receiver<Bytes>,
}

impl RbtPool {
    pub async fn run(self) -> Result<()> {
        // Спавним pool_size воркеров
        // Каждый worker цикл:
        //   1. TCP connect → TLS handshake → mTLS
        //   2. Отправить POST headers + [stream_idx][max_streams]
        //   3. Warmup (5 sec mimicry)
        //   4. Писать frames до RBT_MAX_PAYLOAD или until frame_rx empty
        //   5. Close chunked body, TLS close_notify
        //   6. Новый worker takes over
    }
}
```

## crates/client-linux/src/main.rs

Заменить текущий N_DATA_STREAMS spawn loop на `RbtPool::new(...).run()`. Остальной код (tun_uring, routing) остаётся.

## crates/client-android/src/lib.rs

Аналогично: RbtPool вместо ручного spawn. JNI ABI не меняется.

---

# 10 векторов детекции (что v0.18 лечит / НЕ лечит)

## Критичные — ЛЕЧИМ в v0.18
- 15-20KB TCP lockout ✅ (RBT)
- TLS+hammer heuristic ✅ (mimicry warmup)
- UDP/443 блок ✅ (TCP only)
- WireGuard magic byte ✅ (TLS outer)
- Shadowsocks entropy ✅ (настоящий TLS снаружи)
- Trojan active probing ✅ частично (качество fakeapp)
- IP↔DNS correlation ✅ (правильный DNS на tls.nl2.*)

## Критичные — НЕ лечим (план v0.19)
- **mTLS client cert fingerprint** — главная дыра. Реальные мобильные приложения не используют mTLS. Лечение: in-band auth (HMAC первых N байт payload).
- **Volume-to-IP anomaly** — 500 Mbit/s к одному IP = аномалия абонента. Лечение: multi-origin shard.
- **Connection-rate anomaly** — 6250 conn/sec при full throughput = аномалия. Trade-off со скоростью.
- **JA4 rustls fingerprint** — нужен utls-style spoof (rustls-uwu).
- **TLS handshake timing** — rustls слишком быстрый, реальный мобильный stack медленнее.

## Средние
- Traffic shape mismatch после warmup
- Absence of real app protocol (deep inspection через MITM)
- Parallel connection correlation (добавить jitter)
- ALPN должен быть h2, не http/1.1 (на данный момент h2 usable через H2 frames, но matrix предполагает H1 chunked — пересмотреть)
- User-Agent должен быть правдоподобный (okhttp/4.12.0)

---

# Прогноз comfort window

v0.18 = **3-9 месяцев комфорта** до того как ТСПУ введёт:
1. mTLS detection
2. Per-IP volume аномалия (на некоторых операторах уже есть)
3. Connection rate limiting
4. JA4 fingerprint на non-browser TLS

За это окно выкатить v0.19: in-band auth, utls, multi-origin.

---

# НЕ делать в v0.18
- Не переписывать на Go (bottleneck в syscalls и memcpy, не в GC)
- Не копировать REALITY (IP↔DNS correlation)
- Не копировать gRPC (legacy)
- Не использовать UDP (мёртво)
- Не трогать Android UI (JNI ABI стабилен)
