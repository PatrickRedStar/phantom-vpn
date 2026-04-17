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
//!     TunIo::Uring(3), // tun fd
//!     status_tx,
//!     log_tx,
//! ).await?;
//!
//! // Disconnect later:
//! handles.cancel.notify_waiters();
//! let _ = join.await;
//! # Ok(())
//! # }
//! ```

pub mod logsink;
pub mod supervise;
pub mod telemetry;
pub mod tun_io;

pub use ghoststream_gui_ipc::{
    ConnState, ConnectProfile, LogFrame, StatusFrame, TunnelSettings,
};
pub use telemetry::Telemetry;
pub use tun_io::{PacketIo, TunIo};

use std::sync::Arc;
use bytes::Bytes;
use tokio::sync::{watch, Mutex};

// ── Public constants ─────────────────────────────────────────────────────────

/// Backoff schedule in seconds. Index = attempt-1 (after the first drop).
pub const BACKOFF_SECS: &[u32] = &[3, 6, 12, 24, 48, 60, 60, 60];

/// Maximum number of reconnect attempts before transitioning to Error.
pub const MAX_ATTEMPTS: u32 = 8;

// ── RuntimeHandles ───────────────────────────────────────────────────────────

/// Handles returned by `run()` to control the live tunnel.
pub struct RuntimeHandles {
    /// Notify to trigger a graceful disconnect (wakes any pending backoff sleep
    /// and sets the shutdown flag on the live telemetry).
    pub cancel: Arc<tokio::sync::Notify>,
    /// For `TunIo::Callback` only: push inbound packets (from
    /// `NEPacketTunnelFlow` / Android `VpnService`) into the tunnel here.
    /// The channel is bounded (4096) — callers should `try_send` and drop
    /// on overflow.
    pub inbound_tx: tokio::sync::mpsc::Sender<Bytes>,
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
) -> anyhow::Result<(RuntimeHandles, tokio::task::JoinHandle<anyhow::Result<()>>)> {
    // Ensure the global tracing subscriber is installed.
    logsink::install();
    // Register the caller's log sink.
    logsink::add_sender(log_tx);

    // Build TUN factory: called once per reconnect attempt.
    // For Callback mode we also build an inbound mpsc channel.
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
                let factory: supervise::TunFactory = Arc::new(move || {
                    let (read_tx, read_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);
                    let (write_tx, mut write_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);
                    let tun_fd = raw_fd;
                    // Reader thread: blocking libc::read → async channel
                    std::thread::spawn(move || {
                        let mut buf = vec![0u8; 4096];
                        loop {
                            let n = unsafe { libc::read(tun_fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                            if n <= 0 { break; }
                            let pkt = Bytes::copy_from_slice(&buf[..n as usize]);
                            if read_tx.blocking_send(pkt).is_err() { break; }
                        }
                    });
                    // Writer task: async channel → blocking libc::write
                    tokio::spawn(async move {
                        while let Some(pkt) = write_rx.recv().await {
                            let ret = unsafe { libc::write(tun_fd, pkt.as_ptr() as *const libc::c_void, pkt.len()) };
                            if ret < 0 { break; }
                        }
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

    let cancel = Arc::new(tokio::sync::Notify::new());
    let shared_telem: Arc<Mutex<Option<Arc<Telemetry>>>> = Arc::new(Mutex::new(None));

    let supervisor_cancel = cancel.clone();
    let supervisor_telem = shared_telem.clone();
    let settings = cfg.settings.clone();

    let join = tokio::spawn(async move {
        supervise::supervise(
            cfg,
            settings,
            tun_factory,
            status_tx,
            supervisor_cancel,
            supervisor_telem,
        )
        .await;
        Ok(())
    });

    let handles = RuntimeHandles {
        cancel,
        inbound_tx,
    };
    Ok((handles, join))
}
