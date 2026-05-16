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

/// Default reconnect backoff schedule in seconds. Index = attempt-1 (after
/// the first drop). Tuned for "shaky network" conditions (mobile + TSPU):
/// fast initial recovery (1, 2, 5 s) so brief DPI shakes don't manifest as
/// long stalls, then back off to a 30 s ceiling. Step 5 (error categorisation)
/// supplies a category-specific override that may bypass this table entirely.
pub const BACKOFF_SECS: &[u32] = &[1, 2, 5, 10, 20, 30, 30, 30];

/// Maximum number of reconnect attempts before transitioning to Error.
pub const MAX_ATTEMPTS: u32 = 8;

/// RX idle timeout in seconds. When a tunnel stream goes this long without
/// any inbound bytes (data frame OR heartbeat), the read loop returns an
/// error and the supervisor triggers a reconnect. Heartbeat cadence is
/// ~20-30 s so 45 s gives a comfortable ~1.5×; smaller risks false trips
/// on legitimately quiet sessions, larger lets a half-open TCP socket
/// zombie for minutes under TSPU silent-drop conditions.
///
/// Used by `tls_rx_loop` in `client_common` when invoked from runtime.
pub const RX_IDLE_TIMEOUT_SECS: u32 = 45;

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
    /// `ENETUNREACH` / `EHOSTUNREACH` / no usable network at all. Long wait
    /// (we'll be woken by Android `NetworkCallback` anyway).
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

/// Best-effort error classifier. Walks the error string (already flattened
/// by `format!("{:#}", err)`) for known substrings. Order matters: more
/// specific first.
pub fn classify_tunnel_error(err_str: &str) -> TunnelErrorCategory {
    let s = err_str.to_ascii_lowercase();
    if s.contains("rx idle timeout") || s.contains("rx body timeout") {
        TunnelErrorCategory::IdleTimeout
    } else if s.contains("connection reset")
        || s.contains("broken pipe")
        || s.contains("connection aborted")
        || s.contains("unexpected eof")
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
/// number. Per-category overrides keep recovery fast on TSPU shakes; the
/// catch-all branch falls back to the standard exponential schedule.
pub fn reconnect_delay_secs(cat: TunnelErrorCategory, attempt: u32) -> u32 {
    match cat {
        TunnelErrorCategory::HardReset => 1,
        TunnelErrorCategory::IdleTimeout => 2,
        TunnelErrorCategory::DnsFailed => 3,
        TunnelErrorCategory::TlsAlert => 5,
        // No active network — wait long; the `NetworkCallback` wake will
        // cut sleep short via `cancel.notified()`.
        TunnelErrorCategory::NetworkUnreachable => 60,
        TunnelErrorCategory::Other => {
            BACKOFF_SECS.get(attempt as usize).copied().unwrap_or(30)
        }
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
    /// `NEPacketTunnelFlow` / Android `VpnService`) into the tunnel here.
    /// The channel is bounded (4096) — callers should `try_send` and drop
    /// on overflow.
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
/// The `JoinHandle` resolves when the supervisor exits (either after explicit
/// cancel or after exhausting all reconnect attempts).
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

    // Build TUN factory: called once per reconnect attempt.
    // For Callback mode we also build an inbound mpsc channel.
    // fd to close when supervisor exits (BlockingThreads only).
    let mut tun_fd_to_close: Option<RawFd> = None;

    let (tun_factory, inbound_tx): (supervise::TunFactory, tokio::sync::mpsc::Sender<Bytes>) =
        match tun {
            #[cfg(target_os = "linux")]
            TunIo::Uring(fd) => {
                // io_uring-based TUN — Linux helper / CLI.
                let factory: supervise::TunFactory = Arc::new(move || {
                    phantom_core::tun_uring::spawn(fd, 4096)
                });
                let (dummy_tx, _) = tokio::sync::mpsc::channel::<Bytes>(1);
                (factory, dummy_tx)
            }
            TunIo::BlockingThreads(fd) => {
                // Inline blocking-thread TUN I/O — works on Android and Linux.
                // We dup() the fd so it's owned independently of the JNI layer.
                let raw_fd = unsafe { libc::dup(fd) };
                anyhow::ensure!(raw_fd >= 0, "dup(tun_fd) failed: {}", std::io::Error::last_os_error());
                // Clear O_NONBLOCK — Android's ParcelFileDescriptor sets it,
                // but our reader thread needs blocking reads.
                unsafe {
                    let flags = libc::fcntl(raw_fd, libc::F_GETFL);
                    if flags >= 0 {
                        libc::fcntl(raw_fd, libc::F_SETFL, flags & !libc::O_NONBLOCK);
                    }
                }
                tun_fd_to_close = Some(raw_fd);
                tracing::info!(category = "tun", name = "blocking", mtu = 0, addr = "", tun_fd = raw_fd, "created");
                let factory: supervise::TunFactory = Arc::new(move || {
                    let (read_tx, read_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);
                    let (write_tx, mut write_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);
                    let tun_fd = raw_fd;
                    tracing::debug!(category = "tun", tun_fd, "factory spawning reader+writer");
                    // Reader thread: blocking libc::read → async channel
                    std::thread::spawn(move || {
                        tracing::debug!(category = "tun", tun_fd, "reader thread started");
                        let mut buf = vec![0u8; 4096];
                        loop {
                            let n = unsafe { libc::read(tun_fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                            if n <= 0 {
                                let err = std::io::Error::last_os_error();
                                tracing::error!(category = "tun", tun_fd, n, %err, "read failed");
                                break;
                            }
                            let pkt = Bytes::copy_from_slice(&buf[..n as usize]);
                            if read_tx.blocking_send(pkt).is_err() {
                                tracing::debug!(category = "tun", tun_fd, "reader: channel closed");
                                break;
                            }
                        }
                    });
                    // Writer thread: blocking_recv() → blocking libc::write on a
                    // dedicated OS thread (NOT tokio worker). Putting blocking
                    // syscalls inside `tokio::spawn` freezes a tokio worker on
                    // every TUN buffer-full and starves async tasks (TLS RX/TX,
                    // dispatcher) — see incident 2026-05-06. Partial-write loop
                    // + EINTR retry are required because the TUN fd is in
                    // blocking mode and large packets may not write atomically.
                    std::thread::spawn(move || {
                        tracing::debug!(category = "tun", tun_fd, "writer thread started");
                        while let Some(pkt) = write_rx.blocking_recv() {
                            let mut written = 0usize;
                            let len = pkt.len();
                            while written < len {
                                let n = unsafe {
                                    libc::write(
                                        tun_fd,
                                        pkt.as_ptr().add(written) as *const libc::c_void,
                                        len - written,
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
                                tracing::error!(category = "tun", tun_fd, n, %err, "write failed");
                                return;
                            }
                        }
                        tracing::debug!(category = "tun", tun_fd, "writer: channel closed");
                    });
                    Ok((read_rx, write_tx))
                });
                let (dummy_tx, _) = tokio::sync::mpsc::channel::<Bytes>(1);
                (factory, dummy_tx)
            }
            TunIo::Callback(io) => {
                // Callback mode — iOS NEPacketTunnelProvider.
                // Inbound: caller pushes into inbound_tx; we expose it via RuntimeHandles.
                // Outbound: packets from TLS are forwarded via io.submit_outbound_batch().
                let (inbound_tx, inbound_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);
                let inbound_rx = Arc::new(tokio::sync::Mutex::new(inbound_rx));
                let io = io.clone();
                let factory: supervise::TunFactory = Arc::new(move || {
                    let (write_tx, mut write_rx) =
                        tokio::sync::mpsc::channel::<Bytes>(4096);
                    let (read_tx, read_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);

                    // Forward outbound packets to the callback.
                    let io_clone = io.clone();
                    tokio::spawn(async move {
                        let mut batch = Vec::with_capacity(32);
                        while write_rx.recv_many(&mut batch, 32).await > 0 {
                            io_clone.submit_outbound_batch(std::mem::take(&mut batch));
                        }
                    });

                    // Forward inbound packets from the caller's push channel into read_rx.
                    let inbound_rx = inbound_rx.clone();
                    tokio::spawn(async move {
                        let mut rx = inbound_rx.lock().await;
                        while let Some(pkt) = rx.recv().await {
                            if read_tx.send(pkt).await.is_err() {
                                break;
                            }
                        }
                    });

                    Ok((read_rx, write_tx))
                });
                (factory, inbound_tx)
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
        // Close the dup'd TUN fd so Android can tear down the VPN interface.
        // Without this, the dup'd fd keeps the TUN device alive even after
        // VpnService closes its ParcelFileDescriptor.
        if let Some(fd) = tun_fd_to_close {
            tracing::info!(category = "tun", name = "blocking", tun_fd = fd, "torn_down");
            unsafe { libc::close(fd); }
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
