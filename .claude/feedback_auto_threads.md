---
name: Auto-detect CPU cores, never hardcode stream count
description: Any per-CPU parallelism (N_STREAMS, worker threads, TUN queues) must derive from std::thread::available_parallelism() at runtime, not a hardcoded constant
type: feedback
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
`N_DATA_STREAMS`, tokio worker count, TUN multiqueue count, и любой другой параметр, описывающий «сколько параллелизма держим» — должны **вычисляться из числа ядер на запускающем хосте**, а не хардкодиться.

**Why:** хосты разные — бывает 2-core KVM, бывает 16-core bare-metal. Хардкод `N_STREAMS=4` на 2-core VPS означает 4 TLS-декодера конкурируют за 2 ядра (замерил 2026-04-11: RX-path даёт 3.6 Mbit/s на 1% CPU вместо 11.6 на TX-path). Хардкод `N_STREAMS=4` на 8-core даёт впустую неиспользованные ядра.

**How to apply:**
- В `crates/core/src/wire.rs` `N_DATA_STREAMS` должно стать функцией (или runtime const через OnceLock) с формулой вроде `available_parallelism().min(config_cap).max(1)`.
- Клиент и сервер должны договориться о числе стримов в handshake (первый байт `stream_idx` уже есть) — либо сервер сообщает клиенту сколько слотов держать, либо обе стороны публикуют свои значения и берут `min`.
- Аналогично `tun_uring::spawn_multiqueue` — nproc кладётся в `n_queues` автоматически (это уже так делается в `main.rs:132-134`, хорошо).
- Не писать цифры в комментариях типа «4 parallel TCP connections» — описывать как «one stream per available core, capped by config».
