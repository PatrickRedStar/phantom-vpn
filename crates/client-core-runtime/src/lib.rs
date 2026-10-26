//! `client-core-runtime` — unified tunnel runtime for all GhostStream platforms.
//!
//! Extracts the tunnel pipeline (TLS connect, flow dispatch, telemetry,
//! reconnect supervision, log capture) from `apps/linux/helper` into a
//! single shared crate used by Linux, iOS, and Android.
//!
//! # Quick start
//!
//! ```no_run
//! use client_core_runtime::{run, TunIo, ConnectProfile, TunnelSettings};
//! use ghoststream_gui_ipc::StatusFrame;
//!
//! # async fn example() -> anyhow::Result<()> {
//! let (status_tx, _status_rx) = tokio::sync::watch::channel(StatusFrame::default());
//! let (log_tx, _log_rx) = tokio::sync::mpsc::channel(256);
//!
//! let profile = ConnectProfile {
//!     name: "my-profile".into(),
//!     conn_string: "ghs://...".into(),
//!     settings: TunnelSettings::default(),
//! };
//!
//! let (handles, join) = run(
//!     profile,
//!     TunIo::BlockingThreads(3), // tun fd
//!     status_tx,
//!     log_tx,
//!     None,                      // protect_socket — Linux/iOS pass None
//! ).await?;
//!
//! // Disconnect later:
//! let _ = handles.cancel.send(true);
//! let _ = join.await;
//! # Ok(())
//! # }
//! ```

pub mod log_bridge;
pub mod logsink;
pub mod supervise;
pub mod telemetry;
pub mod tun_io;

pub use ghoststream_gui_ipc::{
    ConnState, ConnectProfile, LogFrame, StatusFrame, TunnelSettings,
};
pub use telemetry::Telemetry;
pub use tun_io::{PacketIo, TunIo};

use std::os::unix::io::RawFd;
use std::sync::Arc;
use bytes::Bytes;
use tokio::sync::{watch, Mutex};

// ── Socket protection (Android VpnService.protect) ─────────────────────────

/// Callback to protect a raw TCP socket fd from VPN routing.
/// On Android, calls `VpnService.protect(fd)` via JNI so the socket
/// bypasses the TUN interface. Returns `true` on success.
/// Other platforms pass `None` (Linux uses RouteGuard, iOS routes
/// extension-sockets automatically).
pub type ProtectSocket = Arc<dyn Fn(RawFd) -> bool + Send + Sync>;

// ── Public constants ─────────────────────────────────────────────────────────

/// Reconnect backoff in seconds, indexed by consecutive failed attempts
/// (0-based). Fast initial recovery (1, 2, 5 s) so brief DPI shakes don't
/// become long stalls, then a 30 s ceiling — forever: with `auto_reconnect`
/// the runtime never gives up on network errors. The table is a floor under
/// the per-category delay (`reconnect_delay_secs`), so a fast category can't
/// turn a persistent failure into a reconnect storm. The counter resets after
/// a session that stayed up 30 s.
pub const BACKOFF_SECS: &[u32] = &[1, 2, 5, 10, 20, 30];

/// RX idle timeout in seconds — the dead-stream detector. When a stream goes
/// this long without any inbound frame (data OR heartbeat), its read loop
/// returns an error and the stream is reopened.
///
/// MUST stay well above `HEARTBEAT_INTERVAL_MAX_SECS` (60 s — the server's
/// maximum heartbeat gap, see `phantom_core::wire`) plus RTT and scheduling
/// slack: at zero margin a heartbeat landing a hair late killed perfectly live
/// but quiet streams (2026-06-13 TSPU incident, "streams dying one-by-one").
/// 90 s = 60 s heartbeat max + 30 s slack.
pub const RX_IDLE_TIMEOUT_SECS: u32 = 90;

/// Per-stream uplink queue and packet queue (TUN <-> runtime) capacities. The
/// iOS Network Extension is killed above ~50 MB, so its queues are shallower;
/// the stream count is not touched.
#[cfg(target_os = "ios")]
pub(crate) const STREAM_TX_QUEUE: usize = 256;
#[cfg(not(target_os = "ios"))]
pub(crate) const STREAM_TX_QUEUE: usize = 2048;
#[cfg(target_os = "ios")]
pub(crate) const PACKET_QUEUE: usize = 1024;
#[cfg(not(target_os = "ios"))]
pub(crate) const PACKET_QUEUE: usize = 4096;

/// Если ВСЕ стримы мертвы (alive == 0) на этот срок — teardown + reconnect.
/// v0.27.1: death-watcher реагирует ТОЛЬКО на alive==0 (B2 degraded-teardown
/// откатан — он генерировал synchronized N-stream reconnect-burst'ы, которые
/// carrier-DPI палит как VPN; см. pcap A/B vs v0.22.4). Единичный мёртвый стрим
/// НЕ рвёт сессию — его задача переоткрывает только его, со случайной паузой.
pub const ALL_STREAMS_DEAD_TIMEOUT_SECS: u32 = 3;

/// Coarse classification of a tunnel drop, used to pick the right reconnect
/// delay. v0.24.0: replaces the one-size-fits-all `BACKOFF_SECS` lookup
/// inside `should_reconnect`. The classifier is best-effort and matches
/// substrings of the `anyhow::Error` chain — good enough for logs + delay
/// shaping. Default to `Other` (table-based backoff) when nothing matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelErrorCategory {
    /// TCP/H2 abruptly reset — server alive, connection broken. Fast retry.
    HardReset,
    /// `tls_rx_loop` fired `rx.idle_timeout` — silent half-open. Fast retry.
    IdleTimeout,
    /// `ENETUNREACH` / `EHOSTUNREACH` / no usable network at all.
    NetworkUnreachable,
    /// TLS alert / handshake failure. Server may be under load — short wait.
    TlsAlert,
    /// DNS resolution failed. Short wait — likely just a transient.
    DnsFailed,
    /// Catch-all → use `BACKOFF_SECS` table indexed by attempt.
    Other,
}

impl TunnelErrorCategory {
    pub fn as_str(self) -> &'static str {
        match self {
            TunnelErrorCategory::HardReset => "hard_reset",
            TunnelErrorCategory::IdleTimeout => "idle_timeout",
            TunnelErrorCategory::NetworkUnreachable => "network_unreachable",
            TunnelErrorCategory::TlsAlert => "tls_alert",
            TunnelErrorCategory::DnsFailed => "dns_failed",
            TunnelErrorCategory::Other => "other",
        }
    }
}

/// Best-effort error classifier. Walks the error string — pass the whole
/// chain, `format!("{:#}", err)`; the top line alone is usually just "stream N
/// handshake failed" — for known substrings. Order matters: more specific
/// first.
pub fn classify_tunnel_error(err_str: &str) -> TunnelErrorCategory {
    let s = err_str.to_ascii_lowercase();
    if s.contains("rx idle timeout") || s.contains("rx body timeout") {
        TunnelErrorCategory::IdleTimeout
    } else if s.contains("connection reset")
        || s.contains("broken pipe")
        || s.contains("connection aborted")
        || s.contains("unexpected eof")
        || s.contains("early eof")
        || s.contains("woke from sleep")
    {
        TunnelErrorCategory::HardReset
    } else if s.contains("network is unreachable")
        || s.contains("no route to host")
        || s.contains("host is unreachable")
        || s.contains("network unreachable")
    {
        TunnelErrorCategory::NetworkUnreachable
    } else if s.contains("tls alert") || s.contains("handshake failure") || s.contains("certificate") {
        TunnelErrorCategory::TlsAlert
    } else if s.contains("dns") || s.contains("nodename nor servname") || s.contains("name resolution") {
        TunnelErrorCategory::DnsFailed
    } else {
        TunnelErrorCategory::Other
    }
}

/// Compute reconnect delay seconds for a given error category + attempt
/// number (consecutive failures, 0-based). The category sets how fast the
/// first retry is (ADR 0009: 1–2 s after a reset or a silent stream); the
/// `BACKOFF_SECS` table is the floor that grows to 30 s on repeated failure.
pub fn reconnect_delay_secs(cat: TunnelErrorCategory, attempt: u32) -> u32 {
    let first = match cat {
        TunnelErrorCategory::HardReset => 1,
        TunnelErrorCategory::IdleTimeout => 2,
        TunnelErrorCategory::DnsFailed => 3,
        TunnelErrorCategory::TlsAlert => 5,
        // No network: nothing tells the runtime it is back, so poll often.
        TunnelErrorCategory::NetworkUnreachable => 5,
        TunnelErrorCategory::Other => 1,
    };
    let floor = BACKOFF_SECS[(attempt as usize).min(BACKOFF_SECS.len() - 1)];
    first.max(floor)
}

/// Errors no retry can fix — the user has to act. Returns the human-readable
/// reason for `StatusFrame.last_error` (state `Error`); `None` = transient,
/// keep reconnecting. Pass the whole chain, `format!("{:#}", err)`.
///
/// A server rejecting our certificate answers with a TLS alert; under TLS 1.3
/// it arrives on the first read after the handshake, so stream errors are
/// checked too, not only the connect result.
///
/// Other certificate failures (unknown issuer, wrong name, a BadCertificate
/// alert) stay transient on purpose: a captive portal or a relay serving its
/// fallback certificate shows a foreign certificate until the network or the
/// relay is fixed, and the tunnel must come back by itself then.
pub fn fatal_reason(err_chain: &str) -> Option<&'static str> {
    let s = err_chain.to_ascii_lowercase();
    // rustls prints alerts as "received fatal alert: CertificateRevoked".
    if s.contains("certificaterevoked") || s.contains("accessdenied") || s.contains("certificate revoked") {
        Some("Доступ отозван")
    } else if s.contains("certificateexpired") {
        Some("Срок действия доступа истёк")
    } else if s.contains("certificate expired")
        || s.contains("certificate not valid yet")
        || s.contains("certificate: expired")
        || s.contains("certificate: notvalidyet")
        || s.contains("certificate has expired")
        || s.contains("certificate is not yet valid")
    {
        Some("Сертификат сервера недействителен на текущую дату — проверьте дату и время на устройстве")
    } else if s.contains("tun reader closed") {
        // TUN I/O is set up once per run(); its reader never comes back.
        Some("TUN-интерфейс закрыт")
    } else {
        None
    }
}

// ── RuntimeHandles ───────────────────────────────────────────────────────────

/// Handles returned by `run()` to control the live tunnel.
pub struct RuntimeHandles {
    /// Cancel signal: send `true` to trigger a graceful disconnect. Wakes any
    /// pending backoff sleep and sets the shutdown flag on the live telemetry.
    ///
    /// v0.25.1 (W3-2): a `watch::Sender<bool>` replaces the old `Arc<Notify>`
    /// — `Notify::notify_waiters()` only wakes tasks that are *already*
    /// suspended on `.notified()`. A cancel issued *between* the watcher
    /// arming itself and re-entering the `select!` is silently lost, which
    /// led to "press Disconnect, nothing happens for 45s" on Android. `watch`
    /// stores the latest value so a late observer still sees the signal.
    pub cancel: watch::Sender<bool>,
    /// For `TunIo::Callback` only: push inbound packets (from
    /// `NEPacketTunnelFlow`) into the tunnel here. The channel is bounded
    /// (`PACKET_QUEUE`) — callers should `try_send` and drop on overflow.
    pub inbound_tx: tokio::sync::mpsc::Sender<Bytes>,
}

/// Suspend until cancel signal arrives. Survives missed signals because
/// `watch` stores the latest value: if `true` was sent before this call,
/// we return immediately. Returns when the stored value becomes `true`
/// or when the sender drops.
///
/// v0.25.1 (W3-2): the helper exists because every supervise/drive_tunnel
/// `select!` arm needs the same "cancel can arrive at any point" semantics
/// and `watch::Receiver::changed()` alone misses the case where the
/// initial value already requested cancellation.
pub async fn wait_cancelled(cancel: &mut watch::Receiver<bool>) {
    loop {
        if *cancel.borrow() {
            return;
        }
        if cancel.changed().await.is_err() {
            return;
        }
    }
}

// ── run() ────────────────────────────────────────────────────────────────────

/// Start the tunnel runtime.
///
/// * Sets up TUN I/O according to `tun` variant.
/// * Registers `log_tx` with the global broadcast layer so log frames arrive
///   on the caller's channel (call `logsink::install()` once beforehand, or
///   this function will install it for you).
/// * Spawns the supervisor task and returns `(RuntimeHandles, JoinHandle)`.
///
/// The `JoinHandle` resolves when the supervisor exits: after an explicit
/// cancel, a fatal error, or a drop with `auto_reconnect` off.
pub async fn run(
    cfg: ConnectProfile,
    tun: TunIo,
    status_tx: watch::Sender<StatusFrame>,
    log_tx: tokio::sync::mpsc::Sender<LogFrame>,
    protect_socket: Option<ProtectSocket>,
) -> anyhow::Result<(RuntimeHandles, tokio::task::JoinHandle<anyhow::Result<()>>)> {
    // Ensure the global tracing subscriber is installed.
    logsink::install();
    // Evict stale senders from previous sessions to avoid duplicate log lines.
    logsink::clear_senders();
    // Register the caller's log sink.
    logsink::add_sender(log_tx);

    // TUN I/O is set up ONCE per run() for every variant and bridged to each
    // reconnect attempt by `per_attempt_factory`. A fresh reader per attempt
    // left the previous one blocked on the same fd: each packet woke only one
    // of them, so packets were sprayed across the live and the dead channel
    // (CRIT-2, v0.25.2 — and the same bug in the io_uring path).
    let mut blocking_threads: Option<BlockingTun> = None;
    let mut outbound_task: Option<tokio::task::JoinHandle<()>> = None;
    let (tun_factory, inbound_tx): (supervise::TunFactory, tokio::sync::mpsc::Sender<Bytes>) =
        match tun {
            #[cfg(target_os = "linux")]
            TunIo::Uring(fd) => {
                // io_uring-based TUN — Linux helper / CLI.
                let (read_rx, write_tx) = phantom_core::tun_uring::spawn(fd, PACKET_QUEUE)?;
                let (dummy_tx, _) = tokio::sync::mpsc::channel::<Bytes>(1);
                (per_attempt_factory(read_rx, write_tx), dummy_tx)
            }
            TunIo::BlockingThreads(fd) => {
                // Blocking-thread TUN I/O — Android (and Linux without io_uring).
                let (read_rx, write_tx, threads) = BlockingTun::spawn(fd)?;
                blocking_threads = Some(threads);
                let (dummy_tx, _) = tokio::sync::mpsc::channel::<Bytes>(1);
                (per_attempt_factory(read_rx, write_tx), dummy_tx)
            }
            TunIo::Callback(io) => {
                // Callback mode — iOS / macOS NEPacketTunnelProvider. Inbound:
                // the caller pushes into `inbound_tx` (RuntimeHandles).
                // Outbound: one persistent task hands packets to the callback;
                // it ends once the supervisor's senders are gone.
                let (inbound_tx, inbound_rx) = tokio::sync::mpsc::channel::<Bytes>(PACKET_QUEUE);
                let (write_tx, mut write_rx) = tokio::sync::mpsc::channel::<Bytes>(PACKET_QUEUE);
                outbound_task = Some(tokio::spawn(async move {
                    let mut batch = Vec::with_capacity(32);
                    while write_rx.recv_many(&mut batch, 32).await > 0 {
                        io.submit_outbound_batch(std::mem::take(&mut batch));
                    }
                }));
                (per_attempt_factory(inbound_rx, write_tx), inbound_tx)
            }
        };

    // v0.25.1 (W3-2): watch::channel(bool) replaces Arc<Notify>. The
    // supervisor takes the Receiver; `RuntimeHandles.cancel` exposes the
    // Sender to the caller. `false` = run, `true` = shut down.
    let (cancel_tx, cancel_rx) = watch::channel(false);
    let shared_telem: Arc<Mutex<Option<Arc<Telemetry>>>> = Arc::new(Mutex::new(None));

    let supervisor_telem = shared_telem.clone();
    let settings = cfg.settings.clone();

    let join = tokio::spawn(async move {
        let shutdown_started_at = std::time::Instant::now();
        // v0.26.19: cover-traffic warmup (W9) removed — эмпирически не помогал
        // против carrier DPI и добавлял ~3-9 s к latency подключения.
        supervise::supervise(
            cfg,
            settings,
            tun_factory,
            status_tx,
            cancel_rx,
            supervisor_telem,
            protect_socket,
        )
        .await;
        tracing::info!(category = "runtime", "shutdown.start");
        // The dup'd TUN fd must be closed before Android can tear the VPN
        // interface down — and only after both threads stopped using it.
        if let Some(threads) = blocking_threads {
            threads.stop().await;
        }
        // Callback mode: the outbound task ends once the supervisor's senders
        // are gone; wait for it, so no packet reaches the callback after this
        // join handle resolves.
        if let Some(task) = outbound_task {
            let _ = task.await;
        }
        let duration_ms = shutdown_started_at.elapsed().as_millis() as u64;
        tracing::info!(category = "runtime", duration_ms, "shutdown.complete");
        Ok(())
    });

    let handles = RuntimeHandles {
        cancel: cancel_tx,
        inbound_tx,
    };
    Ok((handles, join))
}

/// Bridge persistent TUN I/O to per-attempt channels. Only the inbound side
/// needs a forwarder — a receiver can't be shared between attempts — while
/// outbound packets go straight into the persistent writer (no extra hop).
fn per_attempt_factory(
    read_rx: tokio::sync::mpsc::Receiver<Bytes>,
    write_tx: tokio::sync::mpsc::Sender<Bytes>,
) -> supervise::TunFactory {
    let shared_read_rx = Arc::new(tokio::sync::Mutex::new(read_rx));
    let prev: Arc<parking_lot::Mutex<Option<tokio::task::JoinHandle<()>>>> =
        Arc::new(parking_lot::Mutex::new(None));
    Arc::new(move || {
        // Abort the previous attempt's forwarder BEFORE spawning a new one:
        // parked in `.recv().await`, it holds the shared receiver's lock and
        // would release it only on the next TUN packet — on an idle network,
        // exactly when reconnects happen, that could be never (FFI-C4).
        // Aborting releases the lock with the task.
        if let Some(h) = prev.lock().take() {
            h.abort();
        }
        let (attempt_read_tx, attempt_read_rx) = tokio::sync::mpsc::channel::<Bytes>(PACKET_QUEUE);
        let shared = shared_read_rx.clone();
        *prev.lock() = Some(tokio::spawn(async move {
            let mut guard = shared.lock().await;
            while let Some(pkt) = guard.recv().await {
                if attempt_read_tx.send(pkt).await.is_err() {
                    // Supervisor's receiver dropped — attempt is tearing down.
                    break;
                }
            }
        }));
        Ok((attempt_read_rx, write_tx.clone()))
    })
}

/// The two persistent OS threads behind `TunIo::BlockingThreads`.
///
/// Both share ownership of a dup of the caller's fd; it is closed when the
/// last of them exits — never while one of them may still read or write it
/// (a closed fd number can be reused by an unrelated open). The reader polls
/// with a timeout so it notices `stop` without needing the fd closed under it.
struct BlockingTun {
    stop: Arc<std::sync::atomic::AtomicBool>,
    threads: Vec<std::thread::JoinHandle<()>>,
}

impl BlockingTun {
    fn spawn(
        fd: RawFd,
    ) -> anyhow::Result<(
        tokio::sync::mpsc::Receiver<Bytes>,
        tokio::sync::mpsc::Sender<Bytes>,
        BlockingTun,
    )> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::sync::atomic::{AtomicBool, Ordering};

        // dup() so the fd is owned independently of the JNI layer.
        let raw_fd = unsafe { libc::dup(fd) };
        anyhow::ensure!(raw_fd >= 0, "dup(tun_fd) failed: {}", std::io::Error::last_os_error());
        // Clear O_NONBLOCK — Android's ParcelFileDescriptor sets it, but the
        // threads use blocking reads/writes.
        unsafe {
            let flags = libc::fcntl(raw_fd, libc::F_GETFL);
            if flags >= 0 {
                libc::fcntl(raw_fd, libc::F_SETFL, flags & !libc::O_NONBLOCK);
            }
        }
        let tun_fd = Arc::new(unsafe { OwnedFd::from_raw_fd(raw_fd) });
        tracing::info!(category = "tun", name = "blocking", mtu = 0, addr = "", tun_fd = raw_fd, "created");
        // Fresh tunnel, fresh observations — never show the previous
        // session's resolver next to a new tunnel.
        phantom_core::dns_observer::reset();

        let (read_tx, read_rx) = tokio::sync::mpsc::channel::<Bytes>(PACKET_QUEUE);
        let (write_tx, mut write_rx) = tokio::sync::mpsc::channel::<Bytes>(PACKET_QUEUE);
        let stop = Arc::new(AtomicBool::new(false));

        // FFI-H4 (v0.25.3): both spawns are fallible — under PID / thread cap
        // exhaustion `Builder::spawn` returns `io::Error`; a panic here would
        // abort the Apple/Android process (`panic = "abort"`).
        let reader_fd = tun_fd.clone();
        let reader_stop = stop.clone();
        let reader = std::thread::Builder::new()
            .name("phantom-tun-rd".into())
            .spawn(move || {
                let fd = reader_fd.as_raw_fd();
                tracing::debug!(category = "tun", tun_fd = fd, "reader thread started (persistent)");
                let mut buf = vec![0u8; 4096];
                while !reader_stop.load(Ordering::Relaxed) {
                    let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
                    let ready = unsafe { libc::poll(&mut pfd, 1, 500) };
                    if ready == 0 {
                        continue; // timeout — re-check `stop`
                    }
                    let n = if ready > 0 {
                        unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) }
                    } else {
                        -1
                    };
                    if n <= 0 {
                        let err = std::io::Error::last_os_error();
                        if n < 0 && err.raw_os_error() == Some(libc::EINTR) {
                            continue;
                        }
                        tracing::info!(category = "tun", tun_fd = fd, n, %err, "reader thread exiting");
                        break;
                    }
                    let pkt = &buf[..n as usize];
                    // Note where DNS is actually going. Header-only, no
                    // allocation — see dns_observer for why configuration
                    // is not a trustworthy answer to that question.
                    phantom_core::dns_observer::observe(pkt);
                    if read_tx.blocking_send(Bytes::copy_from_slice(pkt)).is_err() {
                        tracing::debug!(category = "tun", tun_fd = fd, "reader: channel closed");
                        break;
                    }
                }
            })
            .map_err(|e| anyhow::anyhow!("spawn tun reader thread: {}", e))?;

        // Writer: dedicated OS thread, NEVER `tokio::spawn` (blocking-on-tokio-
        // worker, incident 2026-05-06). Exits once every sender is dropped,
        // i.e. after the supervisor. Partial-write loop + EINTR retry.
        let writer_fd = tun_fd;
        let writer = std::thread::Builder::new()
            .name("phantom-tun-wr".into())
            .spawn(move || {
                let fd = writer_fd.as_raw_fd();
                tracing::debug!(category = "tun", tun_fd = fd, "writer thread started (persistent)");
                while let Some(pkt) = write_rx.blocking_recv() {
                    let mut written = 0usize;
                    while written < pkt.len() {
                        let n = unsafe {
                            libc::write(
                                fd,
                                pkt.as_ptr().add(written) as *const libc::c_void,
                                pkt.len() - written,
                            )
                        };
                        if n > 0 {
                            written += n as usize;
                            continue;
                        }
                        let err = std::io::Error::last_os_error();
                        if err.raw_os_error() == Some(libc::EINTR) {
                            continue;
                        }
                        // Keep draining — a single failed write doesn't mean
                        // every future one will fail, and stopping would
                        // back-pressure the forwarder.
                        tracing::error!(category = "tun", tun_fd = fd, n, %err, "write failed");
                        break;
                    }
                }
                tracing::debug!(category = "tun", tun_fd = fd, "writer: channel closed");
            });
        let writer = match writer {
            Ok(w) => w,
            Err(e) => {
                stop.store(true, Ordering::Relaxed);
                anyhow::bail!("spawn tun writer thread: {}", e);
            }
        };

        Ok((read_rx, write_tx, BlockingTun { stop, threads: vec![reader, writer] }))
    }

    /// Stop the reader (it re-checks `stop` at least every 500 ms) and wait for
    /// both threads; the writer exits once the supervisor's senders are gone.
    /// The fd is closed when the last thread drops it.
    async fn stop(self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let threads = self.threads;
        let _ = tokio::task::spawn_blocking(move || {
            for t in threads {
                let _ = t.join();
            }
        })
        .await;
        tracing::info!(category = "tun", name = "blocking", "torn_down");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::UnixTime;
    use rustls::{AlertDescription, CertificateError, Error as TlsError};
    use std::time::Duration;

    /// The chain as the supervisor sees it: our context on top, the rustls
    /// error at the bottom (tokio-rustls wraps it in an io::Error).
    fn chain(e: TlsError) -> String {
        let io = std::io::Error::new(std::io::ErrorKind::InvalidData, e);
        format!("{:#}", anyhow::Error::new(io).context("stream 0 tls connect"))
    }

    #[test]
    fn fatal_reasons_match_real_rustls_errors() {
        let revoked = chain(TlsError::AlertReceived(AlertDescription::CertificateRevoked));
        assert_eq!(fatal_reason(&revoked), Some("Доступ отозван"));
        let denied = chain(TlsError::AlertReceived(AlertDescription::AccessDenied));
        assert_eq!(fatal_reason(&denied), Some("Доступ отозван"));

        let t = |s| UnixTime::since_unix_epoch(Duration::from_secs(s));
        for e in [
            CertificateError::Expired,
            CertificateError::NotValidYet,
            CertificateError::ExpiredContext { time: t(2_000), not_after: t(1_000) },
            CertificateError::NotValidYetContext { time: t(1_000), not_before: t(2_000) },
        ] {
            let reason = fatal_reason(&chain(TlsError::InvalidCertificate(e))).unwrap();
            assert!(reason.contains("дату и время"), "{reason}");
        }
        assert_eq!(fatal_reason("TUN reader closed — TX path gone"), Some("TUN-интерфейс закрыт"));

        // A foreign server certificate (captive portal, relay fallback) and
        // other handshake trouble are retried, not fatal.
        for e in [
            TlsError::InvalidCertificate(CertificateError::UnknownIssuer),
            TlsError::InvalidCertificate(CertificateError::NotValidForName),
            TlsError::AlertReceived(AlertDescription::BadCertificate),
            TlsError::AlertReceived(AlertDescription::HandshakeFailure),
        ] {
            assert_eq!(fatal_reason(&chain(e)), None);
        }

        // Network trouble is never fatal.
        for transient in [
            "stream 0 tcp connect: Connection refused (os error 61)",
            "TLS read header: connection reset by peer",
            "rx idle timeout: no data for 90s",
            "DNS lookup timeout for relay.example:443",
            "all streams dead (tcp_reset)",
            "device woke from sleep",
        ] {
            assert_eq!(fatal_reason(transient), None, "{transient}");
        }
    }

    /// Fast first retry per category, growing to the 30 s ceiling, never
    /// beyond — and there is no attempt after which it stops.
    #[test]
    fn reconnect_delay_escalates_to_30s_and_stays() {
        use TunnelErrorCategory::*;
        assert_eq!(reconnect_delay_secs(HardReset, 0), 1);
        assert_eq!(reconnect_delay_secs(IdleTimeout, 0), 2);
        assert_eq!(reconnect_delay_secs(NetworkUnreachable, 0), 5);
        for cat in [HardReset, IdleTimeout, NetworkUnreachable, TlsAlert, DnsFailed, Other] {
            let mut prev = 0;
            for attempt in 0..1_000 {
                let d = reconnect_delay_secs(cat, attempt);
                assert!(d >= prev && d <= 30);
                prev = d;
            }
            assert_eq!(prev, 30);
        }
        assert_eq!(classify_tunnel_error("x: device woke from sleep"), HardReset);
        assert_eq!(
            classify_tunnel_error("stream 3 handshake failed: TLS read header: early eof"),
            HardReset
        );
    }
}
