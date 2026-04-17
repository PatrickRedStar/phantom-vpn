//! TUN I/O abstraction layer — lets the tunnel runtime work with different
//! platform-specific TUN implementations without caring about the details.

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

/// Platform TUN I/O variant. Determines how the runtime reads from / writes to
/// the local TUN interface.
pub enum TunIo {
    /// Linux with io_uring. Uses `phantom_core::tun_uring::spawn(fd, 4096)`.
    /// Suitable for Linux helper + CLI.
    Uring(RawFd),
    /// Linux without io_uring (or Android). Uses `phantom_core::tun_simple::spawn(fd, 4096)`.
    /// Suitable for Android JNI where io_uring is unavailable.
    BlockingThreads(RawFd),
    /// iOS NEPacketTunnelProvider: inbound packets are pushed by the caller via
    /// the returned `RuntimeHandles::inbound_tx`; outbound packets are delivered
    /// via the `PacketIo::submit_outbound_batch` callback.
    Callback(Arc<dyn PacketIo>),
}
