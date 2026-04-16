//! Tracing → LogFrame fan-out.
//!
//! Install once; every GUI session calls `subscribe()` for its own receiver.
//! A `tracing_subscriber::Layer` captures events, renders a short one-liner
//! via the default `fmt::format::Writer`, and broadcasts them to all live
//! receivers. Backpressure: receivers use bounded mpsc; on overflow we drop.

use ghoststream_gui_ipc::LogFrame;
use std::sync::{Mutex, OnceLock};
use tokio::sync::mpsc;
use tracing::field::{Field, Visit};
use tracing::Event;
use tracing_subscriber::layer::{Context, SubscriberExt};
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

const CHANNEL_CAP: usize = 256;

type Subs = Mutex<Vec<mpsc::Sender<LogFrame>>>;
static SUBS: OnceLock<Subs> = OnceLock::new();

fn subs() -> &'static Subs {
    SUBS.get_or_init(|| Mutex::new(Vec::new()))
}

pub struct LogReceiver {
    rx: mpsc::Receiver<LogFrame>,
}

impl LogReceiver {
    pub async fn recv(&mut self) -> Option<LogFrame> {
        self.rx.recv().await
    }
}

pub fn subscribe() -> LogReceiver {
    let (tx, rx) = mpsc::channel(CHANNEL_CAP);
    let mut g = subs().lock().unwrap();
    g.push(tx);
    LogReceiver { rx }
}

struct BroadcastLayer;

struct MsgVisitor<'a> {
    out: &'a mut String,
}

impl<'a> Visit for MsgVisitor<'a> {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            use std::fmt::Write;
            let _ = write!(self.out, "{:?}", value);
        } else {
            use std::fmt::Write;
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
            tracing::Level::TRACE => "DBG",
        };

        let mut msg = String::new();
        let mut v = MsgVisitor { out: &mut msg };
        event.record(&mut v);

        let frame = LogFrame::now(level, msg);

        let mut g = match subs().lock() { Ok(g) => g, Err(_) => return };
        // Send + drop closed.
        g.retain(|tx| match tx.try_send(frame.clone()) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => true, // keep, just dropped this one
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        });
    }
}

pub fn install() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,helper=debug,phantom_core=info,client_common=info"));

    let stderr_layer = tracing_subscriber::fmt::layer()
        .with_target(false)
        .compact();

    tracing_subscriber::registry()
        .with(filter)
        .with(stderr_layer)
        .with(BroadcastLayer)
        .try_init()
        .ok();
}
