//! Telemetry struct + periodic poller task.
//!
//! `Telemetry` holds atomic byte/stream counters that the tunnel hot-path
//! updates lock-free. `telem_task` wakes at 250 ms, computes EMA rates
//! (α = 0.35), derives per-stream activity levels, and publishes a
//! `StatusFrame` to the watch channel for the GUI.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use ghoststream_gui_ipc::{BandwidthClass, ConnState, StatusFrame, TunnelHealth};
use tokio::sync::watch;

/// EMA smoothing factor. Higher = faster to new signal, more jitter.
const ALPHA: f64 = 0.35;

/// Idle threshold above which `Connected` is downgraded to `Stale` for UI
/// honesty. Matches `RX_IDLE_TIMEOUT_SECS` minus a tick of slack so the
/// UI flips to Stale shortly before the runtime triggers a forced reconnect.
const STALE_IDLE_SECS: u32 = 18;

// ── TSPU-128 signature detector (v0.26.5) ────────────────────────────────
//
// Russian TSPU (the DPI middleboxes deployed by Roskomnadzor) implements
// throttling by dropping client→server ACK packets, which collapses the
// TCP congestion window to a steady fixed rate. For TCP/H2 the documented
// rate is 128 kbps (Meduza 2024-08-06, U. Michigan IMC paper, ValdikSS).
// QUIC is throttled to ~512 kbps but our transport is TCP/H2, so we only
// look for the 128 kbps signature.
//
// Detection rule: rate sits inside the 100-160 kbps band for ≥ 10 s of
// continuous RX activity → throttled. Recovers when rate clears 320 kbps
// (2× the band ceiling — well outside any plausible TSPU shaping).
//
// This replaces v0.25.1's ratio-vs-peak heuristic which false-positived
// hard on bursty browsing: a single page-load burst pinned the lifetime
// peak high, then natural idle reading dropped below 20 % × peak and
// flipped UI to "Throttled" while the tunnel was perfectly healthy.
//
// The signature is narrow on purpose — it catches the specific TSPU
// behaviour we care about (the same machine that targets googlevideo,
// twitter.com, etc.) without crying wolf on natural traffic variation.

/// Lower edge of the TSPU 128 kbps signature band.
const TSPU_BAND_MIN_BPS: f64 = 100_000.0;

/// Upper edge of the TSPU 128 kbps signature band. 160 leaves headroom
/// for EMA smoothing and small jitter without false-matching above-band
/// real traffic.
const TSPU_BAND_MAX_BPS: f64 = 160_000.0;

/// Consecutive 250 ms ticks the rate must stay in-band before flipping
/// to Throttled. 40 ticks = 10 s. Lower → faster detect, more flicker;
/// higher → laggy. 10 s matches the warmup we already lose anyway.
const TSPU_STABLE_TICKS: u32 = 40;

/// Recovery threshold. Rate above this clearly means TSPU isn't pinning
/// us — 2× the band ceiling.
const TSPU_RECOVERY_BPS: f64 = 320_000.0;

/// Session must be at least this old before we trust the detector. Gives
/// the tunnel time to actually push bytes; first few seconds rate is
/// noisy by nature of EMA warmup.
const THROTTLE_WARMUP_SECS: u64 = 10;

/// Returns current wall-clock Unix time in milliseconds. Saturates on
/// pre-epoch clocks (shouldn't happen but defensive).
#[inline]
pub fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Live counters for one tunnel attempt. Shared between the dispatcher,
/// per-stream loops, and `telem_task`.
pub struct Telemetry {
    pub started_at: Instant,
    pub bytes_rx: AtomicU64,
    pub bytes_tx: AtomicU64,
    /// Unix-ms timestamp of the last RX byte. `0` = no RX yet this session.
    /// Updated by `telem_task` whenever `bytes_rx` advances; granularity
    /// is the 250 ms tick which is fine for UI staleness UX.
    pub last_rx_unix_ms: AtomicU64,
    /// Unix-ms timestamp of the last TX byte. `0` = no TX yet.
    pub last_tx_unix_ms: AtomicU64,
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
            last_rx_unix_ms: AtomicU64::new(0),
            last_tx_unix_ms: AtomicU64::new(0),
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

/// Compute `health` based on connection state and idle RX seconds.
///
/// Pure function — exposed for unit tests. Behaviour:
/// - non-`Connected` state stays as caller intended (`Reconnecting`
///   matches the connection-state, others stay `Healthy`).
/// - `Connected` + `idle_rx_secs > STALE_IDLE_SECS` → `Stale`.
/// - `Connected` + `bandwidth_class == Throttled` → `Degraded`.
/// - Otherwise → `Healthy`.
pub(crate) fn derive_health(
    state: ConnState,
    idle_rx_secs: u32,
    bandwidth_class: BandwidthClass,
) -> TunnelHealth {
    match state {
        ConnState::Reconnecting => TunnelHealth::Reconnecting,
        ConnState::Connected => {
            if idle_rx_secs > STALE_IDLE_SECS {
                TunnelHealth::Stale
            } else if bandwidth_class == BandwidthClass::Throttled {
                TunnelHealth::Degraded
            } else {
                TunnelHealth::Healthy
            }
        }
        _ => TunnelHealth::Healthy,
    }
}

/// Compute `bandwidth_class` from the TSPU-128 signature.
///
/// State machine, pure function — exposed for unit tests:
///   - Gate: not Connected, warmup not over, or RX idle > 5 s → reset
///     stable counter, force `Normal`. No detection during dead time.
///   - In-band (100-160 kbps): increment stable counter. ≥ 40 ticks
///     of continuous in-band → flip to `Throttled`.
///   - Above recovery (320 kbps): reset stable counter, flip back to
///     `Normal` if we were Throttled.
///   - Below band but above zero (transient dip, e.g. user mid-scroll):
///     freeze the counter, keep current state.
///
/// Returns `(new_class, new_stable_in_band)` — caller threads the counter
/// through successive ticks.
pub(crate) fn derive_bandwidth_class(
    current_class: BandwidthClass,
    cur_rx_bps: f64,
    stable_in_band: u32,
    session_secs: u64,
    state: ConnState,
    idle_rx_secs: u32,
) -> (BandwidthClass, u32) {
    if state != ConnState::Connected
        || session_secs < THROTTLE_WARMUP_SECS
        || idle_rx_secs > 5
    {
        return (BandwidthClass::Normal, 0);
    }

    let in_band = (TSPU_BAND_MIN_BPS..=TSPU_BAND_MAX_BPS).contains(&cur_rx_bps);
    let above_recovery = cur_rx_bps > TSPU_RECOVERY_BPS;

    let next_counter = if in_band {
        stable_in_band.saturating_add(1)
    } else if above_recovery {
        0
    } else {
        // Below band but not clearly above recovery — natural dip, hold.
        stable_in_band
    };

    let next_class = match current_class {
        BandwidthClass::Normal if next_counter >= TSPU_STABLE_TICKS => BandwidthClass::Throttled,
        BandwidthClass::Throttled if above_recovery => BandwidthClass::Normal,
        other => other,
    };

    // Once we recover, the next sample needs a fresh streak to flip back.
    let final_counter = if next_class == BandwidthClass::Normal && current_class == BandwidthClass::Throttled {
        0
    } else {
        next_counter
    };

    (next_class, final_counter)
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
        let mut bandwidth_class = BandwidthClass::Normal;
        // v0.26.5: TSPU-128 signature detector — counts consecutive ticks
        // where the RX rate sits inside the 100-160 kbps band. Flips to
        // Throttled at TSPU_STABLE_TICKS (= 40 ticks = 10 s).
        let mut stable_in_band: u32 = 0;

        loop {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            // v0.25.1 (W3-8): Acquire matches the SeqCst Release semantics
            // used by `Manager::disconnect()` / supervisor cancel paths.
            // Relaxed could in theory let this task observe an *older* value
            // of `shutdown` than the byte/peak counters carry — Acquire
            // makes the synchronisation explicit and trivially correct.
            if telemetry.shutdown.load(Ordering::Acquire) {
                break;
            }

            let now = Instant::now();
            let dt = now.duration_since(last_instant).as_secs_f64().max(0.001);
            last_instant = now;
            let now_ms = now_unix_ms();

            let br = telemetry.bytes_rx.load(Ordering::Relaxed);
            let bt = telemetry.bytes_tx.load(Ordering::Relaxed);
            let drx = br.saturating_sub(last_rx);
            let dtx = bt.saturating_sub(last_tx);
            last_rx = br;
            last_tx = bt;

            // Stamp last_rx/tx_unix_ms on any byte movement this tick.
            // Granularity = 250 ms, plenty for UI staleness UX. Stamping
            // here (vs. inside the hot RX/TX path) keeps the path lock-free.
            if drx > 0 {
                telemetry.last_rx_unix_ms.store(now_ms, Ordering::Relaxed);
            }
            if dtx > 0 {
                telemetry.last_tx_unix_ms.store(now_ms, Ordering::Relaxed);
            }

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

            // ── Honesty derivation ───────────────────────────────────────
            let last_rx_ms = telemetry.last_rx_unix_ms.load(Ordering::Relaxed);
            let last_tx_ms = telemetry.last_tx_unix_ms.load(Ordering::Relaxed);
            let idle_rx_secs: u32 = if last_rx_ms == 0 {
                0
            } else {
                now_ms.saturating_sub(last_rx_ms).saturating_div(1000) as u32
            };
            let session_secs = telemetry.started_at.elapsed().as_secs();

            let mut cur = status_tx.borrow().clone();
            cur.state = ConnState::Connected;
            cur.session_secs = session_secs;
            cur.bytes_rx = br;
            cur.bytes_tx = bt;
            cur.rate_rx_bps = ema_rx;
            cur.rate_tx_bps = ema_tx;
            cur.streams_up = up;
            cur.stream_activity = act;
            cur.last_rx_ms = last_rx_ms;
            cur.last_tx_ms = last_tx_ms;
            cur.idle_rx_secs = idle_rx_secs;

            // TSPU-128 signature classification. Log on edge changes.
            let (new_bw, new_counter) = derive_bandwidth_class(
                bandwidth_class,
                ema_rx,
                stable_in_band,
                session_secs,
                cur.state,
                idle_rx_secs,
            );
            stable_in_band = new_counter;
            if new_bw != bandwidth_class {
                let cur_kbps = (ema_rx / 1000.0) as u64;
                if new_bw == BandwidthClass::Throttled {
                    tracing::warn!(
                        category = "network",
                        event = "throttle.detected",
                        cur_kbps = cur_kbps,
                        "TSPU-128 signature: RX held in 100-160 kbps band for 10 s — shaping suspected (cur {} kbps)",
                        cur_kbps,
                    );
                } else {
                    tracing::info!(
                        category = "network",
                        event = "throttle.recovered",
                        cur_kbps = cur_kbps,
                        "bandwidth recovered to {} kbps — TSPU signature cleared",
                        cur_kbps,
                    );
                }
                bandwidth_class = new_bw;
            }
            cur.bandwidth_class = bandwidth_class;
            cur.health = derive_health(cur.state, idle_rx_secs, bandwidth_class);

            // v0.25.0: re-check shutdown right before publish. Without this, a
            // frame with state=Connected can ship after supervise has already
            // initiated graceful shutdown — widgets flash green for ~250 ms
            // after the user hits Disconnect.
            // v0.25.1 (W3-8): Acquire (see comment at top of loop) so that
            // any `shutdown.store(true, ...)` on another thread is reliably
            // observable here even under aggressive reordering.
            if telemetry.shutdown.load(Ordering::Acquire) {
                break;
            }
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
                idle_rx_secs = idle_rx_secs as u64,
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

    /// Health derivation: Connected + idle <= threshold → Healthy.
    #[test]
    fn test_health_connected_fresh_traffic_is_healthy() {
        assert_eq!(
            derive_health(ConnState::Connected, 5, BandwidthClass::Normal),
            TunnelHealth::Healthy,
        );
    }

    /// Health derivation: Connected + idle > threshold → Stale.
    #[test]
    fn test_health_connected_long_idle_is_stale() {
        assert_eq!(
            derive_health(ConnState::Connected, 25, BandwidthClass::Normal),
            TunnelHealth::Stale,
        );
    }

    /// Health derivation: Connected + Throttled (with fresh traffic) → Degraded.
    #[test]
    fn test_health_connected_throttled_is_degraded() {
        assert_eq!(
            derive_health(ConnState::Connected, 3, BandwidthClass::Throttled),
            TunnelHealth::Degraded,
        );
    }

    /// Health derivation: stale beats throttled — stale is the louder signal.
    #[test]
    fn test_health_stale_beats_throttled() {
        assert_eq!(
            derive_health(ConnState::Connected, 25, BandwidthClass::Throttled),
            TunnelHealth::Stale,
        );
    }

    /// Health derivation: Reconnecting → Reconnecting regardless of idle.
    #[test]
    fn test_health_reconnecting_propagates() {
        assert_eq!(
            derive_health(ConnState::Reconnecting, 1, BandwidthClass::Normal),
            TunnelHealth::Reconnecting,
        );
    }

    /// Throttle detection: warmup window suppresses early in-band ticks.
    #[test]
    fn test_throttle_warmup_holds_normal() {
        let (class, counter) = derive_bandwidth_class(
            BandwidthClass::Normal,
            128_000.0, // smack in the TSPU band
            100,       // stale-but-pre-warmup counter — should be wiped
            5,         // session 5s — still warming up
            ConnState::Connected,
            0,
        );
        assert_eq!(class, BandwidthClass::Normal);
        assert_eq!(counter, 0, "warmup gate must reset the counter");
    }

    /// TSPU signature: 40 consecutive in-band ticks → Throttled.
    #[test]
    fn test_throttle_signature_flips_after_stable_window() {
        let mut class = BandwidthClass::Normal;
        let mut counter: u32 = 0;
        // Simulate 40 ticks at 128 kbps — exactly the TSPU TCP rate.
        for tick in 0..TSPU_STABLE_TICKS {
            let (c, n) = derive_bandwidth_class(
                class,
                128_000.0,
                counter,
                30, // well past warmup
                ConnState::Connected,
                0,
            );
            class = c;
            counter = n;
            // Should hold Normal until the last tick crosses the threshold.
            if tick + 1 < TSPU_STABLE_TICKS {
                assert_eq!(class, BandwidthClass::Normal, "tick {} too early", tick);
            }
        }
        assert_eq!(class, BandwidthClass::Throttled);
        assert_eq!(counter, TSPU_STABLE_TICKS);
    }

    /// TSPU signature: out-of-band rates never accumulate enough to flip.
    /// This is the test that v0.25.1's ratio-vs-peak would have failed —
    /// bursty browsing (200-2000 kbps) is normal, not throttled.
    #[test]
    fn test_throttle_bursty_traffic_no_false_positive() {
        let bursty_pattern = [
            300_000.0,   // 300 kbps — above band
            1_800_000.0, // 1.8 Mbps burst
            500_000.0,
            80_000.0, // dip below band, but isolated
            2_000_000.0,
            400_000.0,
        ];
        let mut class = BandwidthClass::Normal;
        let mut counter: u32 = 0;
        // Repeat 100x — well past TSPU_STABLE_TICKS.
        for cycle in 0..100 {
            for rate in bursty_pattern {
                let (c, n) = derive_bandwidth_class(
                    class,
                    rate,
                    counter,
                    30,
                    ConnState::Connected,
                    0,
                );
                class = c;
                counter = n;
            }
            assert_eq!(
                class,
                BandwidthClass::Normal,
                "cycle {} bursty pattern flipped to Throttled (counter={})",
                cycle,
                counter,
            );
        }
    }

    /// Recovery: once we're Throttled, a rate above 320 kbps clears it
    /// and resets the counter so we need a fresh streak to flip back.
    #[test]
    fn test_throttle_recovers_above_band_ceiling() {
        let (class, counter) = derive_bandwidth_class(
            BandwidthClass::Throttled,
            500_000.0, // above TSPU_RECOVERY_BPS
            TSPU_STABLE_TICKS,
            300,
            ConnState::Connected,
            0,
        );
        assert_eq!(class, BandwidthClass::Normal);
        assert_eq!(counter, 0, "recovery must reset the counter");
    }

    /// Below-band but not clearly recovered: transient dip during scroll.
    /// Counter freezes, state holds — neither flips nor recovers spuriously.
    #[test]
    fn test_throttle_below_band_holds_state() {
        // Normal state, transient 80 kbps dip — should NOT advance counter.
        let (class, counter) = derive_bandwidth_class(
            BandwidthClass::Normal,
            80_000.0, // below band
            17,       // mid-streak from earlier in-band run
            30,
            ConnState::Connected,
            0,
        );
        assert_eq!(class, BandwidthClass::Normal);
        assert_eq!(counter, 17, "below-band dip must freeze counter");
    }

    /// Idle RX ≠ throttled: if the user just isn't requesting anything,
    /// don't blame the network. Counter resets so re-warmup is honest.
    #[test]
    fn test_throttle_ignores_pure_idle() {
        let (class, counter) = derive_bandwidth_class(
            BandwidthClass::Normal,
            0.0,
            25, // counter mid-streak
            300,
            ConnState::Connected,
            30, // idle for 30s — natural, not throttled
        );
        assert_eq!(class, BandwidthClass::Normal);
        assert_eq!(counter, 0, "idle gate resets the counter");
    }

    /// Disconnect mid-detection wipes state — no Throttled label after
    /// reconnect needs to be earned fresh.
    #[test]
    fn test_throttle_non_connected_state_resets() {
        let (class, counter) = derive_bandwidth_class(
            BandwidthClass::Throttled,
            128_000.0,
            TSPU_STABLE_TICKS,
            300,
            ConnState::Reconnecting,
            0,
        );
        assert_eq!(class, BandwidthClass::Normal);
        assert_eq!(counter, 0);
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
