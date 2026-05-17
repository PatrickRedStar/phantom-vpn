//! Tracing → `LogFrame` fan-out.
//!
//! Install once (via [`install`]); every runtime session can register its own
//! `mpsc::Sender<LogFrame>` via [`add_sender`]. The static layer captures
//! tracing events, hands them to [`crate::log_bridge::event_to_log_frame`]
//! for structured-field extraction, and fans the resulting `LogFrame` out to
//! all registered senders. Closed senders are evicted on the next event.
//!
//! Runtime log levels are controlled either via the env var
//! `GHOSTSTREAM_LOG` (standard `tracing_subscriber::EnvFilter` syntax) or
//! via [`set_level`] called from FFI. ADR 0008 §3 spells out the gating
//! priority.

use ghoststream_gui_ipc::LogFrame;
use std::sync::{Mutex, OnceLock};
use tokio::sync::mpsc;
use tracing::Event;
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{reload, EnvFilter, Layer};

const CHANNEL_CAP: usize = 256;

type Subs = Mutex<Vec<mpsc::Sender<LogFrame>>>;
static SUBS: OnceLock<Subs> = OnceLock::new();

/// Handle for runtime log-level changes via [`set_level`].
static FILTER_HANDLE: OnceLock<reload::Handle<EnvFilter, tracing_subscriber::Registry>> =
    OnceLock::new();

fn subs() -> &'static Subs {
    SUBS.get_or_init(|| Mutex::new(Vec::new()))
}

/// A receiver that yields `LogFrame` messages captured by the global
/// tracing layer installed via [`install`].
pub struct LogReceiver {
    rx: mpsc::Receiver<LogFrame>,
}

impl LogReceiver {
    pub async fn recv(&mut self) -> Option<LogFrame> {
        self.rx.recv().await
    }
}

/// Lock helper that survives a poisoned mutex. FFI-H3 (v0.25.3): every
/// poison path inside `BroadcastLayer::on_event` already calls these helpers
/// from a panic-handler-equivalent context (a tracing event fired during
/// unwind). Panicking again on `.unwrap()` here turns a recoverable problem
/// into an abort — exactly the failure mode `panic = "abort"` makes lethal.
/// Treat poison as "previous holder panicked; data is still structurally
/// valid Vec<Sender>" and proceed.
fn lock_subs(s: &'static Subs) -> std::sync::MutexGuard<'static, Vec<mpsc::Sender<LogFrame>>> {
    s.lock().unwrap_or_else(|p| p.into_inner())
}

/// Subscribe to the global log stream. Returns a `LogReceiver` whose
/// channel is populated by the broadcast layer.
pub fn subscribe() -> LogReceiver {
    let (tx, rx) = mpsc::channel(CHANNEL_CAP);
    let mut g = lock_subs(subs());
    g.push(tx);
    LogReceiver { rx }
}

/// Register an additional sender that will receive all subsequent log
/// frames. Useful when a `run()` caller already has an
/// `mpsc::Sender<LogFrame>` and wants to hook into the global log stream
/// without going through [`subscribe`].
pub fn add_sender(tx: mpsc::Sender<LogFrame>) {
    let mut g = lock_subs(subs());
    g.push(tx);
}

/// Remove all registered senders. Called before a new tunnel session
/// to prevent stale senders from the previous session duplicating log
/// lines.
pub fn clear_senders() {
    let mut g = lock_subs(subs());
    g.clear();
}

// ── BroadcastLayer ──────────────────────────────────────────────────────────

struct BroadcastLayer;

impl<S> Layer<S> for BroadcastLayer
where
    S: tracing::Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        // Build a structured LogFrame via the shared bridge so all
        // subscribers see the same canonical category / fields layout.
        let frame = crate::log_bridge::event_to_log_frame(event);

        let mut g = match subs().lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        // Send + evict closed senders.
        g.retain(|tx| match tx.try_send(frame.clone()) {
            Ok(()) => true,
            // Buffer full — drop this frame for that subscriber, keep it
            // around so subsequent frames can resume.
            Err(mpsc::error::TrySendError::Full(_)) => true,
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        });
    }
}

/// Install the global tracing subscriber (once). Subsequent calls are
/// no-ops. Logs go to stderr + all registered senders.
///
/// The default `EnvFilter` mirrors ADR 0008 §3: `info` plus
/// `client_core_runtime=debug` and `client_common=debug`. Override with
/// the env var `GHOSTSTREAM_LOG`.
pub fn install() {
    install_with_spec_inner(None);
}

/// Like [`install`] but uses `spec` as the initial filter instead of
/// consulting `GHOSTSTREAM_LOG` / `RUST_LOG` env vars. Subsequent calls
/// are no-ops (use [`set_filter_spec`] to change the active filter
/// after install).
///
/// Introduced for the Apple FFI so the runtime can hand a resolved
/// spec straight to the subscriber without mutating `std::env`. Rust
/// 2024 makes `std::env::set_var` `unsafe` because concurrent env
/// readers (EnvFilter, getlogin, etc.) can observe a torn pointer
/// and SIGSEGV — see Apple `apply_log_filter`.
pub fn install_with_spec(spec: &str) {
    install_with_spec_inner(Some(spec));
}

fn install_with_spec_inner(explicit: Option<&str>) {
    let filter = if let Some(spec) = explicit {
        // Honour the caller's resolved spec verbatim. The caller is
        // responsible for any noisy-crate suppression (Apple's
        // `default_log_spec` already encodes it, and the verbose path
        // appends it via `set_filter_spec` below).
        EnvFilter::try_new(spec).unwrap_or_else(|_| EnvFilter::new("info"))
    } else {
        EnvFilter::try_from_env("GHOSTSTREAM_LOG")
            .or_else(|_| EnvFilter::try_from_default_env())
            .unwrap_or_else(|_| {
                EnvFilter::new(
                    "info,client_core_runtime=debug,phantom_core=info,client_common=debug,jni=warn,rustls=warn,h2=warn,hyper=warn",
                )
            })
    };

    let (filter_layer, handle) = reload::Layer::new(filter);

    let stderr_layer = tracing_subscriber::fmt::layer()
        .with_target(false)
        .compact();

    let ok = tracing_subscriber::registry()
        .with(filter_layer)
        .with(stderr_layer)
        .with(BroadcastLayer)
        .try_init()
        .is_ok();

    if ok {
        let _ = FILTER_HANDLE.set(handle);
    }
}

/// Change the tracing log level at runtime. Called from `nativeSetLogLevel`
/// on Android and from `phantom_runtime_set_verbose` on Apple.
///
/// `level` is one of: `"trace"`, `"debug"`, `"info"`, `"warn"`, `"error"`.
///
/// Always suppresses noisy internal crates (`jni`, `rustls`) to avoid a
/// feedback loop: jni's `attach_current_thread()` emits DEBUG logs which
/// `BroadcastLayer` would forward back through JNI, triggering another
/// attach, etc.
pub fn set_level(level: &str) {
    if let Some(handle) = FILTER_HANDLE.get() {
        let filter_str = format!("{},jni=warn,rustls=warn,h2=warn,hyper=warn", level);
        let new_filter = EnvFilter::new(filter_str);
        let _ = handle.reload(new_filter);
    }
}

/// Apply a full EnvFilter spec at runtime (e.g. `"info,h2=warn,my_crate=trace"`).
/// Used by the Apple FFI where `apply_log_filter` may produce a multi-target
/// spec rather than a single level. If the spec is a single bare level we
/// route through [`set_level`] so the noisy-crate suppression suffix is
/// applied; otherwise we install it verbatim.
///
/// Silent no-op if the subscriber wasn't installed or the spec fails to
/// parse — the caller has already chosen a fallback in either case.
pub fn set_filter_spec(spec: &str) {
    if matches!(spec, "trace" | "debug" | "info" | "warn" | "error") {
        set_level(spec);
        return;
    }
    if let Some(handle) = FILTER_HANDLE.get() {
        if let Ok(new_filter) = EnvFilter::try_new(spec) {
            let _ = handle.reload(new_filter);
        }
    }
}
