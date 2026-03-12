use thiserror::Error;

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("Noise protocol error: {0}")]
    Noise(#[from] snow::Error),
    #[error("HMAC computation failed")]
    Hmac,
    #[error("Key rotation in progress")]
    Rekeying,
    #[error("Session not found")]
    NoSession,
    #[error("Invalid key length: expected {expected}, got {got}")]
    InvalidKeyLen { expected: usize, got: usize },
}

#[derive(Debug, Error)]
pub enum PacketError {
    #[error("Packet too short: {0} bytes (need >= 12)")]
    TooShort(usize),
    #[error("Invalid SSRC: {0:#010x}")]
    InvalidSsrc(u32),
    #[error("Replay detected: seq={0}")]
    Replay(u16),
    #[error("Packet timestamp too old: diff={0}s")]
    StaleTimestamp(u32),
    #[error("Decryption failed")]
    DecryptFailed,
    #[error("Invalid inner IP length: {0}")]
    BadIpLen(usize),
    #[error("MTU exceeded: {packet} > {max}")]
    MtuExceeded { packet: usize, max: usize },
    #[error("Buffer too small")]
    BufferTooSmall,
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Error)]
pub enum ShaperError {
    #[error("Distribution error: {0}")]
    Distribution(String),
    #[error("Channel closed")]
    ChannelClosed,
}

#[derive(Debug, Error)]
pub enum MtuError {
    #[error("Packet too short for IP header")]
    TooShort,
    #[error("Unsupported IP version: {0}")]
    UnsupportedVersion(u8),
    #[error("No TCP MSS option found")]
    NoMssOption,
    #[error("Invalid TCP header")]
    InvalidTcpHeader,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("TOML parse error: {0}")]
    Toml(#[from] toml::de::Error),
    #[error("Parse error: {0}")]
    Parse(String),
    #[error("Missing field: {0}")]
    MissingField(&'static str),
    #[error("Invalid base64 key: {0}")]
    InvalidKey(String),
}

#[derive(Debug, Error)]
pub enum TunnelError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Crypto error: {0}")]
    Crypto(#[from] CryptoError),
    #[error("Packet error: {0}")]
    Packet(#[from] PacketError),
    #[error("Shaper error: {0}")]
    Shaper(#[from] ShaperError),
    #[error("Config error: {0}")]
    Config(#[from] ConfigError),
    #[error("TUN interface error: {0}")]
    Tun(String),
    #[error("Task join error")]
    Join,
}
