//! Tracing → `LogFrame` fan-out.
//!
//! Install once (via `install()`); every runtime session can register its own
//! `mpsc::Sender<LogFrame>` via `add_sender()`. The static `BroadcastLayer`
//! captures tracing events and fans them out to all registered senders.
//! Closed/full senders are evicted on the next event.

use ghoststream_gui_ipc::LogFrame;
use std::sync::{Mutex, OnceLock};
use tokio::sync::mpsc;
use tracing::field::{Field, Visit};
use tracing::Event;
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{reload, EnvFilter, Layer};

const CHANNEL_CAP: usize = 256;

type Subs = Mutex<Vec<mpsc::Sender<LogFrame>>>;
static SUBS: OnceLock<Subs> = OnceLock::new();

/// Handle for runtime log-level changes via `set_level()`.
static FILTER_HANDLE: OnceLock<reload::Handle<EnvFilter, tracing_subscriber::Registry>> =
    OnceLock::new();

fn subs() -> &'static Subs {
    SUBS.get_or_init(|| Mutex::new(Vec::new()))
}

/// A receiver that yields `LogFrame` messages captured by the global tracing
/// layer installed via `install()`.
pub struct LogReceiver {
    rx: mpsc::Receiver<LogFrame>,
}

impl LogReceiver {
    pub async fn recv(&mut self) -> Option<LogFrame> {
        self.rx.recv().await
    }
}

/// Subscribe to the global log stream. Returns a `LogReceiver` whose channel
/// is populated by the `BroadcastLayer`.
pub fn subscribe() -> LogReceiver {
    let (tx, rx) = mpsc::channel(CHANNEL_CAP);
    let mut g = subs().lock().unwrap();
    g.push(tx);
    LogReceiver { rx }
}

/// Register an additional sender that will receive all subsequent log frames.
/// Useful when a `run()` caller already has an `mpsc::Sender<LogFrame>` and
/// wants to hook into the global log stream without going through `subscribe()`.
pub fn add_sender(tx: mpsc::Sender<LogFrame>) {
    let mut g = subs().lock().unwrap();
    g.push(tx);
}

/// Remove all registered senders. Called before a new tunnel session
/// to prevent stale senders from the previous session duplicating log lines.
pub fn clear_senders() {
    let mut g = subs().lock().unwrap();
    g.clear();
}

// ── BroadcastLayer ──────────────────────────────────────────────────────────

struct BroadcastLayer;

struct MsgVisitor<'a> {
    out: &'a mut String,
}

impl Visit for MsgVisitor<'_> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        use std::fmt::Write;
        if field.name() == "message" {
            let _ = write!(self.out, "{:?}", value);
        } else {
            let _ = write!(self.out, " {}={:?}", field.name(), value);
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        use std::fmt::Write;
        if field.name() == "message" {
            let _ = write!(self.out, "{}", value);
        } else {
            let _ = write!(self.out, " {}={}", field.name(), value);
        }
    }
}

impl<S> Layer<S> for BroadcastLayer
where
    S: tracing::Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let level = match *event.metadata().level() {
            tracing::Level::ERROR => "ERR",
            tracing::Level::WARN  => "WRN",
            tracing::Level::INFO  => "INF",
            tracing::Level::DEBUG => "DBG",
            tracing::Level::TRACE => "TRC",
        };

        let mut msg = String::new();
        let mut v = MsgVisitor { out: &mut msg };
        event.record(&mut v);

        let frame = LogFrame::now(level, msg);

        let mut g = match subs().lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        // Send + evict closed senders.
        g.retain(|tx| match tx.try_send(frame.clone()) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => true,   // keep, just dropped this frame
            Err(mpsc::error::TrySendError::Closed(_)) => false, // evict
        });
    }
}

/// Install the global tracing subscriber (once). Subsequent calls are no-ops.
/// Logs go to stderr + all registered senders.
pub fn install() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new("info,client_core_runtime=debug,phantom_core=info,client_common=info,jni=warn,rustls=warn,h2=warn,hyper=warn")
    });

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

/// Change the tracing log level at runtime. Called from `nativeSetLogLevel`.
/// `level` is one of: "trace", "debug", "info", "warn", "error".
///
/// Always suppresses noisy internal crates (`jni`, `rustls`) to avoid a
/// feedback loop: jni's `attach_current_thread()` emits DEBUG logs which
/// BroadcastLayer sends back through JNI, triggering another attach, etc.
pub fn set_level(level: &str) {
    if let Some(handle) = FILTER_HANDLE.get() {
        let filter_str = format!("{},jni=warn,rustls=warn,h2=warn,hyper=warn", level);
        let new_filter = EnvFilter::new(filter_str);
        let _ = handle.reload(new_filter);
    }
}
