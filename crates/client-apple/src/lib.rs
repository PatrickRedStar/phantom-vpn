//! phantom-client-apple: iOS/macOS FFI bindings for GhostStream.
//!
//! Exposes the unified `client-core-runtime` tunnel to Swift via plain C FFI.
//! Designed to be embedded in an `NEPacketTunnelProvider` extension:
//!
//! - Swift calls [`phantom_runtime_start`] with JSON-encoded [`ConnectProfile`]
//!   and [`TunnelSettings`] plus three C callbacks.
//! - `outbound_cb` is invoked by Rust for each inbound IP packet (network →
//!   device), which Swift hands to `packetFlow.writePackets(...)`.
//! - Swift calls [`phantom_runtime_submit_inbound`] for each outbound IP packet
//!   read from `packetFlow` (device → network).
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
use std::sync::Arc;

use bytes::Bytes;
use client_core_runtime::{ConnectProfile, PacketIo, RuntimeHandles, TunIo, TunnelSettings};
use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, watch};

// ─── Error codes ─────────────────────────────────────────────────────────────

const ERR_BAD_CONFIG: i32 = -1;
const ERR_ALREADY_RUNNING: i32 = -2;
const ERR_RUNTIME_INIT: i32 = -4;
const ERR_QUEUE_FULL: i32 = -10;
const ERR_NO_TUNNEL: i32 = -11;
const ERR_PANIC: i32 = -99;

// ─── Tokio runtime singleton ─────────────────────────────────────────────────

static RT: OnceCell<Runtime> = OnceCell::new();

fn get_or_init_rt() -> Option<&'static Runtime> {
    RT.get_or_try_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(6)
            .thread_name("phantom-apple")
            .build()
    })
    .ok()
}

// ─── Global runtime state ────────────────────────────────────────────────────

struct RuntimeState {
    handles: RuntimeHandles,
    _join: tokio::task::JoinHandle<anyhow::Result<()>>,
}

static STATE: Mutex<Option<RuntimeState>> = Mutex::new(None);

// ─── OutboundDispatcher — implements PacketIo for the Swift outbound callback ─

/// Wraps the Swift-provided C callback so Rust can deliver decoded IP packets
/// (network → device) by calling it for each one.
struct OutboundDispatcher {
    cb: unsafe extern "C" fn(*const u8, usize, *mut c_void),
    ctx: *mut c_void,
}

// SAFETY: The Swift caller guarantees `ctx` lives for at least the lifetime of
// the tunnel. We only pass it back unchanged. `cb` is a plain function pointer.
unsafe impl Send for OutboundDispatcher {}
unsafe impl Sync for OutboundDispatcher {}

impl PacketIo for OutboundDispatcher {
    fn submit_outbound_batch(&self, pkts: Vec<Bytes>) {
        for pkt in pkts {
            // SAFETY: `cb` is a valid function pointer; `ctx` is caller-owned.
            unsafe { (self.cb)(pkt.as_ptr(), pkt.len(), self.ctx) }
        }
    }
}

// ─── phantom_runtime_start ───────────────────────────────────────────────────

/// Start the tunnel runtime.
///
/// * `cfg_json`      — JSON-encoded [`ConnectProfile`] (name + conn_string + settings).
/// * `settings_json` — JSON-encoded [`TunnelSettings`] (overrides settings inside
///                     cfg_json if present; may be `null` / empty to use defaults).
/// * `status_cb`     — called on every [`StatusFrame`] change; JSON-encoded bytes.
/// * `log_cb`        — called for every [`LogFrame`]; JSON-encoded bytes.
/// * `outbound_cb`   — called for each IP packet from the tunnel destined to the device.
/// * `ctx`           — opaque pointer forwarded to all three callbacks.
///
/// Returns 0 on success, negative on error.
#[no_mangle]
pub extern "C" fn phantom_runtime_start(
    cfg_json: *const c_char,
    settings_json: *const c_char,
    status_cb: Option<unsafe extern "C" fn(*const u8, usize, *mut c_void)>,
    log_cb: Option<unsafe extern "C" fn(*const u8, usize, *mut c_void)>,
    outbound_cb: Option<unsafe extern "C" fn(*const u8, usize, *mut c_void)>,
    ctx: *mut c_void,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if cfg_json.is_null() {
            return ERR_BAD_CONFIG;
        }

        // Parse ConnectProfile from cfg_json.
        let cfg_str = match unsafe { CStr::from_ptr(cfg_json) }.to_str() {
            Ok(s) => s,
            Err(_) => return ERR_BAD_CONFIG,
        };
        let mut cfg: ConnectProfile = match serde_json::from_str(cfg_str) {
            Ok(c) => c,
            Err(e) => {
                tracing::error!("phantom_runtime_start: bad cfg_json: {}", e);
                return ERR_BAD_CONFIG;
            }
        };

        // Optionally override TunnelSettings from settings_json.
        if !settings_json.is_null() {
            if let Ok(s) = unsafe { CStr::from_ptr(settings_json) }.to_str() {
                if !s.is_empty() {
                    if let Ok(ts) = serde_json::from_str::<TunnelSettings>(s) {
                        cfg.settings = ts;
                    }
                }
            }
        }

        // Guard against double-start.
        {
            let g = STATE.lock();
            if g.is_some() {
                tracing::warn!("phantom_runtime_start: already running");
                return ERR_ALREADY_RUNNING;
            }
        }

        let rt = match get_or_init_rt() {
            Some(r) => r,
            None => {
                tracing::error!("phantom_runtime_start: failed to init tokio runtime");
                return ERR_RUNTIME_INIT;
            }
        };

        // Require outbound_cb; status_cb and log_cb are optional.
        let outbound_cb = match outbound_cb {
            Some(f) => f,
            None => {
                tracing::error!("phantom_runtime_start: outbound_cb is required");
                return ERR_BAD_CONFIG;
            }
        };

        let dispatcher = Arc::new(OutboundDispatcher { cb: outbound_cb, ctx });
        let tun = TunIo::Callback(dispatcher);

        // Status channel: watch::Sender → task that calls status_cb.
        let (status_tx, mut status_rx) =
            watch::channel(client_core_runtime::StatusFrame::default());

        // Log channel: mpsc → task that calls log_cb.
        let (log_tx, mut log_rx) = mpsc::channel::<client_core_runtime::LogFrame>(256);

        // Start the runtime (blocking until run() returns).
        let (handles, join) = match rt.block_on(client_core_runtime::run(cfg, tun, status_tx, log_tx, None)) {
            Ok(r) => r,
            Err(e) => {
                tracing::error!("phantom_runtime_start: run() failed: {}", e);
                return ERR_BAD_CONFIG;
            }
        };

        // Spawn status watcher task.
        if let Some(scb) = status_cb {
            let ctx_ptr = ctx as usize; // send across thread boundary as usize
            rt.spawn(async move {
                while status_rx.changed().await.is_ok() {
                    let frame = status_rx.borrow_and_update().clone();
                    if let Ok(json) = serde_json::to_vec(&frame) {
                        let ctx = ctx_ptr as *mut c_void;
                        unsafe { scb(json.as_ptr(), json.len(), ctx) };
                    }
                }
            });
        }

        // Spawn log forwarder task.
        if let Some(lcb) = log_cb {
            let ctx_ptr = ctx as usize;
            rt.spawn(async move {
                while let Some(frame) = log_rx.recv().await {
                    if let Ok(json) = serde_json::to_vec(&frame) {
                        let ctx = ctx_ptr as *mut c_void;
                        unsafe { lcb(json.as_ptr(), json.len(), ctx) };
                    }
                }
            });
        }

        *STATE.lock() = Some(RuntimeState { handles, _join: join });
        0
    }))
    .unwrap_or_else(|_| {
        tracing::error!("phantom_runtime_start: panic caught at FFI boundary");
        ERR_PANIC
    })
}

// ─── phantom_runtime_submit_inbound ──────────────────────────────────────────

/// Push an outbound IP packet (read from `packetFlow`) into the tunnel.
///
/// Naming convention note: "inbound" here is from the tunnel's perspective —
/// this packet travels inbound to the tunnel (device → network).
///
/// Returns 0 on accept, -10 on queue full (drop), -11 if no tunnel running.
#[no_mangle]
pub extern "C" fn phantom_runtime_submit_inbound(ptr: *const u8, len: usize) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if ptr.is_null() || len == 0 {
            return ERR_BAD_CONFIG;
        }

        let sender = {
            let g = STATE.lock();
            match g.as_ref() {
                Some(s) => s.handles.inbound_tx.clone(),
                None => return ERR_NO_TUNNEL,
            }
        };

        let pkt = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(ptr, len) });
        match sender.try_send(pkt) {
            Ok(()) => 0,
            Err(mpsc::error::TrySendError::Full(_)) => ERR_QUEUE_FULL,
            Err(mpsc::error::TrySendError::Closed(_)) => ERR_NO_TUNNEL,
        }
    }))
    .unwrap_or(ERR_PANIC)
}

// ─── phantom_runtime_stop ────────────────────────────────────────────────────

/// Signal the running tunnel to shut down gracefully.
/// Returns 0 if a shutdown was signalled, -11 if no tunnel was running.
#[no_mangle]
pub extern "C" fn phantom_runtime_stop() -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let state = STATE.lock().take();
        match state {
            Some(s) => {
                s.handles.cancel.notify_waiters();
                tracing::info!("phantom_runtime_stop: cancel notified");
                0
            }
            None => ERR_NO_TUNNEL,
        }
    }))
    .unwrap_or(ERR_PANIC)
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
