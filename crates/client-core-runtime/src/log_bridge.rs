//! `tracing` → `LogFrame` bridge — ADR 0008.
//!
//! Maps a `tracing::Event` to a structured [`LogFrame`] and fans the result
//! out over `mpsc` senders registered with [`crate::logsink`]. Compared to the
//! v1 fallback (which concatenated all fields into the message string) this
//! bridge:
//!
//! 1. Maps the `tracing::Level` to the canonical 3-char code (`ERR`/`WRN`/
//!    `INF`/`DBG`/`TRC`).
//! 2. Recognises a magic `category` field on the event and lifts it onto
//!    `LogFrame::category`. If absent, the frame's `category` stays `None`.
//! 3. Pulls the `message` field into `LogFrame::msg` verbatim.
//! 4. Collects every other field into a `BTreeMap<String, String>` and sets
//!    `LogFrame::fields` (or `None` if there are none).
//! 5. Constructs the frame via [`LogFrame::structured`] which fills in the
//!    microsecond timestamp.
//!
//! All event sites should follow the canonical taxonomy in ADR 0008 §2.
//! Example:
//!
//! ```ignore
//! tracing::debug!(category = "stream", stream_id = 3, "stream opened");
//! // ⇒ LogFrame{
//! //      level: "DBG",
//! //      category: Some("stream"),
//! //      msg: "stream opened",
//! //      fields: {"stream_id": "3"},
//! //      ..
//! //  }
//! ```
//!
//! ### Sampling
//!
//! Some categories — notably `packet.tx.batch` / `packet.rx.batch` — fire
//! tens of thousands of times per second on a busy tunnel. Emitting every
//! event would saturate the log file and starve the tokio runtime. Sites
//! that need sampling call [`packet_log_sample_should_emit`] before paying
//! the `tracing::trace!` invocation cost. The denominator is read once at
//! process start from the env var `GHOSTSTREAM_PACKET_LOG_SAMPLE` (default
//! `100`); a value of `0` or `1` disables sampling (every batch logs).

use ghoststream_gui_ipc::LogFrame;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use tracing::field::{Field, Visit};
use tracing::Event;
use tracing_subscriber::layer::{Context, Layer};

// ── Level mapping ────────────────────────────────────────────────────────────

/// Map a `tracing::Level` to the canonical 3-char `LogFrame.level` code.
pub fn level_to_str(level: &tracing::Level) -> &'static str {
    match *level {
        tracing::Level::ERROR => "ERR",
        tracing::Level::WARN => "WRN",
        tracing::Level::INFO => "INF",
        tracing::Level::DEBUG => "DBG",
        tracing::Level::TRACE => "TRC",
    }
}

// ── EventVisitor ─────────────────────────────────────────────────────────────

/// Visits a `tracing::Event` and splits it into:
/// - `message` field → `msg`
/// - `category` field → `category`
/// - everything else → `fields`
///
/// Values are stringified: numerics via `to_string()`, strings verbatim,
/// anything else via `Debug` formatting.
struct EventVisitor {
    msg: String,
    category: Option<String>,
    fields: BTreeMap<String, String>,
}

impl EventVisitor {
    fn new() -> Self {
        Self {
            msg: String::new(),
            category: None,
            fields: BTreeMap::new(),
        }
    }
}

impl Visit for EventVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let name = field.name();
        if name == "message" {
            self.msg = format!("{:?}", value);
        } else if name == "category" {
            self.category = Some(format!("{:?}", value));
        } else {
            self.fields.insert(name.to_string(), format!("{:?}", value));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        let name = field.name();
        if name == "message" {
            self.msg = value.to_string();
        } else if name == "category" {
            self.category = Some(value.to_string());
        } else {
            self.fields.insert(name.to_string(), value.to_string());
        }
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields.insert(field.name().to_string(), value.to_string());
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields.insert(field.name().to_string(), value.to_string());
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields.insert(field.name().to_string(), value.to_string());
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.fields.insert(field.name().to_string(), value.to_string());
    }
}

/// Pure conversion from `tracing::Event` → `LogFrame`. Public so callers
/// can build their own custom `Layer` if they need extra logic on top.
pub fn event_to_log_frame(event: &Event<'_>) -> LogFrame {
    let level = level_to_str(event.metadata().level());
    let mut visitor = EventVisitor::new();
    event.record(&mut visitor);
    let category = visitor.category.unwrap_or_default();

    if category.is_empty() {
        // No category supplied — we still need *something* on the frame so
        // downstream consumers can see the event. We construct a v1-style
        // frame with `LogFrame::now` and then attach the fields manually.
        let mut frame = LogFrame::now(level, visitor.msg);
        if !visitor.fields.is_empty() {
            frame.fields = Some(visitor.fields);
        }
        frame
    } else {
        LogFrame::structured(level, &category, visitor.msg, visitor.fields)
    }
}

// ── LogBridgeLayer ───────────────────────────────────────────────────────────

/// `tracing-subscriber` layer that converts events to `LogFrame` and ships
/// them to a closure. The closure is invoked under the layer's call-site;
/// keep it cheap (e.g. push to a channel and return).
pub struct LogBridgeLayer<F>
where
    F: Fn(LogFrame) + Send + Sync + 'static,
{
    sink: F,
}

impl<F> LogBridgeLayer<F>
where
    F: Fn(LogFrame) + Send + Sync + 'static,
{
    pub fn new(sink: F) -> Self {
        Self { sink }
    }
}

impl<S, F> Layer<S> for LogBridgeLayer<F>
where
    S: tracing::Subscriber,
    F: Fn(LogFrame) + Send + Sync + 'static,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let frame = event_to_log_frame(event);
        (self.sink)(frame);
    }
}

// ── Packet sampling helpers ──────────────────────────────────────────────────

static PACKET_SAMPLE_DENOMINATOR: OnceLock<usize> = OnceLock::new();
static PACKET_TX_COUNTER: AtomicU64 = AtomicU64::new(0);
static PACKET_RX_COUNTER: AtomicU64 = AtomicU64::new(0);

fn packet_sample_denominator() -> usize {
    *PACKET_SAMPLE_DENOMINATOR.get_or_init(|| {
        std::env::var("GHOSTSTREAM_PACKET_LOG_SAMPLE")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(100)
    })
}

/// Returns `true` for the first call out of every `denominator` calls
/// (counter is per-direction). `denominator <= 1` ⇒ always emit.
fn should_emit(counter: &AtomicU64, denominator: usize) -> bool {
    if denominator <= 1 {
        return true;
    }
    let n = counter.fetch_add(1, Ordering::Relaxed);
    (n % denominator as u64) == 0
}

/// Should this packet TX batch be logged? Hot-path call: one atomic
/// increment + one modulo. Returns `true` for the first event in every
/// `GHOSTSTREAM_PACKET_LOG_SAMPLE` events (default 100).
pub fn packet_tx_log_sample_should_emit() -> bool {
    should_emit(&PACKET_TX_COUNTER, packet_sample_denominator())
}

/// Should this packet RX batch be logged? See [`packet_tx_log_sample_should_emit`].
pub fn packet_rx_log_sample_should_emit() -> bool {
    should_emit(&PACKET_RX_COUNTER, packet_sample_denominator())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use tracing_subscriber::layer::SubscriberExt;

    /// Helper: run a closure with a one-shot subscriber that collects every
    /// `LogFrame` produced by `LogBridgeLayer` into the returned `Vec`.
    fn capture<R>(f: impl FnOnce() -> R) -> (R, Vec<LogFrame>) {
        let collected: std::sync::Arc<Mutex<Vec<LogFrame>>> =
            std::sync::Arc::new(Mutex::new(Vec::new()));
        let collected_clone = collected.clone();
        let layer = LogBridgeLayer::new(move |frame| {
            collected_clone.lock().unwrap().push(frame);
        });
        let subscriber = tracing_subscriber::registry().with(layer);
        let r = tracing::subscriber::with_default(subscriber, f);
        let frames = std::mem::take(&mut *collected.lock().unwrap());
        (r, frames)
    }

    #[test]
    fn maps_info_event_with_category_and_fields() {
        let (_r, frames) = capture(|| {
            tracing::info!(category = "stream", stream_id = 3u64, "opened");
        });

        assert_eq!(frames.len(), 1);
        let f = &frames[0];
        assert_eq!(f.level, "INF");
        assert_eq!(f.category.as_deref(), Some("stream"));
        assert_eq!(f.msg, "opened");
        let fields = f.fields.as_ref().expect("fields must be present");
        assert_eq!(fields.get("stream_id").map(String::as_str), Some("3"));
        assert!(!fields.contains_key("message"));
        assert!(!fields.contains_key("category"));
    }

    #[test]
    fn maps_all_five_levels() {
        let (_r, frames) = capture(|| {
            tracing::error!(category = "tunnel", "boom");
            tracing::warn!(category = "tunnel", "wobble");
            tracing::info!(category = "tunnel", "ok");
            tracing::debug!(category = "tunnel", "ping");
            tracing::trace!(category = "tunnel", "tick");
        });
        let levels: Vec<&str> = frames.iter().map(|f| f.level.as_str()).collect();
        assert_eq!(levels, vec!["ERR", "WRN", "INF", "DBG", "TRC"]);
    }

    #[test]
    fn event_without_category_yields_none() {
        let (_r, frames) = capture(|| {
            tracing::info!(some_field = "v", "uncategorised");
        });
        assert_eq!(frames.len(), 1);
        let f = &frames[0];
        assert_eq!(f.category, None);
        assert_eq!(f.msg, "uncategorised");
        // Even without a category, structured fields are still attached.
        let fields = f.fields.as_ref().expect("fields present");
        assert_eq!(fields.get("some_field").map(String::as_str), Some("v"));
    }

    #[test]
    fn collects_multiple_structured_fields() {
        let (_r, frames) = capture(|| {
            tracing::info!(
                category = "tunnel",
                profile_id = "default",
                server = "1.2.3.4:443",
                sni = "cdn.example.com",
                streams = 8u64,
                "start"
            );
        });
        assert_eq!(frames.len(), 1);
        let f = &frames[0];
        assert_eq!(f.category.as_deref(), Some("tunnel"));
        assert_eq!(f.msg, "start");
        let fields = f.fields.as_ref().expect("fields present");
        assert_eq!(fields.get("profile_id").map(String::as_str), Some("default"));
        assert_eq!(fields.get("server").map(String::as_str), Some("1.2.3.4:443"));
        assert_eq!(fields.get("sni").map(String::as_str), Some("cdn.example.com"));
        assert_eq!(fields.get("streams").map(String::as_str), Some("8"));
    }

    #[test]
    fn microsecond_timestamp_populated() {
        let (_r, frames) = capture(|| {
            tracing::info!(category = "tunnel", "start");
        });
        let f = &frames[0];
        // `LogFrame::structured` always sets `ts_unix_us`.
        assert!(f.ts_unix_us > 0, "ts_unix_us must be populated for v2 frames");
        assert!(f.ts_unix_us >= f.ts_unix_ms.saturating_mul(1_000));
    }

    #[test]
    fn empty_fields_collapse_to_none() {
        let (_r, frames) = capture(|| {
            tracing::info!(category = "runtime", "shutdown");
        });
        assert_eq!(frames.len(), 1);
        assert!(frames[0].fields.is_none(), "no extra fields ⇒ fields == None");
    }

    /// Sampling: with denominator 100, the first call returns true, the
    /// next 99 return false, the 101st returns true again.
    #[test]
    fn packet_sample_emits_one_in_n() {
        let counter = AtomicU64::new(0);
        let mut emits: Vec<bool> = Vec::with_capacity(250);
        for _ in 0..250 {
            emits.push(should_emit(&counter, 100));
        }

        // Indices 0, 100, 200 are true; everything else is false.
        let true_indices: Vec<usize> = emits
            .iter()
            .enumerate()
            .filter_map(|(i, e)| if *e { Some(i) } else { None })
            .collect();
        assert_eq!(true_indices, vec![0, 100, 200]);
    }

    #[test]
    fn packet_sample_denominator_one_emits_every_event() {
        let counter = AtomicU64::new(0);
        for _ in 0..50 {
            assert!(should_emit(&counter, 1));
        }
    }

    #[test]
    fn packet_sample_denominator_zero_emits_every_event() {
        let counter = AtomicU64::new(0);
        for _ in 0..10 {
            assert!(should_emit(&counter, 0));
        }
    }
}
