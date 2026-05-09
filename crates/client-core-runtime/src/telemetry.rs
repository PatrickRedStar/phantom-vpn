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

// Extracted for unit tests.
pub(crate) fn compute_ema(prev: f64, inst: f64, alpha: f64) -> f64 {
    prev * (1.0 - alpha) + inst * alpha
}

// Extracted for unit tests. Computes per-stream activity (with 0.12 floor for
// alive idle streams, normalised by max delta) and the count of alive streams.
pub(crate) fn compute_activity(
    per_stream_delta: &[u64; 16],
    alive: &[bool; 16],
) -> ([f32; 16], u8) {
    let mut max_delta: u64 = 1;
    for d in per_stream_delta.iter() {
        if *d > max_delta {
            max_delta = *d;
        }
    }
    let mut act = [0.0f32; 16];
    let mut up: u8 = 0;
    for i in 0..16 {
        if alive[i] {
            up += 1;
            // Mix normalised activity with a floor so idle streams show faint.
            let base = (per_stream_delta[i] as f64 / max_delta as f64) as f32;
            act[i] = (0.12 + 0.88 * base).clamp(0.05, 1.0);
        } else {
            act[i] = 0.0;
        }
    }
    (act, up)
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
            ema_rx = compute_ema(ema_rx, inst_rx_bps, ALPHA);
            ema_tx = compute_ema(ema_tx, inst_tx_bps, ALPHA);

            // Per-stream activity: normalize delta by the max over this window.
            let mut per_stream_delta = [0u64; 16];
            let mut alive = [false; 16];
            for i in 0..16 {
                let v = telemetry.stream_tx_bytes[i].load(Ordering::Relaxed);
                let d = v.saturating_sub(last_per_stream[i]);
                last_per_stream[i] = v;
                per_stream_delta[i] = d;
                alive[i] = telemetry.streams_alive[i].load(Ordering::Relaxed);
            }
            let (act, up) = compute_activity(&per_stream_delta, &alive);

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

            // telemetry.publish — per ADR 0008 §2. TRACE level so it's
            // off by default; flip on with verboseLog or
            // GHOSTSTREAM_LOG=client_core_runtime=trace.
            tracing::trace!(
                category = "telemetry",
                n_streams = telemetry.n_streams as u64,
                streams_up = up as u64,
                rate_rx_bps = ema_rx,
                rate_tx_bps = ema_tx,
                "publish"
            );
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// EMA on a burst should produce a smoothed value: not the peak, not zero,
    /// and monotonically decay back to ~zero on subsequent zero ticks.
    #[test]
    fn test_ewma_smooths_burst() {
        let alpha = ALPHA;
        // Simulated instantaneous bps stream: idle, idle, burst, idle, idle.
        // Pretend dt = 0.25s for each tick (250ms loop), so 1_000_000 bytes
        // gives inst_bps = 1_000_000 * 8 / 0.25 = 32_000_000.
        let series = [0.0_f64, 0.0, 32_000_000.0, 0.0, 0.0];

        let mut ema = 0.0_f64;
        let mut history = Vec::new();
        for inst in series.iter() {
            ema = compute_ema(ema, *inst, alpha);
            history.push(ema);
        }

        // Tick 0,1: still zero (no input).
        assert_eq!(history[0], 0.0);
        assert_eq!(history[1], 0.0);

        // Tick 2 (burst): EMA must be > 0 and strictly less than the peak —
        // exact: 0 * 0.65 + 32_000_000 * 0.35 = 11_200_000.
        let peak = history[2];
        assert!(peak > 0.0, "burst tick produces non-zero EMA");
        assert!(peak < 32_000_000.0, "burst tick stays below instantaneous peak");
        let expected_peak = 32_000_000.0 * alpha;
        assert!(
            (peak - expected_peak).abs() < 1e-6,
            "EMA at burst should equal inst*alpha when prev=0 (got {}, want {})",
            peak,
            expected_peak
        );

        // Tick 3,4 (idle again): EMA must monotonically decay toward 0,
        // staying strictly above 0 (exponential decay never reaches 0).
        assert!(history[3] < history[2], "EMA decays after burst (3 < 2)");
        assert!(history[4] < history[3], "EMA continues decaying (4 < 3)");
        assert!(history[3] > 0.0, "EMA stays positive during decay");
        assert!(history[4] > 0.0, "EMA stays positive during decay");

        // Exact decay: history[3] = peak * (1 - alpha).
        let expected_3 = peak * (1.0 - alpha);
        assert!((history[3] - expected_3).abs() < 1e-6);
    }

    /// Per-stream activity normalises by max delta, applies 0.12 floor for
    /// alive-but-idle streams, and 0.0 for dead streams.
    #[test]
    fn test_per_stream_activity_normalises_by_max() {
        let mut deltas = [0u64; 16];
        let mut alive = [false; 16];
        deltas[0] = 100;
        deltas[1] = 200; // max
        deltas[2] = 50;
        deltas[3] = 0; // dead, will stay 0
        alive[0] = true;
        alive[1] = true;
        alive[2] = true;
        alive[3] = false;

        let (act, up) = compute_activity(&deltas, &alive);

        // streams_up counts alive only.
        assert_eq!(up, 3);

        // Index 1 has max delta -> activity should be max (1.0 after clamp).
        let expected_1 = (0.12_f32 + 0.88 * 1.0).clamp(0.05, 1.0);
        assert!(
            (act[1] - expected_1).abs() < 1e-6,
            "max-delta alive stream activity: got {}, want {}",
            act[1],
            expected_1
        );
        assert!((act[1] - 1.0).abs() < 1e-6);

        // Index 0: 100 / 200 = 0.5 -> 0.12 + 0.88*0.5 = 0.56
        let expected_0 = (0.12_f32 + 0.88 * 0.5).clamp(0.05, 1.0);
        assert!((act[0] - expected_0).abs() < 1e-6);
        assert!((act[0] - 0.56).abs() < 1e-4);

        // Index 2: 50 / 200 = 0.25 -> 0.12 + 0.88*0.25 = 0.34
        let expected_2 = (0.12_f32 + 0.88 * 0.25).clamp(0.05, 1.0);
        assert!((act[2] - expected_2).abs() < 1e-6);
        assert!((act[2] - 0.34).abs() < 1e-4);

        // Index 3 dead -> 0.0.
        assert_eq!(act[3], 0.0);

        // Indices 4..16 also dead -> 0.0.
        for i in 4..16 {
            assert_eq!(act[i], 0.0, "stream {} should be 0.0", i);
        }
    }

    /// All-alive but all-idle case: every alive stream should hit the floor
    /// (0.12) — since per_stream_delta is all 0, max_delta defaults to 1 and
    /// base = 0/1 = 0, giving 0.12 + 0.88*0 = 0.12.
    #[test]
    fn test_alive_idle_streams_hit_floor() {
        let deltas = [0u64; 16];
        let mut alive = [false; 16];
        alive[0] = true;
        alive[5] = true;

        let (act, up) = compute_activity(&deltas, &alive);

        assert_eq!(up, 2);
        assert!(
            (act[0] - 0.12).abs() < 1e-4,
            "alive idle stream should be at the 0.12 floor (got {})",
            act[0]
        );
        assert!((act[5] - 0.12).abs() < 1e-4);
        // Dead stream stays 0.
        assert_eq!(act[1], 0.0);
    }

    /// streams_up counts only alive streams, regardless of delta values.
    #[test]
    fn test_streams_up_counts_only_alive() {
        let deltas = [0u64; 16];
        let mut alive = [false; 16];
        alive[0] = true;
        alive[1] = false;
        alive[2] = true;
        alive[3] = true;
        alive[4] = false;

        let (_act, up) = compute_activity(&deltas, &alive);
        assert_eq!(up, 3);
    }

    /// StatusFrame::default() must have rtt_ms = None — this is the invariant
    /// that ADR 0007 protects (Swift dashboard expects None, not Some(0)).
    #[test]
    fn test_default_status_frame_has_rtt_none() {
        let f = StatusFrame::default();
        assert_eq!(f.rtt_ms, None);
    }
}
