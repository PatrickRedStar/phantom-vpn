//! phantom-client-apple: iOS/macOS FFI bindings for GhostStream.
//!
//! Exposes the platform-agnostic client-common tunnel logic to Swift via plain
//! C FFI. Designed to be embedded in an `NEPacketTunnelProvider` extension:
//!
//! - Swift reads IP packets from `packetFlow` and pushes each into Rust via
//!   [`phantom_submit_outbound`].
//! - Rust registers a callback via [`phantom_set_inbound_callback`]; the
//!   callback is invoked for each decoded inbound IP packet, which Swift then
//!   hands back to `packetFlow.writePackets(...)`.
//!
//! Unlike the Android crate, this one does NOT touch a TUN file descriptor,
//! does NOT call a platform-specific `protect()` on sockets (iOS routes
//! extension-sockets around the VPN automatically), and does NOT use JNI.
//!
//! All strings returned from this library are heap-allocated `CString` values
//! transferred via `CString::into_raw`. The caller MUST free them exactly once
//! via [`phantom_free_string`]. Passing any other pointer to that function, or
//! double-freeing, is undefined behavior.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;

use bytes::Bytes;
use once_cell::sync::OnceCell;
use parking_lot::{Mutex, RwLock};
use serde::Deserialize;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};

// ─── Ring-buffer log layer ───────────────────────────────────────────────────

#[derive(Clone)]
struct LogEntryData {
    seq: u64,
    ts_secs: u64,
    level: &'static str,
    msg: String,
}

static LOG_SEQ: AtomicU64 = AtomicU64::new(0);
static LOG_BUFFER: Mutex<std::collections::VecDeque<LogEntryData>> =
    Mutex::new(std::collections::VecDeque::new());
static LOG_BUFFER_BYTES: AtomicU64 = AtomicU64::new(0);

// 1=error, 2=warn, 3=info (default), 4=debug, 5=trace
static LOG_LEVEL: AtomicU8 = AtomicU8::new(3);

const LOG_BUFFER_CAP_BYTES: u64 = 10 * 1024 * 1024;

fn level_u8(level: &tracing::Level) -> u8 {
    match *level {
        tracing::Level::ERROR => 1,
        tracing::Level::WARN => 2,
        tracing::Level::INFO => 3,
        tracing::Level::DEBUG => 4,
        tracing::Level::TRACE => 5,
    }
}

fn level_str(level: &tracing::Level) -> &'static str {
    match *level {
        tracing::Level::ERROR => "ERROR",
        tracing::Level::WARN => "WARN",
        tracing::Level::INFO => "INFO",
        tracing::Level::DEBUG => "DEBUG",
        tracing::Level::TRACE => "TRACE",
    }
}

/// tracing_subscriber::Layer that captures each event into the ring buffer.
/// Gating against LOG_LEVEL happens inside `on_event` — we install the
/// subscriber once at TRACE level and filter by our atomic afterwards so
/// `phantom_set_log_level` does not require rebuilding the subscriber.
struct RingLayer;

struct MsgVisitor {
    out: String,
}

impl tracing::field::Visit for MsgVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            if !self.out.is_empty() {
                self.out.push(' ');
            }
            let _ = std::fmt::write(&mut self.out, format_args!("{:?}", value));
        } else {
            if !self.out.is_empty() {
                self.out.push(' ');
            }
            let _ = std::fmt::write(
                &mut self.out,
                format_args!("{}={:?}", field.name(), value),
            );
        }
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            if !self.out.is_empty() {
                self.out.push(' ');
            }
            self.out.push_str(value);
        } else {
            if !self.out.is_empty() {
                self.out.push(' ');
            }
            let _ = std::fmt::write(
                &mut self.out,
                format_args!("{}={}", field.name(), value),
            );
        }
    }
}

impl<S> tracing_subscriber::Layer<S> for RingLayer
where
    S: tracing::Subscriber,
{
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let metadata = event.metadata();
        let evt_level = level_u8(metadata.level());
        if evt_level > LOG_LEVEL.load(Ordering::Relaxed) {
            return;
        }

        let mut visitor = MsgVisitor { out: String::new() };
        event.record(&mut visitor);

        let entry = LogEntryData {
            seq: LOG_SEQ.fetch_add(1, Ordering::Relaxed),
            ts_secs: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            level: level_str(metadata.level()),
            msg: visitor.out,
        };

        let mut buf = LOG_BUFFER.lock();
        let entry_bytes = entry.msg.len() as u64 + 64;
        buf.push_back(entry);
        LOG_BUFFER_BYTES.fetch_add(entry_bytes, Ordering::Relaxed);
        while LOG_BUFFER_BYTES.load(Ordering::Relaxed) > LOG_BUFFER_CAP_BYTES {
            if let Some(old) = buf.pop_front() {
                LOG_BUFFER_BYTES.fetch_sub(old.msg.len() as u64 + 64, Ordering::Relaxed);
            } else {
                break;
            }
        }
    }
}

static LOGGER_INIT: OnceCell<()> = OnceCell::new();

fn init_logger() {
    LOGGER_INIT.get_or_init(|| {
        use tracing_subscriber::prelude::*;
        // Install at TRACE unconditionally — our RingLayer filters on
        // LOG_LEVEL so callers can raise/lower verbosity without rebuilding.
        let subscriber = tracing_subscriber::registry()
            .with(tracing_subscriber::filter::LevelFilter::TRACE)
            .with(RingLayer);
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

// ─── Stats counters ──────────────────────────────────────────────────────────

static BYTES_RX: AtomicU64 = AtomicU64::new(0);
static BYTES_TX: AtomicU64 = AtomicU64::new(0);
static PKTS_RX: AtomicU64 = AtomicU64::new(0);
static PKTS_TX: AtomicU64 = AtomicU64::new(0);
static IS_CONNECTED: AtomicBool = AtomicBool::new(false);

fn reset_stats() {
    BYTES_RX.store(0, Ordering::Relaxed);
    BYTES_TX.store(0, Ordering::Relaxed);
    PKTS_RX.store(0, Ordering::Relaxed);
    PKTS_TX.store(0, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
}

// ─── Inbound callback registry ───────────────────────────────────────────────

/// Swift-provided C callback invoked for every IP packet the tunnel decodes.
/// The pointer-to-bytes is only valid for the duration of the call — Swift
/// must copy before returning if it needs to retain.
type InboundCb = extern "C" fn(*const u8, usize, *mut c_void);

struct CbSlot {
    cb: Option<InboundCb>,
    ctx: *mut c_void,
}

// SAFETY: the `ctx` pointer is an opaque handle owned by Swift. The Swift
// contract: the caller that registers the callback guarantees the ctx remains
// valid until they register a different callback (or null). Rust treats it as
// an opaque bag of bits and only passes it back unchanged.
unsafe impl Send for CbSlot {}
unsafe impl Sync for CbSlot {}

static INBOUND_CB: RwLock<CbSlot> = RwLock::new(CbSlot {
    cb: None,
    ctx: std::ptr::null_mut(),
});

fn invoke_inbound(pkt: &[u8]) {
    let guard = INBOUND_CB.read();
    if let Some(cb) = guard.cb {
        cb(pkt.as_ptr(), pkt.len(), guard.ctx);
    }
}

// ─── Tokio runtime singleton ─────────────────────────────────────────────────

static RUNTIME: OnceCell<Runtime> = OnceCell::new();

fn runtime() -> Option<&'static Runtime> {
    RUNTIME
        .get_or_try_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(6)
                .thread_name("phantom-apple")
                .build()
        })
        .ok()
}

// ─── Tunnel handle ───────────────────────────────────────────────────────────

struct TunnelHandle {
    shutdown_tx: Option<oneshot::Sender<()>>,
    tun_packet_tx: mpsc::Sender<Bytes>,
    shutdown_flag: Arc<AtomicBool>,
}

static TUNNEL: Mutex<Option<TunnelHandle>> = Mutex::new(None);

// ─── Start config ────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct StartConfig {
    server_addr: String,
    server_name: String,
    #[serde(default)]
    insecure: bool,
    cert_pem: String,
    key_pem: String,
    #[serde(default)]
    ca_cert_pem: Option<String>,
}

// ─── Error codes ─────────────────────────────────────────────────────────────

const ERR_BAD_CONFIG: i32 = -1;
const ERR_ALREADY_RUNNING: i32 = -2;
const ERR_BAD_IDENTITY: i32 = -3;
const ERR_RUNTIME_INIT: i32 = -4;
const ERR_TLS_CONFIG: i32 = -5;
const ERR_QUEUE_FULL: i32 = -10;
const ERR_NO_TUNNEL: i32 = -11;
const ERR_PANIC: i32 = -99;

// ─── phantom_start ───────────────────────────────────────────────────────────

/// Start the tunnel. `config_json` is a JSON object:
/// `{"server_addr":"...","server_name":"...","insecure":bool,`
/// ` "cert_pem":"...","key_pem":"...","ca_cert_pem":"..."|null}`
///
/// Returns 0 on success, negative on error.
#[no_mangle]
pub extern "C" fn phantom_start(config_json: *const c_char) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        init_logger();

        if config_json.is_null() {
            return ERR_BAD_CONFIG;
        }
        let cfg_str = match unsafe { CStr::from_ptr(config_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                tracing::error!("phantom_start: config_json not UTF-8");
                return ERR_BAD_CONFIG;
            }
        };
        let cfg: StartConfig = match serde_json::from_str(cfg_str) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("phantom_start: bad config JSON: {}", e);
                return ERR_BAD_CONFIG;
            }
        };

        // Guard against double-start.
        {
            let g = TUNNEL.lock();
            if g.is_some() {
                tracing::warn!("phantom_start: tunnel already running");
                return ERR_ALREADY_RUNNING;
            }
        }

        reset_stats();

        // Ignored if already installed (likely on reconnect).
        let _ = rustls::crypto::ring::default_provider().install_default();

        // Parse cert + key.
        let client_identity = match phantom_core::tls::parse_pem_identity(
            cfg.cert_pem.as_bytes(),
            cfg.key_pem.as_bytes(),
        ) {
            Ok(id) => Some(id),
            Err(e) => {
                tracing::error!("phantom_start: bad client identity: {}", e);
                return ERR_BAD_IDENTITY;
            }
        };

        // Parse optional CA.
        let server_ca = match cfg.ca_cert_pem.as_deref() {
            Some(pem) if !pem.is_empty() => {
                match phantom_core::tls::parse_pem_cert_chain(pem.as_bytes()) {
                    Ok(c) => Some(c),
                    Err(e) => {
                        tracing::warn!(
                            "phantom_start: invalid ca_cert_pem, falling back to system roots: {}",
                            e
                        );
                        None
                    }
                }
            }
            _ => None,
        };

        let rt = match runtime() {
            Some(r) => r,
            None => {
                tracing::error!("phantom_start: failed to init tokio runtime");
                return ERR_RUNTIME_INIT;
            }
        };

        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let (tun_packet_tx, tun_packet_rx) = mpsc::channel::<Bytes>(8192);
        let shutdown_flag = Arc::new(AtomicBool::new(false));

        let server_addr = cfg.server_addr.clone();
        let server_name = cfg.server_name.clone();
        let insecure = cfg.insecure;
        let sf = shutdown_flag.clone();

        rt.spawn(async move {
            tracing::info!(
                "Tunnel starting: server={} sni={} insecure={}",
                server_addr,
                server_name,
                insecure
            );
            if let Err(e) = run_tunnel(
                &server_addr,
                &server_name,
                insecure,
                server_ca,
                client_identity,
                tun_packet_rx,
                shutdown_rx,
                sf,
            )
            .await
            {
                tracing::error!("Tunnel error: {:#}", e);
            }
            IS_CONNECTED.store(false, Ordering::Relaxed);
            tracing::info!("Tunnel stopped");
        });

        *TUNNEL.lock() = Some(TunnelHandle {
            shutdown_tx: Some(shutdown_tx),
            tun_packet_tx,
            shutdown_flag,
        });
        0
    }))
    .unwrap_or_else(|_| {
        tracing::error!("phantom_start: panic caught at FFI boundary");
        ERR_PANIC
    })
}

// ─── phantom_stop ────────────────────────────────────────────────────────────

/// Signal the running tunnel to shut down. Non-blocking beyond a brief yield
/// to let the abort propagate. Subsequent `phantom_start` calls reuse the
/// same tokio runtime.
#[no_mangle]
pub extern "C" fn phantom_stop() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        IS_CONNECTED.store(false, Ordering::Relaxed);

        let handle = TUNNEL.lock().take();
        if let Some(mut h) = handle {
            h.shutdown_flag.store(true, Ordering::Relaxed);
            if let Some(tx) = h.shutdown_tx.take() {
                let _ = tx.send(());
            }
            drop(h.tun_packet_tx);
            tracing::info!("phantom_stop: shutdown signalled");
        }

        // Brief yield so the spawned task sees the shutdown before we return.
        std::thread::sleep(std::time::Duration::from_millis(50));
    }));
}

// ─── phantom_submit_outbound ─────────────────────────────────────────────────

/// Submit an outbound IP packet read from `NEPacketTunnelProvider.packetFlow`.
/// Returns 0 on accept, -10 on queue full (packet dropped), -11 if no tunnel
/// is running, -1 on bad pointer/len.
#[no_mangle]
pub extern "C" fn phantom_submit_outbound(ptr: *const u8, len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if ptr.is_null() || len == 0 {
            return ERR_BAD_CONFIG;
        }
        // Defensive cap — matches BATCH_MAX_PLAINTEXT ceiling, IP packets
        // should never exceed ~2 KB on our MTU=1350 TUN.
        if len > phantom_core::wire::BATCH_MAX_PLAINTEXT {
            tracing::warn!("phantom_submit_outbound: oversized packet {} bytes", len);
            return ERR_BAD_CONFIG;
        }

        let sender = {
            let g = TUNNEL.lock();
            match g.as_ref() {
                Some(h) => h.tun_packet_tx.clone(),
                None => return ERR_NO_TUNNEL,
            }
        };

        let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
        let pkt = Bytes::copy_from_slice(slice);

        BYTES_TX.fetch_add(len as u64, Ordering::Relaxed);
        PKTS_TX.fetch_add(1, Ordering::Relaxed);

        match sender.try_send(pkt) {
            Ok(()) => 0,
            Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => ERR_QUEUE_FULL,
            Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => ERR_NO_TUNNEL,
        }
    }))
    .unwrap_or(ERR_PANIC)
}

// ─── phantom_set_inbound_callback ────────────────────────────────────────────

/// Register a C callback that Rust will invoke for each inbound IP packet
/// decoded from the TLS streams. Pass `cb=None` to clear.
///
/// The `ctx` pointer is stored and passed back verbatim. The caller must keep
/// it valid until a subsequent call replaces it.
#[no_mangle]
pub extern "C" fn phantom_set_inbound_callback(
    cb: Option<extern "C" fn(*const u8, usize, *mut c_void)>,
    ctx: *mut c_void,
) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut slot = INBOUND_CB.write();
        slot.cb = cb;
        slot.ctx = ctx;
    }));
}

// ─── phantom_get_stats ───────────────────────────────────────────────────────

/// Returns a newly-allocated JSON string:
/// `{"bytes_rx":N,"bytes_tx":N,"pkts_rx":N,"pkts_tx":N,"connected":bool}`.
/// Caller must free via `phantom_free_string`.
#[no_mangle]
pub extern "C" fn phantom_get_stats() -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let json = format!(
            r#"{{"bytes_rx":{},"bytes_tx":{},"pkts_rx":{},"pkts_tx":{},"connected":{}}}"#,
            BYTES_RX.load(Ordering::Relaxed),
            BYTES_TX.load(Ordering::Relaxed),
            PKTS_RX.load(Ordering::Relaxed),
            PKTS_TX.load(Ordering::Relaxed),
            IS_CONNECTED.load(Ordering::Relaxed),
        );
        CString::new(json)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }))
    .unwrap_or(std::ptr::null_mut())
}

// ─── phantom_get_logs ────────────────────────────────────────────────────────

/// Returns a JSON array of log entries with `seq > since_seq`. Pass -1 to
/// get everything in the ring buffer.
/// Shape: `[{"seq":N,"ts":"HH:MM:SS","level":"INFO","msg":"..."}]`.
/// Caller must free via `phantom_free_string`.
#[no_mangle]
pub extern "C" fn phantom_get_logs(since_seq: i64) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let entries: Vec<String> = {
            let buf = LOG_BUFFER.lock();
            buf.iter()
                .filter(|e| (e.seq as i64) > since_seq)
                .map(|e| {
                    let (h, m, s) = {
                        let epoch = e.ts_secs as libc::time_t;
                        let mut tm: libc::tm = unsafe { std::mem::zeroed() };
                        unsafe {
                            libc::localtime_r(&epoch, &mut tm);
                        }
                        (tm.tm_hour as u64, tm.tm_min as u64, tm.tm_sec as u64)
                    };
                    let escaped_msg =
                        serde_json::to_string(&e.msg).unwrap_or_else(|_| "\"\"".to_string());
                    format!(
                        r#"{{"seq":{},"ts":"{:02}:{:02}:{:02}","level":"{}","msg":{}}}"#,
                        e.seq, h, m, s, e.level, escaped_msg,
                    )
                })
                .collect()
        };
        let json = format!("[{}]", entries.join(","));
        CString::new(json)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }))
    .unwrap_or(std::ptr::null_mut())
}

// ─── phantom_set_log_level ───────────────────────────────────────────────────

/// Accepts "trace", "debug", "info", "warn", "error" (case-insensitive).
/// Unknown strings reset to "info".
#[no_mangle]
pub extern "C" fn phantom_set_log_level(level: *const c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        init_logger();
        if level.is_null() {
            LOG_LEVEL.store(3, Ordering::Relaxed);
            return;
        }
        let s = match unsafe { CStr::from_ptr(level) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                LOG_LEVEL.store(3, Ordering::Relaxed);
                return;
            }
        };
        let v = match s.to_lowercase().as_str() {
            "trace" => 5,
            "debug" => 4,
            "info" => 3,
            "warn" => 2,
            "error" => 1,
            _ => 3,
        };
        LOG_LEVEL.store(v, Ordering::Relaxed);
        tracing::info!("Log level → {}", s);
    }));
}

// ─── phantom_parse_conn_string ───────────────────────────────────────────────

/// Parse a `ghs://...` connection string and return JSON with the iOS-
/// relevant fields: `{"server_addr":"...","server_name":"...","tun_addr":"...",`
/// `"cert_pem":"...","key_pem":"..."}`. Returns NULL on parse error.
/// Caller must free via `phantom_free_string`.
#[no_mangle]
pub extern "C" fn phantom_parse_conn_string(input: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if input.is_null() {
            return std::ptr::null_mut();
        }
        let s = match unsafe { CStr::from_ptr(input) }.to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };
        let cfg = match client_common::helpers::parse_conn_string(s) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("phantom_parse_conn_string: {}", e);
                return std::ptr::null_mut();
            }
        };

        let server_addr = cfg.network.server_addr;
        let server_name = cfg.network.server_name.unwrap_or_default();
        let tun_addr = cfg.network.tun_addr.unwrap_or_default();
        let (cert_pem, key_pem) = match cfg.tls {
            Some(t) => (
                t.cert_pem.unwrap_or_default(),
                t.key_pem.unwrap_or_default(),
            ),
            None => (String::new(), String::new()),
        };

        let out = serde_json::json!({
            "server_addr": server_addr,
            "server_name": server_name,
            "tun_addr": tun_addr,
            "cert_pem": cert_pem,
            "key_pem": key_pem,
        })
        .to_string();

        CString::new(out)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }))
    .unwrap_or(std::ptr::null_mut())
}

// ─── phantom_compute_vpn_routes ──────────────────────────────────────────────

/// Input: text of a CIDR file (one `a.b.c.d/nn` per line — the *contents*,
/// not a path; iOS extension reads the file and passes the string).
/// Output: JSON array `[{"addr":"...","prefix":N}]` of routes that should be
/// sent through the VPN (complement of the direct list).
/// Caller must free via `phantom_free_string`.
#[no_mangle]
pub extern "C" fn phantom_compute_vpn_routes(direct_cidrs: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        init_logger();
        if direct_cidrs.is_null() {
            return std::ptr::null_mut();
        }
        let text = match unsafe { CStr::from_ptr(direct_cidrs) }.to_str() {
            Ok(s) => s,
            Err(_) => return std::ptr::null_mut(),
        };
        let table = phantom_core::routing::RoutingTable::from_cidrs(text);
        tracing::info!("Routing: loaded {} direct CIDRs", table.direct_count());
        let routes = table.compute_vpn_routes();
        tracing::info!("Routing: computed {} VPN routes", routes.len());
        let json = phantom_core::routing::routes_to_json(&routes);
        CString::new(json)
            .map(|s| s.into_raw())
            .unwrap_or(std::ptr::null_mut())
    }))
    .unwrap_or(std::ptr::null_mut())
}

// ─── phantom_free_string ─────────────────────────────────────────────────────

/// Free a string returned by any `phantom_*` function that returns
/// `*mut c_char`. Passing NULL is a no-op. Passing anything not obtained
/// from this library, or double-freeing, is undefined behavior.
#[no_mangle]
pub extern "C" fn phantom_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }));
}

// ─── Tunnel runner ───────────────────────────────────────────────────────────

#[allow(clippy::too_many_arguments)]
async fn run_tunnel(
    server_addr: &str,
    server_name: &str,
    insecure: bool,
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(
        Vec<rustls::pki_types::CertificateDer<'static>>,
        rustls::pki_types::PrivateKeyDer<'static>,
    )>,
    mut tun_packet_rx: mpsc::Receiver<Bytes>,
    shutdown_rx: oneshot::Receiver<()>,
    shutdown_flag: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    use client_common::{tls_connect_with_tcp, tls_rx_loop, tls_tx_loop, write_handshake};
    use phantom_core::wire::{flow_stream_idx, n_data_streams};

    // Build TLS config (ALPN=h2 is set inside make_h2_client_tls, which is fine
    // for our server — it negotiates ALPN but still speaks raw [4B len][batch]
    // framing once the TLS handshake completes, identical to Android).
    let client_config =
        phantom_core::h2_transport::make_h2_client_tls(insecure, server_ca, client_identity)
            .context("Failed to build TLS client config")
            .map_err(|e| {
                let _ = e;
                anyhow::anyhow!("build TLS client config failed (ERR_TLS_CONFIG={})", ERR_TLS_CONFIG)
            })?;

    // Normalize server_addr: accept bare host, missing port, or full socketaddr.
    let normalized_addr = client_common::with_default_port(server_addr, 443);
    let server_sock: std::net::SocketAddr = if let Ok(addr) = normalized_addr.parse() {
        addr
    } else {
        tracing::info!("Resolving DNS for {}", normalized_addr);
        tokio::net::lookup_host(&normalized_addr)
            .await
            .context("DNS lookup failed")?
            .next()
            .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", normalized_addr))?
    };

    let n_streams = n_data_streams();
    tracing::info!(
        "Opening {} parallel TLS streams to {}",
        n_streams,
        server_sock
    );

    let mut tls_writers = Vec::with_capacity(n_streams);
    let mut tls_readers = Vec::with_capacity(n_streams);

    for idx in 0..n_streams {
        let tcp = tokio::net::TcpStream::connect(server_sock)
            .await
            .with_context(|| format!("stream {}: TCP connect failed", idx))?;
        let _ = tcp.set_nodelay(true);

        tracing::info!("Stream {}: TCP connected to {}", idx, server_sock);

        let (r, mut w) =
            tls_connect_with_tcp(tcp, server_name.to_string(), client_config.clone())
                .await
                .with_context(|| format!("stream {}: TLS handshake failed", idx))?;

        write_handshake(&mut w, idx as u8, n_streams as u8)
            .await
            .with_context(|| format!("stream {}: write_handshake failed", idx))?;

        tracing::info!("Stream {}: TLS + stream_idx handshake OK", idx);

        tls_readers.push(r);
        tls_writers.push(w);
    }

    tracing::info!("All {} TLS streams up", n_streams);
    IS_CONNECTED.store(true, Ordering::Relaxed);

    // Per-stream TX channels: dispatcher → stream N.
    let mut tx_senders: Vec<mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
    let mut tx_receivers: Vec<mpsc::Receiver<Bytes>> = Vec::with_capacity(n_streams);
    for _ in 0..n_streams {
        let (tx, rx) = mpsc::channel::<Bytes>(2048);
        tx_senders.push(tx);
        tx_receivers.push(rx);
    }

    // Inbound sink: N rx loops → merger → Swift callback.
    let (tls_pkt_tx, mut tls_pkt_rx) = mpsc::channel::<Bytes>(4096);

    // Dispatcher: Swift outbound → per-stream channel, pinned by 5-tuple hash.
    //
    // `try_send` (not `send().await`) is deliberate — a single slow TLS stream
    // must not back-pressure the dispatcher and block ALL flows (cross-stream
    // HoL blocking reproduced on Android v0.18 with `send().await`). Dropping
    // on full lets TCP retransmit handle the slow stream while fast streams
    // stay fluid. Same behavior as server's `tun_dispatch_loop`.
    let tx_senders_disp = tx_senders.clone();
    let disp_handle = tokio::spawn(async move {
        let mut drop_full: u64 = 0;
        let mut drop_closed: u64 = 0;
        while let Some(pkt) = tun_packet_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams);
            let target = &tx_senders_disp[idx];
            match target.try_send(pkt) {
                Ok(()) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    drop_full += 1;
                    if drop_full == 1 || drop_full % 1024 == 0 {
                        tracing::warn!(
                            "dispatcher: stream {} full (dropped_full={})",
                            idx,
                            drop_full
                        );
                    }
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    drop_closed += 1;
                    tracing::warn!(
                        "dispatcher: stream {} closed (dropped_closed={}), exiting",
                        idx,
                        drop_closed
                    );
                    return;
                }
            }
        }
    });
    drop(tx_senders);

    // Inbound merger: forward each packet up through the Swift callback.
    let inbound_handle = tokio::spawn(async move {
        while let Some(pkt) = tls_pkt_rx.recv().await {
            BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
            PKTS_RX.fetch_add(1, Ordering::Relaxed);
            invoke_inbound(&pkt);
        }
    });

    // Spawn N tx loops and N rx loops.
    let mut tx_handles = Vec::with_capacity(n_streams);
    let mut rx_handles = Vec::with_capacity(n_streams);
    for (idx, (writer, rx_chan)) in tls_writers
        .into_iter()
        .zip(tx_receivers.into_iter())
        .enumerate()
    {
        tx_handles.push(tokio::spawn(async move {
            let res = tls_tx_loop(writer, rx_chan).await;
            tracing::warn!("stream {}: tx loop ended: {:?}", idx, res);
            res
        }));
    }
    for (idx, reader) in tls_readers.into_iter().enumerate() {
        let sink = tls_pkt_tx.clone();
        rx_handles.push(tokio::spawn(async move {
            let res = tls_rx_loop(reader, sink).await;
            tracing::warn!("stream {}: rx loop ended: {:?}", idx, res);
            res
        }));
    }
    drop(tls_pkt_tx); // merger task closes when all rx clones drop.

    tokio::select! {
        _ = shutdown_rx => {
            tracing::info!("Tunnel: shutdown signal received");
        }
        _ = async {
            for h in &mut tx_handles {
                let _ = h.await;
            }
        } => {
            tracing::warn!("All TX loops exited");
        }
        _ = async {
            for h in &mut rx_handles {
                let _ = h.await;
            }
        } => {
            tracing::warn!("All RX loops exited");
        }
    }

    for h in tx_handles {
        h.abort();
    }
    for h in rx_handles {
        h.abort();
    }
    disp_handle.abort();
    inbound_handle.abort();

    shutdown_flag.store(true, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
    Ok(())
}
