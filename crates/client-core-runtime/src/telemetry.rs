//! Telemetry struct + periodic poller task.
//!
//! `Telemetry` holds atomic byte/stream counters that the tunnel hot-path
//! updates lock-free. `telem_task` wakes at 250 ms, computes EMA rates
//! (α = 0.35), derives per-stream activity levels, and publishes a
//! `StatusFrame` to the watch channel for the GUI.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use ghoststream_gui_ipc::{ConnState, StatusFrame};
use tokio::sync::watch;

/// EMA smoothing factor. Higher = faster to new signal, more jitter.
const ALPHA: f64 = 0.35;

/// Live counters for one tunnel attempt. Shared between the dispatcher,
/// per-stream loops, and `telem_task`.
pub struct Telemetry {
    pub started_at: Instant,
    pub bytes_rx: AtomicU64,
    pub bytes_tx: AtomicU64,
    /// Per-stream TX byte counters for activity indicator. Fixed 16-entry
    /// array matches `MAX_N_STREAMS`.
    pub stream_tx_bytes: Vec<AtomicU64>,
    pub n_streams: usize,
    pub streams_alive: Vec<AtomicBool>,
    pub tun_addr: String,
    pub server_addr: String,
    pub sni: String,
    /// Set to `true` by `Manager::disconnect()` to signal an orderly stop.
    pub shutdown: AtomicBool,
}

impl Telemetry {
    pub fn new(
        n_streams: usize,
        tun_addr: String,
        server_addr: String,
        sni: String,
    ) -> Self {
        Self {
            started_at: Instant::now(),
            bytes_rx: AtomicU64::new(0),
            bytes_tx: AtomicU64::new(0),
            stream_tx_bytes: (0..16).map(|_| AtomicU64::new(0)).collect(),
            n_streams,
            streams_alive: (0..16).map(|_| AtomicBool::new(false)).collect(),
            tun_addr,
            server_addr,
            sni,
            shutdown: AtomicBool::new(false),
        }
    }
}

/// Spawn the 250 ms telemetry polling task. Sends `StatusFrame` updates to
/// `status_tx` until `telemetry.shutdown` is set.
pub fn spawn_telem_task(
    telemetry: Arc<Telemetry>,
    status_tx: watch::Sender<StatusFrame>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut last_rx = 0u64;
        let mut last_tx = 0u64;
        let mut last_instant = Instant::now();
        let mut last_per_stream: [u64; 16] = [0; 16];
        let mut ema_rx = 0.0f64;
        let mut ema_tx = 0.0f64;

        loop {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            if telemetry.shutdown.load(Ordering::Relaxed) {
                break;
            }

            let now = Instant::now();
            let dt = now.duration_since(last_instant).as_secs_f64().max(0.001);
            last_instant = now;

            let br = telemetry.bytes_rx.load(Ordering::Relaxed);
            let bt = telemetry.bytes_tx.load(Ordering::Relaxed);
            let drx = br.saturating_sub(last_rx);
            let dtx = bt.saturating_sub(last_tx);
            last_rx = br;
            last_tx = bt;

            let inst_rx_bps = (drx as f64 * 8.0) / dt;
            let inst_tx_bps = (dtx as f64 * 8.0) / dt;
            ema_rx = ema_rx * (1.0 - ALPHA) + inst_rx_bps * ALPHA;
            ema_tx = ema_tx * (1.0 - ALPHA) + inst_tx_bps * ALPHA;

            // Per-stream activity: normalize delta by the max over this window.
            let mut per_stream_delta = [0u64; 16];
            let mut max_delta: u64 = 1;
            for i in 0..16 {
                let v = telemetry.stream_tx_bytes[i].load(Ordering::Relaxed);
                let d = v.saturating_sub(last_per_stream[i]);
                last_per_stream[i] = v;
                per_stream_delta[i] = d;
                if d > max_delta {
                    max_delta = d;
                }
            }
            let mut act = [0.0f32; 16];
            let mut up: u8 = 0;
            for i in 0..16 {
                if telemetry.streams_alive[i].load(Ordering::Relaxed) {
                    up += 1;
                    // Mix normalised activity with a floor so idle streams show faint.
                    let base = (per_stream_delta[i] as f64 / max_delta as f64) as f32;
                    act[i] = (0.12 + 0.88 * base).clamp(0.05, 1.0);
                } else {
                    act[i] = 0.0;
                }
            }

            let mut cur = status_tx.borrow().clone();
            cur.state = ConnState::Connected;
            cur.session_secs = telemetry.started_at.elapsed().as_secs();
            cur.bytes_rx = br;
            cur.bytes_tx = bt;
            cur.rate_rx_bps = ema_rx;
            cur.rate_tx_bps = ema_tx;
            cur.streams_up = up;
            cur.stream_activity = act;
            let _ = status_tx.send(cur);
        }
    })
}
