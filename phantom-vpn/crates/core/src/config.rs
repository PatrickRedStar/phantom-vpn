//! Конфигурация: парсинг server.toml и client.toml.
//! Все поля опциональны для упрощения работы с частично заданным конфигом.

use crate::error::ConfigError;
use serde::{Deserialize, Serialize};
use std::path::Path;

// ─── Секция ключей ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct KeysConfig {
    /// Приватный ключ сервера (base64, 32 байта)
    pub server_private_key: Option<String>,
    /// Публичный ключ сервера (base64, 32 байта)
    pub server_public_key:  Option<String>,
    /// Приватный ключ клиента (base64, 32 байта) — только в client.toml
    pub client_private_key: Option<String>,
    /// Публичный ключ клиента (base64, 32 байта) — только в client.toml
    pub client_public_key:  Option<String>,
    /// Общий секрет (base64, 32 байта) — HMAC ключ для SSRC Magic Word
    pub shared_secret:      Option<String>,
}

// ─── Серверная сетевая секция ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerNetworkConfig {
    /// Адрес для прослушивания (default: "0.0.0.0:3478")
    #[serde(default = "default_listen_addr")]
    pub listen_addr: String,
    /// Имя TUN интерфейса (default: "tun0")
    pub tun_name:    Option<String>,
    /// Адрес TUN с маской (default: "10.7.0.1/24")
    pub tun_addr:    Option<String>,
    /// MTU для TUN (default: 1380)
    pub tun_mtu:     Option<u32>,
    /// WAN интерфейс для NAT masquerade (e.g. "eth0")
    pub wan_iface:   Option<String>,
}

impl Default for ServerNetworkConfig {
    fn default() -> Self {
        Self {
            listen_addr: default_listen_addr(),
            tun_name:    None,
            tun_addr:    None,
            tun_mtu:     None,
            wan_iface:   None,
        }
    }
}

// ─── QUIC секция ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct QuicConfig {
    /// Путь к PEM сертификату (если не задан — генерируется self-signed)
    pub cert_path: Option<String>,
    /// Путь к PEM приватному ключу
    pub key_path:  Option<String>,
    /// Subject Alternative Names для self-signed сертификата
    pub cert_subjects: Option<Vec<String>>,
    /// ALPN протокол (default: "h3")
    pub alpn: Option<String>,
    /// Idle timeout в секундах (default: 30)
    pub idle_timeout_secs: Option<u64>,
}

// ─── Клиентская сетевая секция ────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientNetworkConfig {
    /// Адрес сервера (required: "ip:port")
    #[serde(default = "default_server_addr")]
    pub server_addr: String,
    /// Имя хоста сервера для TLS SNI (e.g. "myserver.com")
    pub server_name: Option<String>,
    /// Принимать self-signed сертификаты (default: false)
    #[serde(default)]
    pub insecure: bool,
    /// Имя TUN интерфейса (default: "tun0")
    pub tun_name:    Option<String>,
    /// IP адрес клиента в туннеле (default: "10.7.0.2/24")
    pub tun_addr:    Option<String>,
    /// MTU для TUN (default: 1350)
    pub tun_mtu:     Option<u32>,
    /// Шлюз по умолчанию в туннеле (если задан — добавляем default route)
    pub default_gw:  Option<String>,
}

impl Default for ClientNetworkConfig {
    fn default() -> Self {
        Self {
            server_addr: default_server_addr(),
            server_name: None,
            insecure:    false,
            tun_name:    None,
            tun_addr:    None,
            tun_mtu:     None,
            default_gw:  None,
        }
    }
}

// ─── Таймауты ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TimeoutsConfig {
    /// Время простоя сессии до удаления (секунды, default: 300)
    pub idle_timeout_secs: Option<u64>,
    /// Максимальное время жизни сессии (секунды, default: 86400)
    pub hard_timeout_secs: Option<u64>,
}

// ─── Шейпер ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ShaperConfig {
    /// FPS в строгой фазе WebRTC имитации (default: 30)
    pub fps:             Option<u32>,
    /// Длительность строгой фазы (секунды, default: 5)
    pub strict_phase_secs: Option<u64>,
    /// FPS в режиме покоя (default: 5)
    pub idle_fps:        Option<u32>,
}

// ─── ServerConfig ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ServerConfig {
    #[serde(default)]
    pub network:  ServerNetworkConfig,
    #[serde(default)]
    pub keys:     Option<KeysConfig>,
    #[serde(default)]
    pub timeouts: Option<TimeoutsConfig>,
    #[serde(default)]
    pub shaper:   Option<ShaperConfig>,
    #[serde(default)]
    pub quic:     Option<QuicConfig>,
}

impl ServerConfig {
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
        let content = std::fs::read_to_string(path)?;
        toml::from_str(&content).map_err(|e| ConfigError::Parse(e.to_string()))
    }
}

// ─── ClientConfig ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ClientConfig {
    #[serde(default)]
    pub network: ClientNetworkConfig,
    #[serde(default)]
    pub keys:    Option<KeysConfig>,
    #[serde(default)]
    pub shaper:  Option<ShaperConfig>,
}

impl ClientConfig {
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self, ConfigError> {
        let content = std::fs::read_to_string(path)?;
        toml::from_str(&content).map_err(|e| ConfigError::Parse(e.to_string()))
    }
}

// ─── Defaults ─────────────────────────────────────────────────────────────────

fn default_listen_addr() -> String { "0.0.0.0:443".into() }
fn default_server_addr() -> String { "127.0.0.1:443".into() }
