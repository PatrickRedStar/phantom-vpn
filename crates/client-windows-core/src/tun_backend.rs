//! TUN backend implementations.
//!
//! The `TunBackend` trait itself lives in `client-core-runtime` so the
//! tunnel runtime can drive any backend through a single Arc<dyn _>. This
//! module provides two concrete impls:
//!
//! * `WintunBackend` — production Wintun session (cfg(windows)).
//! * `MockBackend` — in-memory packet queues for headless tests on Mac/
//!   Linux/Windows. Used by `cargo test -p client-windows-core` and by any
//!   integration test that needs to drive the runtime without a real TUN.

use std::collections::VecDeque;
use std::io;
use std::sync::Arc;

use parking_lot::Mutex;

pub use client_core_runtime::TunBackend;

/// In-memory mock TUN. Packets pushed into `rx_queue` are surfaced to the
/// runtime via `read()`; packets the runtime writes are captured in
/// `tx_queue` for tests to assert on.
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

#[cfg(windows)]
pub use wintun_impl::{WintunBackend, WintunConfig};

#[cfg(windows)]
mod wintun_impl {
    use super::TunBackend;
    use std::io;
    use std::net::{IpAddr, Ipv4Addr};
    use std::path::{Path, PathBuf};
    use std::sync::Arc;

    use anyhow::{Context, Result};

    /// Configuration for the Wintun adapter, applied once at session start.
    /// Mirrors what `crates/client-linux/src/lib.rs` does via `ip route`
    /// on Linux — but Wintun takes IP/netmask/MTU directly via its API.
    #[derive(Debug, Clone)]
    pub struct WintunConfig {
        /// Display name of the virtual adapter as shown in "Network
        /// Connections" — e.g. "GhostStream".
        pub adapter_name: String,
        /// Tunnel-type label Wintun uses in driver metadata.
        pub tunnel_type: String,
        /// Path to the wintun.dll bundled with the binary. The
        /// `wintun_loader` module in `apps/windows/gui` resolves this from
        /// the .exe directory before constructing the backend.
        pub dll_path: PathBuf,
        /// TUN interior IP for the tunnel endpoint (typically 10.x.x.x).
        pub address: Ipv4Addr,
        /// Subnet mask for `address`. Default-route handling lives outside
        /// this backend (see `wintun_loader::install_default_route`).
        pub netmask: Ipv4Addr,
        /// MTU for the tunnel. GhostStream uses 1350 system-wide so TLS
        /// records fit one TCP segment under typical 1500-byte WAN MTUs.
        pub mtu: u16,
        /// DNS servers to push to the local resolver while connected.
        /// Pass empty if the user opts out of DNS routing.
        pub dns_servers: Vec<IpAddr>,
    }

    /// Production Wintun-backed `TunBackend`. Holds the loaded DLL handle,
    /// the adapter (kept alive for the lifetime of the session), and the
    /// session itself in an `Arc` so reader/writer threads in
    /// `client-core-runtime` can both reach it.
    pub struct WintunBackend {
        // Kept alive for the lifetime of the backend: dropping `_wintun`
        // unloads wintun.dll, which would invalidate `_adapter` and
        // `session` underneath us.
        _wintun: wintun::Wintun,
        _adapter: Arc<wintun::Adapter>,
        session: Arc<wintun::Session>,
    }

    impl WintunBackend {
        pub fn new(config: &WintunConfig) -> Result<Self> {
            Self::ensure_dll_present(&config.dll_path)?;
            // SAFETY: load_from_path is unsafe because the caller must
            // ensure the path points to a trustworthy DLL. The wintun
            // loader in `apps/windows/gui` resolves the path next to the
            // signed binary we ship, so the DLL is the one we bundled.
            let wintun = unsafe { wintun::load_from_path(&config.dll_path) }
                .with_context(|| format!("load wintun.dll from {}", config.dll_path.display()))?;

            // Prefer reusing an existing adapter with our name (clean
            // recovery after a hard exit that left the adapter behind);
            // create only if open fails.
            let adapter = match wintun::Adapter::open(&wintun, &config.adapter_name) {
                Ok(a) => a,
                Err(_) => wintun::Adapter::create(
                    &wintun,
                    &config.adapter_name,
                    &config.tunnel_type,
                    None,
                )
                .context("create wintun adapter")?,
            };

            adapter
                .set_address(config.address)
                .context("set adapter IP address")?;
            adapter
                .set_netmask(config.netmask)
                .context("set adapter netmask")?;
            adapter
                .set_mtu(config.mtu as usize)
                .context("set adapter MTU")?;
            if !config.dns_servers.is_empty() {
                adapter
                    .set_dns_servers(&config.dns_servers)
                    .context("set adapter DNS servers")?;
            }

            let session = Arc::new(
                adapter
                    .start_session(wintun::MAX_RING_CAPACITY)
                    .context("start wintun session")?,
            );

            tracing::info!(
                category = "tun",
                name = "wintun",
                adapter = %config.adapter_name,
                address = %config.address,
                mtu = config.mtu,
                "wintun adapter ready"
            );

            Ok(Self {
                _wintun: wintun,
                _adapter: adapter,
                session,
            })
        }

        /// Stop any in-flight `receive_blocking()` call. Drop alone would
        /// also stop the session, but explicit shutdown lets the runtime
        /// flush gracefully before tearing down the reader thread.
        pub fn shutdown(&self) -> Result<()> {
            self.session
                .shutdown()
                .context("wintun session shutdown")?;
            Ok(())
        }

        /// Win32 interface index of the underlying Wintun adapter — the
        /// argument every `netsh interface ip ... <idx> ...` invocation
        /// needs. Delegates straight to `wintun::Adapter::get_adapter_index`
        /// (wintun 0.5.1 caches the value at create/open time, so this
        /// call is effectively free).
        pub fn adapter_index(&self) -> Result<u32> {
            self._adapter
                .get_adapter_index()
                .map_err(|e| anyhow::anyhow!("get wintun adapter index: {e:?}"))
        }

        fn ensure_dll_present(path: &Path) -> Result<()> {
            if !path.exists() {
                anyhow::bail!(
                    "wintun.dll not found at {}. The DLL must be bundled \
                     next to ghoststream.exe — see wintun_loader.rs.",
                    path.display()
                );
            }
            Ok(())
        }
    }

    impl TunBackend for WintunBackend {
        fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
            // Use try_receive instead of receive_blocking so the runtime's
            // reader thread can periodically yield (the runtime sleeps
            // 10 ms on WouldBlock — see lib.rs Backend match arm). That
            // tradeoff costs ~10 ms of latency under no-traffic conditions
            // but avoids holding a thread inside a blocking syscall when
            // the runtime is shutting down.
            match self.session.try_receive() {
                Ok(Some(pkt)) => {
                    let bytes = pkt.bytes();
                    let n = bytes.len().min(buf.len());
                    buf[..n].copy_from_slice(&bytes[..n]);
                    Ok(n)
                }
                Ok(None) => Err(io::Error::new(io::ErrorKind::WouldBlock, "no packet")),
                Err(e) => Err(io::Error::new(io::ErrorKind::Other, format!("{e:?}"))),
            }
        }

        fn write(&self, packet: &[u8]) -> io::Result<usize> {
            let len = packet.len();
            if len == 0 {
                return Ok(0);
            }
            if len > u16::MAX as usize {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "packet larger than u16::MAX",
                ));
            }
            match self.session.allocate_send_packet(len as u16) {
                Ok(mut pkt) => {
                    pkt.bytes_mut().copy_from_slice(packet);
                    self.session.send_packet(pkt);
                    Ok(len)
                }
                Err(e) => Err(io::Error::new(io::ErrorKind::Other, format!("{e:?}"))),
            }
        }
    }
}
