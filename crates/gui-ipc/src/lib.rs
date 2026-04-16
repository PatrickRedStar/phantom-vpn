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
}

fn default_true() -> bool { true }

impl Default for TunnelSettings {
    fn default() -> Self {
        Self {
            dns_leak_protection: true,
            ipv6_killswitch: true,
            auto_reconnect: true,
        }
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
