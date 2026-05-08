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
}

fn default_true() -> bool { true }

impl Default for TunnelSettings {
    fn default() -> Self {
        Self {
            dns_leak_protection: true,
            ipv6_killswitch: true,
            auto_reconnect: true,
            streams: None,
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
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogFrame {
    pub ts_unix_ms: u64,
    /// "OK"/"INF"/"DBG"/"WRN"/"ERR"
    pub level: String,
    pub msg: String,
}

impl LogFrame {
    pub fn now(level: &str, msg: impl Into<String>) -> Self {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        Self { ts_unix_ms: ts, level: level.to_string(), msg: msg.into() }
    }
}
