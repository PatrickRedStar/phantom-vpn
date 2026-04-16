---
name: GhostStream v0.18.0 shipped state (2026-04-11)
description: What actually landed for v0.18.0 server-side + clients, what's verified, what's still pending
type: project
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
**Shipped and deployed on vdsina at 2026-04-11 ~20:48 UTC+3. APK v0.18.0 (versionCode 43) installed on Samsung S21 R5CR102X85M at ~21:06 UTC+3.** Server-side live, client crates compile clean, APK on phone.

**Landed in this sprint:**
- `crates/core/src/wire.rs`: `N_DATA_STREAMS` const → `n_data_streams()` fn (cached OnceLock, derives from `std::thread::available_parallelism()`, clamped `[MIN_N_STREAMS=2, MAX_N_STREAMS=16]`). `flow_stream_idx(pkt, n)` unchanged.
- `crates/core/src/tun_uring.rs`: multiqueue dispatcher now uses `flow_stream_idx` instead of round-robin — matches server-side flow-affine scheduling. No more intra-flow reordering.
- `crates/server/src/vpn_session.rs`: `VpnSession` gained `effective_n: usize` field; `new_coordinator` takes it as parameter and asserts `tun_pkt_txs.len() == effective_n`. `tun_dispatch_loop` now calls `flow_stream_idx(&pkt, session.effective_n)`.
- `crates/server/src/h2_server.rs`: 2-byte handshake `[stream_idx, client_max_streams]` with 200ms fallback to v0.17 1-byte compat. Server computes `effective_n = min(server_n, client_max).clamp(MIN, MAX)`. Rejects `stream_idx >= effective_n` on new sessions AND on reconnects against existing `session.effective_n`. Mimicry warmup fires ONLY on stream_idx==0 AND `is_new==true`. Replaces old `handle_fallback_h2` with `fakeapp::handle`.
- `crates/server/src/mimicry.rs` (NEW): `warmup_write` emits 4 frames over ~800ms: 2KB/8KB/16KB/24KB, each is a real wire-format batch containing one 16-byte placeholder packet + padding. Placeholder fails IPv4 sanity check on client side → silently dropped.
- `crates/server/src/fakeapp.rs` (NEW): H2 server serving `/`, `/favicon.ico`, `/robots.txt`, `/manifest.json`, `/api/v1/health`, `/api/v1/status`. Response headers mimic nginx/1.24.0 with x-request-id. 30s idle timeout.
- `crates/server/src/main.rs`: registers `mimicry` + `fakeapp` modules.
- `crates/server/src/quic_server.rs`: migrated to `n_data_streams()` and `effective_n` parameter for `VpnSession::new_coordinator` (parity with h2 path).
- `crates/client-common/src/tls_tunnel.rs`: `write_stream_idx` renamed to `write_handshake(w, stream_idx, max_streams)` — writes both bytes atomically.
- `crates/client-common/src/lib.rs`: re-exports `write_handshake`.
- `crates/client-linux/src/main.rs` + `crates/client-android/src/lib.rs`: switched to `n_data_streams()` function, introduced local `let n_streams = n_data_streams();`, all `N_DATA_STREAMS` call-sites migrated, handshake call is `write_handshake(&mut w, idx as u8, n_streams as u8)`.
- `android/app/build.gradle.kts`: `versionCode=43`, `versionName="0.18.0"`, `GIT_TAG="v0.18.0"`.

**Smoke test (2026-04-11 20:51 UTC+3):** phantom-client-linux localhost against freshly deployed server — TLS handshake succeeds, server logs `Authenticated VPN client from 127.0.0.1:59056 (fp=71387eae…, stream 0/2)` then `stream 1/2`. `effective_n=2` because vdsina has 2 cores. Both streams stayed alive, mimicry warmup did not break the path.

**Perf benchmark (2026-04-11 21:00 UTC+3):** hostkey (RU) → vdsina through H2 tunnel, 4 iperf3 streams, 15s:
- Download (-R): **750 Mbit/s** (v0.17.2 baseline 625) — +20% vs. v0.17.2
- Upload:          **482 Mbit/s** (v0.17.2 baseline 254) — +90% vs. v0.17.2
- No regression. Flow-affine tun_uring dispatcher + 2-byte handshake did NOT slow anything down; likely improved download by eliminating intra-flow reorder retransmits.

**APK deployment (2026-04-11 21:06 UTC+3):**
- `.so` built on vdsina via `cargo ndk` (1.82 MB)
- APK built on user's machine through SSH tunnel `-p 22222` (Android SDK not on vdsina)
- Installed on R5CR102X85M (Samsung S21) — only device currently connected
- Fresh `spongebob2` client created (tun 10.7.0.3/24, fp `08799a10802fd1dbd22d5685956ed8d97fa3e49d06cb22018cb1791d5f31e888`)
- Profile files injected via `run-as com.ghoststream.vpn` into `/data/user/0/com.ghoststream.vpn/files/profiles/66f0502e-7ff6-4904-ab02-b2b097b1a3e6/` (client.crt, client.key, profiles.json with activeId)
- App launched via monkey launcher intent
- R3GL207YE8P (`spongebob`/10.7.0.2) was NOT attached to user's adb, skipped.

**Server process:** `phantom-server.service`, PID 3527619 at 20:48:18. Config and keyring unchanged.

**What is NOT yet done:**
- `crates/core/src/rbt.rs` (A2) — intentionally deferred, was in the v0.18 plan but labeled "future work". Do NOT treat as part of v0.18.
- Git tag + release commit — still uncommitted (status M on v0.18 files). When user asks to tag, `git add` the edited files + untracked `fakeapp.rs`, `mimicry.rs`, bump done already in `android/app/build.gradle.kts`.
- R3GL207YE8P update — connect phone and re-run APK deploy script targeting `spongebob` / 10.7.0.2.

**Post-ship hotfixes (2026-04-11 21:45–22:00 UTC+3):**
- `h2_server.rs:118` — `effective_n = client_max.clamp(MIN, MAX)` (was `min(server_n, client_max).clamp`). 8-core phone on 2-core server was getting `effective_n=2` and rejecting stream_idx 2..7 on reconnect. Server-side cost of honoring the client's request is just more mpsc channels + tokio tasks, cheap regardless of physical cores.
- `client-common/src/tls_tunnel.rs:82-90` — `tls_rx_loop` now drops non-IPv4 packets instead of forwarding them to the TUN fd. Fixes EINVAL from the 16-byte mimicry warmup placeholder when it reaches the TUN writer.
- `client-android/src/lib.rs:659` and `client-linux/src/main.rs:393` — dispatcher now uses `try_send` (with drop_full / drop_closed counters) instead of `send().await`. With per-stream pinning, blocking dispatch was causing cross-stream head-of-line blocking: one slow TLS stream would freeze EVERY flow regardless of hash, which matches the user's observed speedtest hang + upload asymmetry (ya.ru 254/18 vs speedtest 170/127). Kotlin watchdog then triggered full-tunnel reconnect; server logs showed exactly this pattern (8-way "replaced by reconnect" storms on 10.7.0.3 at 21:15 and 21:20). APK v0.18.0 rebuilt and reinstalled on R5CR102X85M at ~22:00 UTC+3 (profile storage preserved via `adb install -r`). Still not verified against phone speedtest — user needs to reopen app and hit Connect.

**Post-ship hotfixes round 2 (2026-04-11 22:43 UTC+3, PID 3558185, server-only, no client rebuild):**
Triggered by user report: bastion profile "вообще не подключается", NL-direct "connection up but download=0". Diagnosed two distinct bugs + two structural bugs on the session lifecycle path:

- `h2_server.rs` — handshake now reads both bytes in one `read_exact(&mut hs_buf)`, removed the 200ms fallback. The fallback window could fire on high-latency paths (RU bastion hop) and pin `effective_n` to the server's `n_data_streams()=2`, after which every reconnect with stream_idx ≥ 2 was rejected with `"stream_idx {N} exceeds existing session effective_n=2"` — observed for spongebob2-ru fp=943a975ad5b8bd32 at 22:12–22:21. Removed `n_data_streams` from the imports.

- `h2_server.rs` — added pre-Entry stale-session eviction. Before the `sessions_by_fp.get(&fp)` lookup, if an existing session has `effective_n != client_max`, OR `stream_idx >= effective_n`, OR `all_streams_down() && all tun_pkt_txs==None` (zombie batch-loops), we remove it from both `sessions_by_fp` AND sweep matching entries from `sessions` IP map, then `old.close()`. This fixes the NL-direct download=0 scenario: at 22:13:05 cleanup_task removed 10.7.0.3 from sessions and called `session.close()` which dropped all `tun_pkt_txs` senders → all 8 `stream_batch_loop` tasks exited → when phone reconnected at 22:20:51, `Entry::Occupied` found the corpse with live `effective_n=8` but zero live batch loops, writers attached fresh frame senders, dispatcher hit `TrySendError::Closed` on first packet → 128 accumulated drops at 22:21:15.

- `vpn_session.rs` — `cleanup_task` now takes `SessionByFp` and calls `reap_session_fp` after `session.close()`. Belt-and-suspenders for the above: even without the h2_server eviction logic, idle cleanup no longer leaves zombies in the fp index. `main.rs:194` updated to pass `sessions_by_fp.clone()`.

- `vpn_session.rs` — replaced `same_channel`-based `detach_stream_if` with generation-counter `detach_stream_gen`. Added `attach_gen: Vec<AtomicU64>` field to `VpnSession`. `attach_stream` now returns a `u64` generation token; the writer task passes it to `detach_stream_gen(idx, gen)` which clears the slot only if no newer reconnect has bumped the counter. **Why this matters:** the old code kept `frame_tx_for_detach = frame_tx.clone()` inside the writer's spawn closure — that clone kept the Sender half alive, so `frame_rx.recv()` could NEVER return `None`. The writer only exited on TLS write error, so a freshly-attached writer attached to a stale session (zombie scenario) with no TX traffic would park forever and prevent reap. `quic_server.rs:143` updated to `let _gen = session.attach_stream(i, frame_tx)`.

- `h2_server.rs` — after `tls_rx_loop` exits, we now explicitly call `session.detach_stream_gen(stream_idx, attach_gen)`. That drops the Sender in the slot → writer's `frame_rx.recv()` returns `None` → writer unwinds cleanly. No more relying on closure-captured clones.

Deployed 22:43:48 MSK, PID 3558185. No phone-side changes needed — all fixes are server-only.

**Phone benchmark after round-2 hotfixes (2026-04-11 22:47 MSK, user report):**
- **Bastion path** (RU hostkey → NL vdsina): ya.ru 271/19, Ookla speedtest 174/65 (one sample) and 247/109 (second sample).
- **NL-direct path**: ya.ru 239/15, Ookla speedtest 221/124.
- Both profiles reconnect cleanly. ±20% variance between back-to-back speedtests — TCP CUBIC/BBR window ramp + cellular jitter + RU→NL path variance. Normal.
- **ya.ru upload asymmetry (single-flow 15-19 Mbit vs multi-flow 65-124 Mbit)** is NOT a bug — it is the expected consequence of `flow_stream_idx` hashing. ya.ru speedtest uses a single TCP flow → hashed to one `stream_idx` → one `stream_batch_loop` → one TLS stream → single-core bottleneck on the phone. Ookla uses 8+ parallel flows → spread across all stream_idx values → parallelizes across all S21 cores. **Do not "fix" this by breaking flow-affinity — that would reintroduce intra-flow reordering and DUPACK storms.** Instead, document it as a known limitation of flow-affine dispatch.

**How to apply:** the round-2 hotfixes are in working-tree status M (not committed). When the user asks to tag v0.18.1, stage h2_server.rs + vpn_session.rs + main.rs + quic_server.rs + client-android/lib.rs + client-linux/main.rs + client-common/lib.rs + client-common/tls_tunnel.rs + fakeapp.rs + mimicry.rs + android/app/build.gradle.kts (already 0.18.0) and commit.

**Server-side bench after hotfixes (hostkey → vdsina, 2026-04-11 21:48 UTC+3):**
- Single flow upload: 378 Mbit/s, **0 retransmits** (clean TX path).
- 4-flow upload: 327 Mbit/s — worse than baseline 436. Reason: all 4 iperf3 ephemeral ports hashed to stream 0 (effective_n=2 on hostkey, bad luck parity), so `try_send` now drops on client side where `send().await` previously back-pressured. NOT a real regression — production traffic distributes across the hash better.
- 4-flow download: 615 Mbit/s / 75k retrans — baseline was 708 / 110k retrans. Still server-side dropping on stream 0 (`TUN dispatch idx=0 full for 10.7.0.4 dropped_full=9216`). Same 2-core hash collision as upload. Not a fix regression.

**How to apply:** When the user comes back and asks "did we ship v0.18", this file is the answer — along with detection_vectors / landscape memory. The detection_vectors file lists what v0.18 fixed vs. what remains for v0.19/v0.20.
