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

// ─── Log filter gating (ADR 0008 §3) ─────────────────────────────────────────

/// Default `tracing` filter spec when no env override and `verbose_log == false`.
///
/// Debug builds default to DBG for our own crates (so engineers see handshake /
/// stream lifecycle without flipping the toggle). Release builds default to INF
/// to keep the file lean unless the operator explicitly opts in.
fn default_log_spec() -> &'static str {
    if cfg!(debug_assertions) {
        "info,client_core_runtime=debug,client_common=debug,phantom_client_apple=debug"
    } else {
        "info"
    }
}

/// Compute the active filter spec for a `phantom_runtime_start` invocation,
/// per the ADR 0008 §3 priority chain. Pure function — easy to test, no
/// observable side effects.
fn resolve_log_spec(verbose: bool) -> String {
    // 1. env `GHOSTSTREAM_LOG` wins over everything (engineers can pin a spec
    //    while debugging without rebuilding). Reading env is fine — only
    //    *writing* it is unsafe under Rust 2024.
    let from_env = std::env::var("GHOSTSTREAM_LOG").ok().filter(|s| !s.is_empty());

    // 2. Swift verbose toggle.
    // 3. Build-config default.
    match (from_env, verbose) {
        (Some(s), _) => s,
        (None, true) => "trace".to_string(),
        (None, false) => default_log_spec().to_string(),
    }
}

/// Resolve and apply the active filter spec for this `phantom_runtime_start`
/// invocation, per the ADR 0008 §3 priority chain. Idempotent — safe to call
/// multiple times across sessions.
///
/// v0.25.2 (CRIT-4): no longer touches `std::env::set_var`. Rust 2024 makes
/// that `unsafe` because concurrent env readers — `EnvFilter`, libc
/// internals, third-party tokio worker plugins — can observe a torn pointer
/// during the write and SIGSEGV. We now feed the resolved spec straight to
/// the subscriber via `logsink::install_with_spec()` (first call) and
/// `logsink::set_filter_spec()` (subsequent calls), keeping the live
/// filter exactly in sync without mutating shared process state.
fn apply_log_filter(verbose: bool) {
    let spec = resolve_log_spec(verbose);

    // Install the global subscriber with our resolved spec on the very first
    // call; subsequent calls are a no-op inside `logsink` and the live filter
    // is driven by `set_filter_spec` below instead.
    client_core_runtime::logsink::install_with_spec(&spec);

    // Re-apply on every entry so that a flip of `verbose_log` between
    // sessions takes effect even when `install()` is already a no-op.
    // Accepts the full EnvFilter syntax — single bare levels are still
    // routed through `set_level` internally so the noisy-crate suppression
    // suffix is applied.
    client_core_runtime::logsink::set_filter_spec(&spec);
}

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
/// * `verbose_log`   — when `true`, override the active log filter to TRACE for
///                     every category (per ADR 0008 §3, priority 2). When
///                     `false`, the default filter applies: `GHOSTSTREAM_LOG`
///                     env (priority 1) → build-config default (priority 3).
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
    verbose_log: bool,
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
                // SECURITY: never include `e.to_string()` in the log — when
                // the parser fails mid-userinfo (base64-PEM inside a
                // `ghs://` conn-string), serde_json's Display impl echoes
                // the surrounding bytes verbatim, leaking the private key
                // into the persisted NDJSON runtime log. Surface only the
                // structural position so the operator can still diagnose
                // bad payloads.
                tracing::error!(
                    "phantom_runtime_start: cfg_json parse failed (line: {}, column: {})",
                    e.line(),
                    e.column()
                );
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

        // ── Atomic "reserve the slot or bail" (CRIT-1) ───────────────────────
        //
        // v0.25.2: hold the `STATE` lock across the entire init path so that
        // two concurrent FFI callers can't both observe `None`, both proceed
        // to `run()`, and both end up creating a tunnel while only the second
        // one is tracked. The previous pattern released the lock after the
        // `is_some()` check, leaving a wide TOCTOU window through
        // `apply_log_filter` and `rt.block_on(run(...))`.
        //
        // Concurrent `phantom_runtime_submit_inbound` callers briefly contend
        // on the same `parking_lot::Mutex`, but they only clone a channel
        // sender under the lock — sub-microsecond — and the start path is
        // not on any hot path (called once per Swift `startTunnel`). The
        // shared lock is the simplest correct shape, no placeholder dance
        // required.
        let mut state_guard = STATE.lock();
        if state_guard.is_some() {
            tracing::warn!("phantom_runtime_start: already running");
            return ERR_ALREADY_RUNNING;
        }

        // ── Log gating (ADR 0008 §3) ────────────────────────────────────────
        // Priority resolution for the tracing filter:
        //   1. env `GHOSTSTREAM_LOG` (full EnvFilter syntax)
        //   2. `verbose_log == true` (UserDefaults-driven Swift toggle) ⇒ TRACE
        //   3. Build-config default (debug vs release).
        //
        // v0.25.2 (CRIT-4): `apply_log_filter` no longer mutates env vars.
        // The resolved spec is handed straight to `logsink::install_with_spec`
        // and `logsink::set_filter_spec`.
        apply_log_filter(verbose_log);

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

        // Start the runtime. `run()` is async but does only synchronous
        // setup internally (channel allocations + a single `tokio::spawn`
        // for the supervisor), so this `block_on` returns near-instantly
        // and the Swift `startTunnel` thread is held for microseconds.
        // The actual tunnel lifecycle runs on tokio workers via the
        // spawned supervisor (`join` below).
        let (handles, join) = match rt.block_on(client_core_runtime::run(cfg, tun, status_tx, log_tx, None)) {
            Ok(r) => r,
            Err(e) => {
                tracing::error!("phantom_runtime_start: run() failed: {}", e);
                // No state inserted; another start may now proceed.
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

        // Commit the slot atomically — same guard we acquired at the top of
        // the function, so no other thread has observed a stale `None` in
        // the meantime.
        *state_guard = Some(RuntimeState { handles, _join: join });
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
                // v0.25.1 (W3-2): `cancel` is now `watch::Sender<bool>`.
                // `send(true)` stores the value so a supervisor that has
                // not yet re-armed its select! arm still sees the signal
                // — the fix for missed-cancel under TSPU shake. Ignoring
                // the result is correct: a closed channel means the
                // supervisor already exited on its own.
                let _ = s.handles.cancel.send(true);
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
                // SECURITY: `parse_conn_string` errors carry safe `.context`
                // messages today, but the underlying `base64::DecodeError`
                // and `FromUtf8Error` impls can leak raw bytes from the
                // userinfo (base64-PEM) section if anyhow's chain ever
                // changes. Log only the top-level context, never the full
                // chain.
                let top = format!("{}", e);
                tracing::error!("phantom_parse_conn_string: {}", top);
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
        let direct_n = table.direct_count();
        let routes = table.compute_vpn_routes();
        let vpn_n = routes.len();
        // ADR 0008 §2: structured `settings.routes.computed` event so
        // dashboards / log viewers can filter routing decisions out of
        // the noise. Direct + VPN counts let us spot mis-configured
        // route tables (e.g. direct_n=0 when split-routing is expected).
        tracing::info!(
            category = "settings",
            direct_n = direct_n as u64,
            vpn_n = vpn_n as u64,
            "routes.computed"
        );
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

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use client_core_runtime::LogFrame;

    /// ADR 0008: a `LogFrame::structured(...)` must round-trip cleanly via
    /// JSON — the same path the FFI `log_cb` payload travels (Rust → bytes →
    /// Swift JSONDecoder). Category and structured fields must survive bit-
    /// exact.
    #[test]
    fn log_frame_v2_ffi_roundtrip_preserves_structured_payload() {
        let event = LogFrame::structured(
            "DBG",
            "handshake",
            "tls.client_hello",
            [
                ("sni".to_string(), "cdn.example.com".to_string()),
                ("alpn".to_string(), "h2".to_string()),
            ],
        );

        // Mirror the actual FFI encode path (lib.rs ~line 204).
        let bytes = serde_json::to_vec(&event).expect("encode");
        let parsed: LogFrame = serde_json::from_slice(&bytes).expect("decode");

        assert_eq!(parsed.level, "DBG");
        assert_eq!(parsed.category.as_deref(), Some("handshake"));
        assert_eq!(parsed.msg, "tls.client_hello");
        let fields = parsed.fields.as_ref().expect("fields present");
        assert_eq!(fields.get("sni").map(String::as_str), Some("cdn.example.com"));
        assert_eq!(fields.get("alpn").map(String::as_str), Some("h2"));
        assert!(parsed.ts_unix_us > 0, "v2 frames must carry microsecond timestamp");
    }

    /// ADR 0008: a v1 LogFrame payload (no `category`, no `fields`, no
    /// `ts_unix_us`) emitted by an older sender (Linux helper, Android
    /// pre-v0.23.x) must still decode on the FFI consumer side. Backward
    /// compat is the whole point of `#[serde(default)]` on the new fields.
    #[test]
    fn log_frame_v1_payload_decodes_via_ffi_path() {
        let v1 = br#"{"ts_unix_ms":1715200000000,"level":"INF","msg":"legacy"}"#;

        let parsed: LogFrame = serde_json::from_slice(v1).expect("v1 decodes");

        assert_eq!(parsed.ts_unix_ms, 1715200000000);
        assert_eq!(parsed.ts_unix_us, 0);
        assert_eq!(parsed.level, "INF");
        assert_eq!(parsed.msg, "legacy");
        assert!(parsed.category.is_none());
        assert!(parsed.fields.is_none());
        // Convenience fallback — consumers should never see "us == 0" silently.
        assert_eq!(parsed.timestamp_us(), 1715200000000 * 1_000);
    }

    /// ADR 0008 §3: `default_log_spec()` must differ between debug and
    /// release so the file lives at INFO+ in shipped builds and DEBUG+ in
    /// dev. We can't toggle `cfg!(debug_assertions)` at test time, but we
    /// can pin the value for whichever profile this test runs in.
    #[test]
    fn default_log_spec_is_build_aware() {
        let spec = default_log_spec();
        if cfg!(debug_assertions) {
            assert!(
                spec.contains("client_core_runtime=debug"),
                "debug build must enable DBG for our crates, got: {}",
                spec
            );
        } else {
            assert_eq!(spec, "info", "release build must default to INF, got: {}", spec);
        }
    }

    /// ADR 0008 §3 priority 1: if `GHOSTSTREAM_LOG` is set, it must override
    /// both the verbose toggle and the build default. We exercise the pure
    /// resolver directly so the test never mutates the global subscriber.
    /// The test is `#[serial]`-style — guarded by a process-wide mutex
    /// against the other env-reading tests (because they share
    /// `GHOSTSTREAM_LOG`).
    ///
    /// v0.25.2 (CRIT-4): no longer asserts on `RUST_LOG` — `apply_log_filter`
    /// no longer mutates env vars. Setting `GHOSTSTREAM_LOG` for the test
    /// fixture is still safe because tests run single-threaded under
    /// `--test-threads=1` semantics via `ENV_LOCK` and no other code is
    /// reading env concurrently in this binary's test harness.
    #[test]
    fn ghoststream_log_env_overrides_verbose_toggle() {
        let _guard = ENV_LOCK.lock();

        let prev_gs = std::env::var_os("GHOSTSTREAM_LOG");

        std::env::set_var("GHOSTSTREAM_LOG", "warn,h2=trace");
        // Even with verbose=true, the env wins.
        assert_eq!(resolve_log_spec(true), "warn,h2=trace");
        assert_eq!(resolve_log_spec(false), "warn,h2=trace");

        match prev_gs {
            Some(v) => std::env::set_var("GHOSTSTREAM_LOG", v),
            None => std::env::remove_var("GHOSTSTREAM_LOG"),
        }
    }

    /// ADR 0008 §3 priority 2: with no env set, `verbose_log == true` must
    /// pin TRACE.
    #[test]
    fn verbose_toggle_pins_trace_when_env_unset() {
        let _guard = ENV_LOCK.lock();

        let prev_gs = std::env::var_os("GHOSTSTREAM_LOG");

        std::env::remove_var("GHOSTSTREAM_LOG");
        assert_eq!(resolve_log_spec(true), "trace");

        match prev_gs {
            Some(v) => std::env::set_var("GHOSTSTREAM_LOG", v),
            None => std::env::remove_var("GHOSTSTREAM_LOG"),
        }
    }

    /// ADR 0008 §3 priority 3: with no env set and verbose off, the
    /// build-config default applies.
    #[test]
    fn build_default_applies_when_env_unset_and_verbose_off() {
        let _guard = ENV_LOCK.lock();

        let prev_gs = std::env::var_os("GHOSTSTREAM_LOG");

        std::env::remove_var("GHOSTSTREAM_LOG");
        assert_eq!(resolve_log_spec(false), default_log_spec());

        match prev_gs {
            Some(v) => std::env::set_var("GHOSTSTREAM_LOG", v),
            None => std::env::remove_var("GHOSTSTREAM_LOG"),
        }
    }

    /// Process-wide lock so tests that touch `GHOSTSTREAM_LOG` (read or
    /// fixture-set) don't race when `cargo test` runs them in parallel.
    static ENV_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());
}
