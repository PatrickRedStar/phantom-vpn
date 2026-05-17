//! TUN backend abstraction.
//!
//! `TunBackend` is the trait the runtime drives to move packets in and out
//! of the local TUN adapter. On Windows the concrete impl wraps a Wintun
//! session; for headless tests on any host we ship `MockBackend` — a pair
//! of in-memory queues that lets us drive the full tunnel pipeline without
//! a real adapter.

use std::collections::VecDeque;
use std::io;
use std::sync::Arc;

use parking_lot::Mutex;

/// Blocking-style TUN packet I/O. `read` returns one inbound packet (from
/// the local network stack into the tunnel); `write` accepts one outbound
/// packet (from the tunnel back to the local stack). Both calls are
/// expected to be cheap and non-blocking from the runtime's point of view —
/// the runtime owns dedicated reader/writer threads that wrap each call.
pub trait TunBackend: Send + Sync + 'static {
    /// Read one packet into `buf`. Returns the number of bytes written.
    /// Implementations should block until a packet is available or return
    /// `io::ErrorKind::WouldBlock` so the caller can retry / cancel.
    fn read(&self, buf: &mut [u8]) -> io::Result<usize>;

    /// Write one outbound packet. Returns the number of bytes accepted.
    fn write(&self, packet: &[u8]) -> io::Result<usize>;
}

/// In-memory mock TUN. Used by `cargo test -p client-windows-core` on any
/// host (Mac, Linux, Windows). Packets pushed into `rx_queue` are surfaced
/// to the runtime via `read()`; packets the runtime writes are captured in
/// `tx_queue` for the test to assert on.
pub struct MockBackend {
    rx_queue: Arc<Mutex<VecDeque<Vec<u8>>>>,
    tx_queue: Arc<Mutex<VecDeque<Vec<u8>>>>,
}

impl MockBackend {
    pub fn new() -> Self {
        Self {
            rx_queue: Arc::new(Mutex::new(VecDeque::new())),
            tx_queue: Arc::new(Mutex::new(VecDeque::new())),
        }
    }

    /// Test helper: push a packet onto the inbound queue (simulates a
    /// packet that arrived on the local network stack and would normally
    /// land on the TUN adapter).
    pub fn push_rx(&self, packet: Vec<u8>) {
        self.rx_queue.lock().push_back(packet);
    }

    /// Test helper: drain the outbound queue (packets the runtime sent
    /// back into the local stack).
    pub fn drain_tx(&self) -> Vec<Vec<u8>> {
        self.tx_queue.lock().drain(..).collect()
    }
}

impl Default for MockBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl TunBackend for MockBackend {
    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        match self.rx_queue.lock().pop_front() {
            Some(pkt) => {
                let n = pkt.len().min(buf.len());
                buf[..n].copy_from_slice(&pkt[..n]);
                Ok(n)
            }
            None => Err(io::Error::new(io::ErrorKind::WouldBlock, "rx queue empty")),
        }
    }

    fn write(&self, packet: &[u8]) -> io::Result<usize> {
        self.tx_queue.lock().push_back(packet.to_vec());
        Ok(packet.len())
    }
}

// ── Wintun-backed implementation (Windows only) ────────────────────────────
//
// Phase 3 will fill in the body. For now we expose the struct under
// `cfg(windows)` so consumers can refer to the type even though there's no
// actual session yet — keeping the public surface stable across phases.

#[cfg(windows)]
pub struct WintunBackend {
    // session: wintun::Session,
}
