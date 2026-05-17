//! TUN I/O abstraction layer — lets the tunnel runtime work with different
//! platform-specific TUN implementations without caring about the details.

#[cfg(unix)]
use std::os::unix::io::RawFd;
use std::sync::Arc;
use bytes::Bytes;

/// Trait for platforms that deliver outbound packets via callback (e.g. iOS
/// `NEPacketTunnelFlow`). The runtime calls `submit_outbound_batch` when it
/// has received packets from the server that need to be written to the local
/// network stack.
pub trait PacketIo: Send + Sync {
    fn submit_outbound_batch(&self, pkts: Vec<Bytes>);
}

/// Blocking-style TUN packet I/O. The runtime drives this trait from a
/// dedicated pair of OS threads (one for each direction) so per-call
/// blocking is fine.
///
/// `read` returns one inbound packet (local stack → tunnel); `write`
/// accepts one outbound packet (tunnel → local stack).
///
/// Concrete impls: `WintunBackend` on Windows (`client-windows-core`),
/// `MockBackend` on any host for headless tests.
pub trait TunBackend: Send + Sync + 'static {
    /// Read one packet into `buf`. Two acceptable implementation patterns:
    ///
    /// * **Blocking** (preferred — used by Wintun): park the OS thread
    ///   until a packet arrives. Return `Err(io::ErrorKind::Other)` (or
    ///   any non-WouldBlock error) when `shutdown_hint` is called from
    ///   another thread, so the runtime's reader exits cleanly.
    /// * **Non-blocking** (used by MockBackend in tests): return
    ///   `Err(io::ErrorKind::WouldBlock)` when nothing is available.
    ///   The runtime sleeps ~10 ms and retries.
    fn read(&self, buf: &mut [u8]) -> std::io::Result<usize>;

    /// Write one outbound packet. Returns the number of bytes accepted.
    fn write(&self, packet: &[u8]) -> std::io::Result<usize>;

    /// Hint that the reader thread should wake up and exit. Default is a
    /// no-op; backends that block in `read()` (like Wintun's
    /// `receive_blocking`) must override this to unblock the reader so
    /// the runtime can shut down cleanly.
    ///
    /// Called by the runtime's supervise task ONCE after the supervisor
    /// loop exits. Safe to call multiple times — implementations should
    /// be idempotent.
    fn shutdown_hint(&self) {}
}

/// Platform TUN I/O variant. Determines how the runtime reads from / writes to
/// the local TUN interface.
pub enum TunIo {
    /// Linux with io_uring. Uses `phantom_core::tun_uring::spawn(fd, 4096)`.
    /// Suitable for Linux helper + CLI.
    #[cfg(target_os = "linux")]
    Uring(RawFd),
    /// Blocking-thread TUN I/O using libc read/write. Works on Android and Linux.
    /// Suitable for Android JNI where io_uring is unavailable.
    #[cfg(unix)]
    BlockingThreads(RawFd),
    /// iOS NEPacketTunnelProvider: inbound packets are pushed by the caller via
    /// the returned `RuntimeHandles::inbound_tx`; outbound packets are delivered
    /// via the `PacketIo::submit_outbound_batch` callback.
    Callback(Arc<dyn PacketIo>),
    /// Generic trait-object TUN backend. Used by Windows (Wintun) and by
    /// headless tests (MockBackend). Reader/writer threads in the runtime
    /// drive `TunBackend::read` / `::write` directly — no fd, no libc.
    Backend(Arc<dyn TunBackend>),
}
