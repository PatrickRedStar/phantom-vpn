//! IPC protocol between `ghoststream-gui` (unprivileged) and
//! `ghoststream-helper` (root, spawned via pkexec).
//!
//! Transport: Unix stream socket at `$XDG_RUNTIME_DIR/ghoststream.sock`
//! (typically `/run/user/<uid>/ghoststream.sock`). Wire format: newline-
//! delimited JSON, one message per line. Each side reads LF-terminated
//! frames with `BufReader::read_line`.

use serde::{Deserialize, Serialize};

pub const SOCKET_FILENAME: &str = "ghoststream.sock";

/// Resolve the per-user helper socket path for `uid`.
/// Mirrors systemd's choice of `$XDG_RUNTIME_DIR` (default `/run/user/<uid>`).
pub fn socket_path_for_uid(uid: u32) -> std::path::PathBuf {
    if let Some(rt) = std::env::var_os("XDG_RUNTIME_DIR") {
        let p = std::path::PathBuf::from(rt).join(SOCKET_FILENAME);
        // Only honour env if the directory belongs to this UID (i.e. we're the
        // user). In the helper we pass the explicit UID instead.
        return p;
    }
    std::path::PathBuf::from(format!("/run/user/{}/{}", uid, SOCKET_FILENAME))
}

/// Deterministic path for a given UID, ignoring env — used by the helper when
/// running under pkexec (env is scrubbed).
pub fn socket_path_for_uid_runtime(uid: u32) -> std::path::PathBuf {
    std::path::PathBuf::from(format!("/run/user/{}/{}", uid, SOCKET_FILENAME))
}

// ─── Connection profile (sent by GUI → helper) ──────────────────────────────

/// Per-connection toggles. Defaults match "safe by default" — all three
/// protections ON. `#[serde(default)]` ensures older GUI/helper clients that
/// don't send this field get the safe defaults.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TunnelSettings {
    #[serde(default = "default_true")]
    pub dns_leak_protection: bool,
    #[serde(default = "default_true")]
    pub ipv6_killswitch: bool,
    #[serde(default = "default_true")]
    pub auto_reconnect: bool,
    /// None = automatic CPU-derived stream count; Some(n) is clamped by runtime.
    #[serde(default)]
    pub streams: Option<usize>,
    /// v0.27.0 (W10): kept for backward-compat / debugging — time-based
    /// recycle. Most installs should leave this `None` and use
    /// `dpi_recycle_bytes` instead, which fires only when traffic actually
    /// approaches the carrier's freeze threshold (idle sessions don't get
    /// pointlessly recycled).
    #[serde(default)]
    pub dpi_recycle_secs: Option<u32>,
    /// v0.27.0 (W11): byte-triggered session recycle. When the *total*
    /// payload that has flowed through the tunnel (bytes_rx + bytes_tx)
    /// crosses this threshold, tear down + re-handshake the whole session.
    /// `None` / `Some(0)` = disabled. Recommended value when enabled is
    /// 100_000 (100 KB) — just under the aggregate `8 streams × 14 KB`
    /// threshold that net4people #490 reports as the per-connection
    /// freeze trigger on Russian carrier DPI. Off by default; user opts
    /// in via Settings → "Эксперимент: обход DPI шейпинга".
    ///
    /// Trade-off vs `dpi_recycle_secs`: byte-based fires only on actual
    /// throughput, so an idle tunnel (e.g. user looking at a static page)
    /// doesn't trigger pointless handshakes. Time-based fires regardless
    /// of activity which wastes battery and DPI surface for no benefit.
    #[serde(default)]
    pub dpi_recycle_bytes: Option<u64>,
}

fn default_true() -> bool { true }

impl Default for TunnelSettings {
    fn default() -> Self {
        Self {
            dns_leak_protection: true,
            ipv6_killswitch: true,
            auto_reconnect: true,
            streams: None,
            dpi_recycle_secs: None,
            dpi_recycle_bytes: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tunnel_settings_streams_default_to_auto() {
        let settings: TunnelSettings = serde_json::from_str("{}").unwrap();

        assert_eq!(settings.streams, None);
    }

    #[test]
    fn tunnel_settings_accept_manual_stream_override() {
        let settings: TunnelSettings = serde_json::from_str(r#"{"streams":12}"#).unwrap();

        assert_eq!(settings.streams, Some(12));
    }

    /// ADR 0007 invariant: `rtt_ms == None` MUST round-trip through JSON
    /// (and NOT come back as `Some(0)`). The Swift dashboard distinguishes
    /// "no measurement" from "measurement of zero".
    #[test]
    fn test_status_frame_json_roundtrip_preserves_rtt_none() {
        let frame = StatusFrame {
            rtt_ms: None,
            ..StatusFrame::default()
        };

        let json = serde_json::to_string(&frame).expect("serialize");
        let parsed: StatusFrame = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(parsed.rtt_ms, None, "rtt_ms must remain None across JSON round-trip");

        // Bit-exact equality on every other field.
        assert_eq!(parsed.state, frame.state);
        assert_eq!(parsed.session_secs, frame.session_secs);
        assert_eq!(parsed.bytes_rx, frame.bytes_rx);
        assert_eq!(parsed.bytes_tx, frame.bytes_tx);
        assert_eq!(parsed.rate_rx_bps.to_bits(), frame.rate_rx_bps.to_bits());
        assert_eq!(parsed.rate_tx_bps.to_bits(), frame.rate_tx_bps.to_bits());
        assert_eq!(parsed.n_streams, frame.n_streams);
        assert_eq!(parsed.streams_up, frame.streams_up);
        for i in 0..16 {
            assert_eq!(
                parsed.stream_activity[i].to_bits(),
                frame.stream_activity[i].to_bits(),
                "stream_activity[{}] must round-trip bit-exact",
                i
            );
        }
        assert_eq!(parsed.tun_addr, frame.tun_addr);
        assert_eq!(parsed.server_addr, frame.server_addr);
        assert_eq!(parsed.sni, frame.sni);
        assert_eq!(parsed.last_error, frame.last_error);
        assert_eq!(parsed.reconnect_attempt, frame.reconnect_attempt);
        assert_eq!(parsed.reconnect_next_delay_secs, frame.reconnect_next_delay_secs);
    }

    /// Fully-populated telemetry frame must round-trip without loss — covers
    /// the typical Connected-state payload Swift consumes.
    #[test]
    fn test_status_frame_json_roundtrip_with_full_telemetry() {
        let mut activity = [0.0_f32; 16];
        // Mix: floor, mid, max, ..., trailing zeros (dead streams).
        activity[0] = 0.1;
        activity[1] = 0.5;
        activity[2] = 1.0;
        activity[3] = 0.12;
        activity[4] = 0.34;
        activity[5] = 0.56;
        activity[6] = 0.78;
        activity[7] = 0.9;
        activity[8] = 0.05;
        activity[9] = 0.23;
        // 10..16 stay 0.0 (dead streams past streams_up).

        let frame = StatusFrame {
            state: ConnState::Connected,
            session_secs: 12345,
            bytes_rx: 1_048_576,
            bytes_tx: 524_288,
            // ~16 KB/s expressed as bits/sec: 16384 * 8 = 131072 bps.
            rate_rx_bps: 131072.0,
            rate_tx_bps: 65536.0,
            n_streams: 10,
            streams_up: 10,
            stream_activity: activity,
            rtt_ms: Some(42),
            tun_addr: Some("10.42.0.2/24".to_string()),
            server_addr: Some("89.110.109.128:443".to_string()),
            sni: Some("cdn.example.com".to_string()),
            last_error: None,
            reconnect_attempt: None,
            reconnect_next_delay_secs: None,
            ..StatusFrame::default()
        };

        let json = serde_json::to_string(&frame).expect("serialize");
        let parsed: StatusFrame = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(parsed.state, ConnState::Connected);
        assert_eq!(parsed.session_secs, 12345);
        assert_eq!(parsed.bytes_rx, 1_048_576);
        assert_eq!(parsed.bytes_tx, 524_288);
        // bit-exact float comparison
        assert_eq!(parsed.rate_rx_bps.to_bits(), 131072.0_f64.to_bits());
        assert_eq!(parsed.rate_tx_bps.to_bits(), 65536.0_f64.to_bits());
        assert_eq!(parsed.n_streams, 10);
        assert_eq!(parsed.streams_up, 10);
        for i in 0..16 {
            assert_eq!(
                parsed.stream_activity[i].to_bits(),
                activity[i].to_bits(),
                "stream_activity[{}] must round-trip bit-exact",
                i
            );
        }
        assert_eq!(parsed.rtt_ms, Some(42));
        assert_eq!(parsed.tun_addr.as_deref(), Some("10.42.0.2/24"));
        assert_eq!(parsed.server_addr.as_deref(), Some("89.110.109.128:443"));
        assert_eq!(parsed.sni.as_deref(), Some("cdn.example.com"));
        assert_eq!(parsed.last_error, None);
        assert_eq!(parsed.reconnect_attempt, None);
        assert_eq!(parsed.reconnect_next_delay_secs, None);
    }

    /// ADR 0008: a v1 LogFrame payload (no category, no fields, no
    /// microsecond timestamp) MUST deserialize cleanly and yield safe
    /// defaults for the new v2 fields. Backward compat for Linux /
    /// Android / older helpers.
    #[test]
    fn test_log_frame_v1_payload_deserializes_with_defaults() {
        let v1 = r#"{"ts_unix_ms":1715200000000,"level":"INF","msg":"hello"}"#;
        let parsed: LogFrame =
            serde_json::from_str(v1).expect("v1 LogFrame must deserialize");
        assert_eq!(parsed.ts_unix_ms, 1715200000000);
        assert_eq!(parsed.ts_unix_us, 0); // default
        assert_eq!(parsed.level, "INF");
        assert_eq!(parsed.msg, "hello");
        assert_eq!(parsed.category, None);
        assert!(parsed.fields.is_none());
        // Convenience fallback returns ms*1000 when us is missing.
        assert_eq!(parsed.timestamp_us(), 1715200000000 * 1_000);
    }

    /// ADR 0008: a v2 LogFrame round-trip preserves microsecond
    /// timestamp, category, and structured fields bit-exact.
    #[test]
    fn test_log_frame_v2_structured_roundtrip() {
        let event = LogFrame::structured(
            "DBG",
            "stream",
            "stream opened",
            [
                ("stream_id".to_string(), "3".to_string()),
                ("priority".to_string(), "high".to_string()),
            ],
        );

        let json = serde_json::to_string(&event).expect("serialize");
        let parsed: LogFrame =
            serde_json::from_str(&json).expect("deserialize");

        assert_eq!(parsed, event);
        assert_eq!(parsed.level, "DBG");
        assert_eq!(parsed.category.as_deref(), Some("stream"));
        let fields = parsed.fields.as_ref().expect("fields present");
        assert_eq!(fields.get("stream_id").map(String::as_str), Some("3"));
        assert_eq!(fields.get("priority").map(String::as_str), Some("high"));
        assert!(parsed.ts_unix_us >= parsed.ts_unix_ms.saturating_mul(1_000));
    }

    /// `LogFrame::structured` with empty fields collapses to `None`,
    /// keeping JSON compact and equal to a v1-shape (apart from the
    /// new microsecond timestamp).
    #[test]
    fn test_log_frame_structured_empty_fields_collapse_to_none() {
        let event =
            LogFrame::structured("INF", "tunnel", "started", std::iter::empty());
        assert!(event.fields.is_none());
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectProfile {
    pub name: String,
    /// Full `ghs://…` URL — helper parses it via `client_common`.
    pub conn_string: String,
    /// Connection-time toggles. Defaulted via serde if absent for backcompat.
    #[serde(default)]
    pub settings: TunnelSettings,
}

// ─── Requests (GUI → helper) ────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Connect { profile: ConnectProfile },
    Disconnect,
    GetStatus,
    /// After this is received, helper streams `Response::LogLine` until the
    /// client disconnects.
    SubscribeLogs,
    /// Helper teardown + exit.
    Shutdown,
}

// ─── Responses (helper → GUI) ───────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Ok,
    Error { message: String },
    Status(StatusFrame),
    LogLine(LogFrame),
    /// Helper is about to exit (e.g. after Shutdown or fatal error).
    Bye,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnState {
    Disconnected,
    Connecting,
    /// Waiting for auto-reconnect backoff between attempts. Details (attempt
    /// number, delay) in `StatusFrame::reconnect_*`.
    Reconnecting,
    Connected,
    Error,
}

impl ConnState {
    pub fn as_ui_word(self) -> &'static str {
        match self {
            ConnState::Disconnected => "Dormant",
            ConnState::Connecting => "Handshaking",
            ConnState::Reconnecting => "Regrouping",
            ConnState::Connected => "Transmitting",
            ConnState::Error => "Severed",
        }
    }
}

/// Fine-grained health classification for a `Connected` tunnel. Honest
/// signal for the UI: even when `ConnState::Connected`, the underlying
/// transport may be silent (`Stale`), partially throttled (`Degraded`),
/// or mid-recovery (`Reconnecting`). New in v0.24.0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TunnelHealth {
    #[default]
    Healthy,
    /// `Connected` but no RX traffic for > stale threshold (typically 20s).
    Stale,
    /// `Connected`, traffic flowing but bandwidth is heavily reduced.
    Degraded,
    /// Recovering — runtime decided to reconnect but UI still on Connected lifecycle.
    Reconnecting,
}

/// Coarse bandwidth class, derived from peak-vs-current rate. `Throttled`
/// is set when sustained throughput drops below 20% of session peak while
/// traffic is still flowing — typical signature of DPI shaping (~128 kbit/s).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BandwidthClass {
    #[default]
    Normal,
    Throttled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusFrame {
    pub state: ConnState,
    pub session_secs: u64,
    pub bytes_rx: u64,
    pub bytes_tx: u64,
    /// Exponentially-weighted moving average, bits/sec.
    pub rate_rx_bps: f64,
    pub rate_tx_bps: f64,
    pub n_streams: u8,
    pub streams_up: u8,
    /// 0..1 per-stream activity; entries past `n_streams` are 0.
    pub stream_activity: [f32; 16],
    pub rtt_ms: Option<u32>,
    pub tun_addr: Option<String>,
    pub server_addr: Option<String>,
    pub sni: Option<String>,
    /// Last error message (cleared on successful Connect).
    pub last_error: Option<String>,
    /// Current reconnect attempt (1-based). `None` if not reconnecting.
    #[serde(default)]
    pub reconnect_attempt: Option<u32>,
    /// Seconds until the next reconnect attempt. `None` if not waiting.
    #[serde(default)]
    pub reconnect_next_delay_secs: Option<u32>,
    /// Unix-ms timestamp of last byte received from server. `0` if no
    /// RX yet this session. New in v0.24.0.
    #[serde(default)]
    pub last_rx_ms: u64,
    /// Unix-ms timestamp of last byte transmitted to server. `0` if no
    /// TX yet this session. New in v0.24.0.
    #[serde(default)]
    pub last_tx_ms: u64,
    /// Seconds since `last_rx_ms`. Derived for UI convenience so clients
    /// don't have to do their own wall-clock math each frame. `0` when no
    /// RX has happened yet. New in v0.24.0.
    #[serde(default)]
    pub idle_rx_secs: u32,
    /// Fine-grained health classification for a `Connected` tunnel.
    /// New in v0.24.0.
    #[serde(default)]
    pub health: TunnelHealth,
    /// Coarse bandwidth class — `Throttled` flags suspected DPI shaping.
    /// New in v0.24.0.
    #[serde(default)]
    pub bandwidth_class: BandwidthClass,
}

impl Default for StatusFrame {
    fn default() -> Self {
        Self {
            state: ConnState::Disconnected,
            session_secs: 0,
            bytes_rx: 0,
            bytes_tx: 0,
            rate_rx_bps: 0.0,
            rate_tx_bps: 0.0,
            n_streams: 0,
            streams_up: 0,
            stream_activity: [0.0; 16],
            rtt_ms: None,
            tun_addr: None,
            server_addr: None,
            sni: None,
            last_error: None,
            reconnect_attempt: None,
            reconnect_next_delay_secs: None,
            last_rx_ms: 0,
            last_tx_ms: 0,
            idle_rx_secs: 0,
            health: TunnelHealth::Healthy,
            bandwidth_class: BandwidthClass::Normal,
        }
    }
}

/// Structured log event. v2 (per ADR 0008) extends v1 with
/// microsecond timestamp, optional `category` label, and an optional
/// `fields` map of stringified key-value attributes. Old consumers
/// continue to read `ts_unix_ms` + `level` + `msg`; the new fields use
/// `#[serde(default)]` for backward compat.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LogFrame {
    /// Legacy millisecond timestamp. Kept as the primary field for v1
    /// compatibility; new code prefers `ts_unix_us` when present.
    pub ts_unix_ms: u64,

    /// Microsecond Unix timestamp. New in v2. Defaults to 0 when
    /// missing — consumers should fall back to `ts_unix_ms * 1_000`.
    #[serde(default)]
    pub ts_unix_us: u64,

    /// 3-char level code: "ERR" / "WRN" / "INF" / "DBG" / "TRC".
    /// "OK" is accepted as a legacy alias for INF.
    pub level: String,

    /// Free-form human-readable message.
    pub msg: String,

    /// Logical category. New in v2. One of: "tunnel", "handshake",
    /// "stream", "packet", "telemetry", "tun", "ipc", "settings",
    /// "runtime", "ffi". `None` = uncategorized.
    #[serde(default)]
    pub category: Option<String>,

    /// Structured fields: small map (<10 entries typical) of stringified
    /// values. New in v2.
    #[serde(default)]
    pub fields: Option<std::collections::BTreeMap<String, String>>,
}

impl LogFrame {
    /// v1 constructor. Builds a `LogFrame` with current timestamp and no
    /// category/fields. Prefer `LogFrame::structured` for new code.
    pub fn now(level: &str, msg: impl Into<String>) -> Self {
        let (ms, us) = current_timestamps();
        Self {
            ts_unix_ms: ms,
            ts_unix_us: us,
            level: level.to_string(),
            msg: msg.into(),
            category: None,
            fields: None,
        }
    }

    /// v2 constructor: structured event with category and key-value
    /// fields. Use this from `tracing` subscribers and any new event
    /// site. See ADR 0008 for the canonical category/event taxonomy.
    pub fn structured<S, F>(
        level: &str,
        category: &str,
        msg: S,
        fields: F,
    ) -> Self
    where
        S: Into<String>,
        F: IntoIterator<Item = (String, String)>,
    {
        let (ms, us) = current_timestamps();
        let map: std::collections::BTreeMap<String, String> =
            fields.into_iter().collect();
        let fields = if map.is_empty() { None } else { Some(map) };
        Self {
            ts_unix_ms: ms,
            ts_unix_us: us,
            level: level.to_string(),
            msg: msg.into(),
            category: Some(category.to_string()),
            fields,
        }
    }

    /// Convenience: microsecond timestamp, falling back to ms*1000 for
    /// v1 frames where the field defaulted to 0.
    pub fn timestamp_us(&self) -> u64 {
        if self.ts_unix_us != 0 {
            self.ts_unix_us
        } else {
            self.ts_unix_ms.saturating_mul(1_000)
        }
    }
}

fn current_timestamps() -> (u64, u64) {
    let dur = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let ms = dur.as_millis() as u64;
    let us = (dur.as_micros() as u64).max(ms.saturating_mul(1_000));
    (ms, us)
}
