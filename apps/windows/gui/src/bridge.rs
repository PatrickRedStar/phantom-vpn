//! UI ↔ tokio bridge.
//!
//! The Slint event loop runs on the main thread; the tunnel runtime lives
//! in a dedicated tokio worker thread. The two communicate through:
//!
//! * `UiCommand` — user gestures pushed from the UI thread into tokio.
//! * `apply_status_to_ui` / `apply_log_to_ui` — invoked from tokio to
//!   poke fresh data back into the UI through Slint's
//!   `upgrade_in_event_loop` helper (which uses `invoke_from_event_loop`
//!   under the hood, so the actual UI mutation happens on the event-loop
//!   thread).

use std::rc::Rc;
use std::time::Duration;

use ghoststream_gui_ipc::{ConnState, LogFrame, StatusFrame};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel, Weak};

use crate::{LogLine, MainWindow, StreamBar};

/// Maximum number of log lines kept in the UI buffer. Beyond this we drop
/// the oldest to prevent unbounded memory growth on a long-running
/// session — 400 lines is enough to cover ~5 minutes of debug-level
/// chatter, and the user can clear / hide the panel any time.
const LOG_RING_CAPACITY: usize = 400;

/// Commands the UI thread sends into the tokio worker.
#[derive(Debug)]
pub enum UiCommand {
    Connect,
    Disconnect,
    ChangeProfile,
    Quit,
}

/// Maps a `StatusFrame` onto the MainWindow properties. Must be invoked
/// from the event-loop thread (the closure handed to
/// `upgrade_in_event_loop` is).
pub fn apply_status_to_ui(weak: Weak<MainWindow>, status: StatusFrame) {
    let _ = weak.upgrade_in_event_loop(move |w| {
        let (kind, word) = match status.state {
            ConnState::Disconnected => ("disconnected", "Dormant"),
            ConnState::Connecting => ("connecting", "Handshaking"),
            ConnState::Reconnecting => ("connecting", "Regrouping"),
            ConnState::Connected => ("connected", "Transmitting"),
            ConnState::Error => ("error", "Severed"),
        };
        w.set_state_kind(SharedString::from(kind));
        w.set_state_word(SharedString::from(word));
        w.set_session_timer(SharedString::from(format_timer(status.session_secs)));
        w.set_session_active(status.session_secs > 0);

        let (rx_value, rx_unit) = format_rate(status.rate_rx_bps);
        w.set_rx_value(SharedString::from(rx_value));
        w.set_rx_unit(SharedString::from(rx_unit));
        let (tx_value, tx_unit) = format_rate(status.rate_tx_bps);
        w.set_tx_value(SharedString::from(tx_value));
        w.set_tx_unit(SharedString::from(tx_unit));

        w.set_streams_up(status.streams_up as i32);
        w.set_streams_total(status.n_streams.max(1) as i32);

        if let Some(rtt) = status.rtt_ms {
            w.set_rtt_text(SharedString::from(format!("{} ms", rtt)));
        } else {
            w.set_rtt_text(SharedString::from("—"));
        }

        if let Some(server) = status.server_addr.as_deref() {
            w.set_exit_endpoint(SharedString::from(server.to_string()));
        }

        w.set_last_error(SharedString::from(
            status.last_error.as_deref().unwrap_or(""),
        ));

        // Per-stream activity model. `status.n_streams` says how many H2
        // streams the runtime spun up (1..=16, typically 4 for
        // GhostStream). The `stream_activity` array is fixed-size
        // [f32; 16] — entries past `n_streams` are 0. `streams_up` is the
        // count actually carrying data; we mark the first `up` entries
        // as alive and the rest as dead so the UI can dim them.
        let n = (status.n_streams as usize).min(16);
        let up = (status.streams_up as usize).min(n);
        let stream_bars: Vec<StreamBar> = (0..n)
            .map(|i| StreamBar {
                activity: status.stream_activity.get(i).copied().unwrap_or(0.0),
                label: SharedString::from(format!("s{}", i)),
                alive: i < up,
            })
            .collect();
        w.set_streams(ModelRc::new(Rc::new(VecModel::from(stream_bars))));
    });
}

/// Append a single log frame to the UI's log model. Trims to
/// `LOG_RING_CAPACITY` so memory stays bounded.
///
/// The `ModelRc<T>` returned by the Slint binding doesn't expose
/// `as_any()` for a stable downcast in the 1.15 release, so we read all
/// rows out, mutate the snapshot, and reinstall a fresh VecModel. At
/// 400-row cap this is a few dozen microseconds per log — well below
/// the cost of a frame repaint, so the simplicity pays off.
pub fn apply_log_to_ui(weak: Weak<MainWindow>, frame: LogFrame) {
    let line = LogLine {
        ts: SharedString::from(format_ts_short(frame.ts_unix_ms)),
        severity: SharedString::from(normalise_severity(&frame.level)),
        category: SharedString::from(frame.category.as_deref().unwrap_or("")),
        message: SharedString::from(frame.msg),
    };
    let _ = weak.upgrade_in_event_loop(move |w| {
        use slint::Model;
        let logs_model = w.get_logs();
        let mut lines: Vec<LogLine> = (0..logs_model.row_count())
            .filter_map(|i| logs_model.row_data(i))
            .collect();
        if lines.len() >= LOG_RING_CAPACITY {
            lines.remove(0);
        }
        lines.push(line);
        w.set_logs(ModelRc::new(Rc::new(VecModel::from(lines))));
    });
}

/// Reset the UI back to the Idle state. Used after a clean Disconnect or
/// when bootstrapping the worker before the first tunnel has run.
pub fn reset_ui_to_idle(weak: Weak<MainWindow>) {
    let mut frame = StatusFrame::default();
    frame.state = ConnState::Disconnected;
    apply_status_to_ui(weak, frame);
}

/// Replace the log model with a fresh empty VecModel — used when starting
/// a new tunnel session so the panel doesn't accumulate stale lines.
pub fn clear_logs(weak: Weak<MainWindow>) {
    let _ = weak.upgrade_in_event_loop(|w| {
        w.set_logs(ModelRc::new(Rc::new(VecModel::from(Vec::<LogLine>::new()))));
    });
}

// ── formatters ────────────────────────────────────────────────────────────

fn format_timer(session_secs: u64) -> String {
    let d = Duration::from_secs(session_secs);
    let total = d.as_secs();
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    format!("{:02}:{:02}:{:02}", h, m, s)
}

/// Format a bits/sec rate into (value, unit) suitable for the stats grid.
/// Returns a tuple so the UI can colour the unit separately.
fn format_rate(bps: f64) -> (String, String) {
    let bytes_per_sec = bps / 8.0;
    if bytes_per_sec < 1024.0 {
        (format!("{:.0}", bytes_per_sec.max(0.0)), "B/s".into())
    } else if bytes_per_sec < 1024.0 * 1024.0 {
        (format!("{:.0}", bytes_per_sec / 1024.0), "KB/s".into())
    } else if bytes_per_sec < 1024.0 * 1024.0 * 1024.0 {
        (format!("{:.2}", bytes_per_sec / (1024.0 * 1024.0)), "MB/s".into())
    } else {
        (
            format!("{:.2}", bytes_per_sec / (1024.0 * 1024.0 * 1024.0)),
            "GB/s".into(),
        )
    }
}

/// Render a Unix-ms timestamp as `HH:MM:SS` for the log panel. We
/// deliberately drop milliseconds to keep lines narrow — the runtime
/// already prefixes every event with a microsecond-resolution timestamp
/// in `LogFrame::ts_unix_us` for the structured sink, so the UI display
/// can be coarse.
fn format_ts_short(ts_unix_ms: u64) -> String {
    use std::time::{Duration, UNIX_EPOCH};
    let epoch = UNIX_EPOCH + Duration::from_millis(ts_unix_ms);
    // Pure-stdlib formatting — no `chrono` dep needed for HH:MM:SS.
    // We compute seconds-of-day from the epoch then split.
    let secs = epoch
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let secs_of_day = secs % 86_400;
    let h = secs_of_day / 3600;
    let m = (secs_of_day % 3600) / 60;
    let s = secs_of_day % 60;
    format!("{:02}:{:02}:{:02}", h, m, s)
}

/// Normalise the severity string from `LogFrame::level` to one of the
/// four labels the UI styles. `OK` is the legacy alias for `INF`.
fn normalise_severity(level: &str) -> &'static str {
    match level {
        "ERR" => "ERR",
        "WRN" => "WRN",
        "DBG" => "DBG",
        "TRC" => "DBG", // collapse trace into DBG colour
        _ => "INF",     // "INF" / "OK" / unknown
    }
}
