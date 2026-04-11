use thiserror::Error;

#[derive(Debug, Error)]
pub enum PacketError {
    #[error("Packet too short: {0} bytes")]
    TooShort(usize),
    #[error("Invalid inner IP length: {0}")]
    BadIpLen(usize),
    #[error("Buffer too small")]
    BufferTooSmall,
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
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
    #[error("Packet error: {0}")]
    Packet(#[from] PacketError),
    #[error("Config error: {0}")]
    Config(#[from] ConfigError),
    #[error("TUN interface error: {0}")]
    Tun(String),
    #[error("Task join error")]
    Join,
}
