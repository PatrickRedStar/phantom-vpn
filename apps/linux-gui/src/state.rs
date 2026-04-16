//! Slint property bridge + real telemetry state.
//!
//! All UI mutations happen on the Slint event loop thread, pumped via
//! `slint::invoke_from_event_loop`. The tokio runtime owns the IPC socket
//! and profile store; UI callbacks forward into it through an mpsc channel
//! of `UiCommand`s; telemetry flows back through `UiEvent`s.

use slint::{ModelRc, SharedString, VecModel};
use std::collections::VecDeque;
use std::fmt::Write;

use ghoststream_gui_ipc::{ConnState, LogFrame, StatusFrame};

use crate::MainWindow;

pub const MAX_LOG_LINES: usize = 20_000;
/// Small tail shown in the right rail.
pub const RIGHT_RAIL_TAIL: usize = 24;
pub const TRACE_WINDOW: usize = 300; // 60s @ 5Hz

pub struct ViewState {
    pub rx_samples: VecDeque<f32>,
    pub tx_samples: VecDeque<f32>,
    pub rx_peak_bps: f64,
    pub tx_peak_bps: f64,
    pub logs: VecDeque<LogFrame>,
    pub last_status: StatusFrame,
}

impl ViewState {
    pub fn new() -> Self {
        Self {
            rx_samples: VecDeque::from(vec![0.0; TRACE_WINDOW]),
            tx_samples: VecDeque::from(vec![0.0; TRACE_WINDOW]),
            rx_peak_bps: 1.0,
            tx_peak_bps: 1.0,
            logs: VecDeque::new(),
            last_status: StatusFrame::default(),
        }
    }

    pub fn push_rate(&mut self, rx_bps: f64, tx_bps: f64) {
        // Adaptive peak: slowly decay so the scope re-scales after a burst
        // drops off. 2.5% decay per tick ≈ 10 s half-life at 4 Hz.
        self.rx_peak_bps = (self.rx_peak_bps * 0.975).max(rx_bps).max(1_000_000.0);
        self.tx_peak_bps = (self.tx_peak_bps * 0.975).max(tx_bps).max(1_000_000.0);

        let rx_norm = (rx_bps / self.rx_peak_bps).clamp(0.0, 1.0) as f32;
        let tx_norm = (tx_bps / self.tx_peak_bps).clamp(0.0, 1.0) as f32;
        self.rx_samples.pop_front();
        self.tx_samples.pop_front();
        self.rx_samples.push_back(rx_norm);
        self.tx_samples.push_back(tx_norm);
    }

    pub fn push_log(&mut self, l: LogFrame) {
        self.logs.push_back(l);
        if self.logs.len() > MAX_LOG_LINES {
            let n = self.logs.len() - MAX_LOG_LINES;
            for _ in 0..n { self.logs.pop_front(); }
        }
    }
}

pub fn seed_static(window: &MainWindow) {
    window.set_link_node("—".into());
    window.set_rtt("—".into());
    window.set_cipher("TLS_AES_256_GCM".into());
    window.set_mtu("1350".into());
    window.set_sni("—".into());
    window.set_state_label("TUNNEL STATE".into());
    window.set_state_main("Dormant".into());
    window.set_state_kind("disconnected".into());
    window.set_session_timer("00:00:00".into());
    window.set_rx_label("0.0".into());
    window.set_tx_label("0.0".into());
    window.set_footer_health("● IDLE".into());
}

pub fn apply_status(window: &MainWindow, view: &mut ViewState, s: &StatusFrame) {
    view.last_status = s.clone();

    let (kind, word) = match s.state {
        ConnState::Disconnected => ("disconnected", "Dormant"),
        ConnState::Connecting   => ("connecting",   "Handshaking"),
        ConnState::Reconnecting => ("connecting",   "Regrouping"),
        ConnState::Connected    => ("connected",    "Transmitting"),
        ConnState::Error        => ("error",        "Severed"),
    };
    window.set_state_kind(kind.into());
    window.set_state_main(word.into());

    window.set_last_error(
        s.last_error.clone().unwrap_or_default().into()
    );

    window.set_session_timer(format_hms(s.session_secs).into());

    // Oscilloscope sample push (4 Hz — match helper cadence).
    view.push_rate(s.rate_rx_bps, s.rate_tx_bps);
    window.set_rx_path(samples_to_path(&view.rx_samples).into());
    window.set_tx_path(samples_to_path(&view.tx_samples).into());

    window.set_rx_label(format!("{:.1}", s.rate_rx_bps / 1_000_000.0).into());
    window.set_tx_label(format!("{:.1}", s.rate_tx_bps / 1_000_000.0).into());

    // Per-stream activity bars.
    use crate::StreamBar;
    let n = s.n_streams as usize;
    let mut bars: Vec<StreamBar> = Vec::with_capacity(n.max(1));
    for i in 0..n {
        bars.push(StreamBar {
            activity: s.stream_activity[i],
            label: SharedString::from(format!("s{}", i)),
            alive: i < s.streams_up as usize,
        });
    }
    window.set_streams(ModelRc::new(VecModel::from(bars)));

    // Session KV rows.
    use crate::KvRow;
    let rows = vec![
        KvRow { key: "Assigned".into(),     value: s.tun_addr.clone().unwrap_or_else(|| "—".into()).into(), accent: false },
        KvRow { key: "Server".into(),       value: s.server_addr.clone().unwrap_or_else(|| "—".into()).into(), accent: false },
        KvRow { key: "SNI".into(),          value: s.sni.clone().unwrap_or_else(|| "—".into()).into(), accent: false },
        KvRow { key: "Transport".into(),    value: "H2 / TLS 1.3 / TCP".into(), accent: false },
        KvRow { key: "Streams".into(),      value: format!("{}/{}", s.streams_up, s.n_streams).into(), accent: false },
        KvRow { key: "Bytes in".into(),     value: humanize_bytes(s.bytes_rx).into(), accent: true  },
        KvRow { key: "Bytes out".into(),    value: humanize_bytes(s.bytes_tx).into(), accent: false },
    ];
    window.set_session_rows(ModelRc::new(VecModel::from(rows)));

    // Ticker up top.
    window.set_link_node(s.server_addr.clone().unwrap_or_else(|| "—".into()).into());
    window.set_sni(s.sni.clone().unwrap_or_else(|| "—".into()).into());
    window.set_rtt(match s.rtt_ms { Some(v) => format!("{} ms", v).into(), None => SharedString::from("—") });
    window.set_footer_health(match s.state {
        ConnState::Connected    => "● NOMINAL".into(),
        ConnState::Connecting   => "◐ CONNECTING".into(),
        ConnState::Reconnecting => "◐ REGROUPING".into(),
        ConnState::Error        => "⚠ FAULT".into(),
        ConnState::Disconnected => "● IDLE".into(),
    });
}

pub fn apply_logs(window: &MainWindow, view: &ViewState) {
    use crate::LogEntry;
    let model: Vec<LogEntry> = view.logs.iter().rev().take(RIGHT_RAIL_TAIL).rev().map(|l| {
        let kind = match l.level.as_str() {
            "OK"  => "ok",
            "INF" => "info",
            "DBG" => "debug",
            "WRN" => "warn",
            "ERR" => "warn",
            _     => "info",
        };
        LogEntry {
            ts:    short_ts(l.ts_unix_ms).into(),
            level: l.level.clone().into(),
            msg:   l.msg.clone().into(),
            tag:   "".into(),
            kind:  kind.to_string().into(),
        }
    }).collect();
    window.set_logs(ModelRc::new(VecModel::from(model)));
}

fn format_hms(secs: u64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    format!("{:02}:{:02}:{:02}", h, m, s)
}

fn short_ts(unix_ms: u64) -> String {
    let secs = unix_ms / 1000;
    let h = (secs / 3600) % 24;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    format!("{:02}:{:02}:{:02}", h, m, s)
}

fn humanize_bytes(n: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;
    if n >= GB { format!("{:.2} GB", n as f64 / GB as f64) }
    else if n >= MB { format!("{:.2} MB", n as f64 / MB as f64) }
    else if n >= KB { format!("{:.1} KB", n as f64 / KB as f64) }
    else { format!("{} B", n) }
}

fn samples_to_path(samples: &VecDeque<f32>) -> String {
    if samples.is_empty() { return String::new(); }
    let mut out = String::with_capacity(samples.len() * 12);
    let n = samples.len();
    let denom = (n - 1).max(1) as f32;
    for (i, s) in samples.iter().enumerate() {
        let x = (i as f32 / denom) * 100.0;
        let y = 100.0 - s.clamp(0.0, 1.0) * 100.0;
        let cmd = if i == 0 { 'M' } else { 'L' };
        let _ = write!(out, "{}{:.2} {:.2} ", cmd, x, y);
    }
    out
}

// ── Logs screen (full buffer) projection ───────────────────────────────────

fn level_rank(l: &str) -> u8 {
    match l {
        "TRC" | "TRACE" => 0,
        "DBG" | "DEBUG" => 1,
        "INF" | "OK" | "INFO" => 2,
        "WRN" | "WARN" => 3,
        "ERR" | "ERROR" => 4,
        _ => 2,
    }
}

fn level_threshold(name: &str) -> u8 {
    match name {
        "ALL" | "TRACE" => 0,
        "DEBUG" => 1,
        "INFO" => 2,
        "WARN" => 3,
        "ERROR" => 4,
        _ => 2,
    }
}

pub fn level_cycle_next(cur: &str) -> &'static str {
    match cur {
        "ALL" => "TRACE",
        "TRACE" => "DEBUG",
        "DEBUG" => "INFO",
        "INFO" => "WARN",
        "WARN" => "ERROR",
        _ => "ALL",
    }
}

pub fn apply_logs_screen(
    window: &MainWindow,
    view: &ViewState,
    level: &str,
    substring: &str,
) {
    use crate::LogEntry;
    let thr = level_threshold(level);
    let needle = substring.trim().to_ascii_lowercase();
    let filtered: Vec<_> = view.logs.iter().filter(|l| {
        if level_rank(l.level.as_str()) < thr { return false; }
        if !needle.is_empty() && !l.msg.to_ascii_lowercase().contains(&needle) {
            return false;
        }
        true
    }).collect();
    // Keep most recent ~2000 lines to stay snappy.
    let skip = filtered.len().saturating_sub(2000);
    let model: Vec<LogEntry> = filtered.into_iter().skip(skip).map(|l| {
        let kind = match l.level.as_str() {
            "OK"  => "ok",
            "INF" => "info",
            "DBG" => "debug",
            "WRN" => "warn",
            "ERR" => "warn",
            _     => "info",
        };
        LogEntry {
            ts:    short_ts(l.ts_unix_ms).into(),
            level: l.level.clone().into(),
            msg:   l.msg.clone().into(),
            tag:   "".into(),
            kind:  kind.to_string().into(),
        }
    }).collect();
    window.set_logs_all(ModelRc::new(VecModel::from(model)));
    window.set_logs_total_lines(view.logs.len() as i32);
}

// ── Profile-row projection for the left rail ────────────────────────────────

pub fn apply_profiles(
    window: &MainWindow,
    store: &crate::profiles::Store,
    live: &StatusFrame,
) {
    use crate::ProfileItem;
    let active_id = store.active_id.clone();
    let items: Vec<ProfileItem> = store.profiles.iter().map(|p| {
        let is_active = Some(&p.id) == active_id.as_ref();
        let connected = is_active && live.state == ConnState::Connected;
        let state_label = if connected {
            "Active".to_string()
        } else if is_active {
            match live.state {
                ConnState::Connecting => "Handshake".into(),
                ConnState::Error      => "Severed".into(),
                _                     => "Selected".into(),
            }
        } else {
            "Standby".into()
        };
        let (rx_label, tx_label) = if connected {
            (format!("{:.1} Mbit", live.rate_rx_bps / 1_000_000.0),
             format!("{:.1} Mbit", live.rate_tx_bps / 1_000_000.0))
        } else {
            ("—".to_string(), "—".to_string())
        };
        ProfileItem {
            name: p.name.clone().into(),
            host: p.server_addr.clone().into(),
            state: state_label.into(),
            is_active,
            ping_ms: live.rtt_ms.map(|v| v as i32).unwrap_or(0),
            ping_text: live.rtt_ms.map(|v| format!("{} ms", v)).unwrap_or_else(|| "—".into()).into(),
            ping_class: SharedString::from(
                match live.rtt_ms {
                    Some(v) if v < 100 => "ok",
                    Some(v) if v < 300 => "mid",
                    _ => "bad",
                }
            ),
            rx_label: rx_label.into(),
            tx_label: tx_label.into(),
        }
    }).collect();
    let count = items.len() as i32;
    window.set_profiles(ModelRc::new(VecModel::from(items)));
    window.set_profile_count(count);
}
