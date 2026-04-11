//! Общие хелперы клиента: загрузка конфига, ключей, connection string.

use std::path::Path;
use anyhow::Context;

use phantom_core::config::{ClientConfig, ClientNetworkConfig, QuicConfig};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

// ─── CLI Args ────────────────────────────────────────────────────────────────

#[derive(clap::Parser, Debug)]
#[command(
    name  = "phantom-client",
    about = "PhantomVPN client — WebRTC/SRTP masquerade VPN"
)]
pub struct Args {
    /// Path to TOML config file
    #[arg(short, long, default_value = "config/client.toml")]
    pub config: String,

    /// Override server address (e.g. 1.2.3.4:3478)
    #[arg(short, long)]
    pub server: Option<String>,

    /// Base64url connection string (overrides config file)
    #[arg(long)]
    pub conn_string: Option<String>,

    /// File containing base64url connection string
    #[arg(long)]
    pub conn_string_file: Option<String>,

    /// Verbose logging
    #[arg(short, long, action = clap::ArgAction::Count)]
    pub verbose: u8,

    /// Transport override: "quic", "h2", or "auto"
    #[arg(long)]
    pub transport: Option<String>,
}

// ─── Init logging ────────────────────────────────────────────────────────────

pub fn init_logging(verbose: u8) {
    let level = match verbose {
        0 => tracing::Level::INFO,
        1 => tracing::Level::DEBUG,
        _ => tracing::Level::TRACE,
    };
    tracing_subscriber::fmt()
        .with_max_level(level)
        .with_target(false)
        .compact()
        .init();
}

// ─── Load config ─────────────────────────────────────────────────────────────

pub fn load_config(path: &str) -> anyhow::Result<ClientConfig> {
    if std::path::Path::new(path).exists() {
        ClientConfig::from_file(path)
            .with_context(|| format!("Failed to load config: {}", path))
    } else {
        tracing::warn!("Config file not found ({}), using defaults", path);
        Ok(ClientConfig::default())
    }
}

// ─── Connection string ──────────────────────────────────────────────────────

/// Parse a base64url-encoded connection string into ClientConfig.
///
/// Connection string JSON format (v1):
/// ```json
/// {
///   "v": 1,
///   "addr": "1.2.3.4:8443",
///   "sni": "example.com",
///   "tun": "10.7.0.4/24",
///   "transport": "h2",
///   "cert": "-----BEGIN CERTIFICATE-----\n...",
///   "key": "-----BEGIN EC PRIVATE KEY-----\n...",
///   "ca": "-----BEGIN CERTIFICATE-----\n..."  // optional
/// }
/// ```
pub fn normalize_transport(value: &str) -> anyhow::Result<String> {
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "h2" | "tls" => Ok("h2".to_string()),
        _ => anyhow::bail!("Unsupported transport: {} (only 'h2' is supported)", value),
    }
}

pub fn parse_conn_string(input: &str) -> anyhow::Result<ClientConfig> {
    let trimmed = input.trim();

    let json_str = if trimmed.starts_with('{') {
        trimmed.to_string()
    } else {
        // base64url → JSON
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
        let bytes = URL_SAFE_NO_PAD.decode(trimmed)
            .context("Invalid base64url in connection string")?;
        String::from_utf8(bytes).context("Connection string is not valid UTF-8")?
    };

    let obj: serde_json::Value = serde_json::from_str(&json_str)
        .context("Invalid JSON in connection string")?;

    let addr = obj["addr"].as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing 'addr' in connection string"))?;
    let sni = obj["sni"].as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing 'sni' in connection string"))?;
    let tun = obj["tun"].as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing 'tun' in connection string"))?;
    let cert = obj["cert"].as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing 'cert' in connection string"))?;
    let key = obj["key"].as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing 'key' in connection string"))?;
    let ca = obj["ca"].as_str(); // optional
    let transport = match obj["transport"].as_str() {
        Some(value) => normalize_transport(value)?,
        None => "h2".to_string(),
    };

    let mut quic = QuicConfig {
        cert_pem: Some(cert.to_string()),
        key_pem: Some(key.to_string()),
        ..Default::default()
    };
    if let Some(ca_pem) = ca {
        quic.ca_cert_pem = Some(ca_pem.to_string());
    }

    // Extract gateway from tun addr (e.g. "10.7.0.4/24" → "10.7.0.1")
    let default_gw = tun.split('/').next()
        .and_then(|ip| {
            let parts: Vec<&str> = ip.split('.').collect();
            if parts.len() == 4 {
                Some(format!("{}.{}.{}.1", parts[0], parts[1], parts[2]))
            } else {
                None
            }
        });

    Ok(ClientConfig {
        network: ClientNetworkConfig {
            server_addr: addr.to_string(),
            server_name: Some(sni.to_string()),
            insecure: false,
            tun_name: None,
            tun_addr: Some(tun.to_string()),
            tun_mtu: Some(1350),
            default_gw,
        },
        transport: Some(transport),
        keys: None,
        shaper: None,
        quic: Some(quic),
    })
}

/// Load connection string from CLI args (--conn-string or --conn-string-file).
/// Returns None if neither is set.
pub fn load_conn_string(args: &Args) -> anyhow::Result<Option<ClientConfig>> {
    if let Some(ref cs) = args.conn_string {
        return Ok(Some(parse_conn_string(cs)?));
    }
    if let Some(ref path) = args.conn_string_file {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read conn-string file: {}", path))?;
        return Ok(Some(parse_conn_string(&content)?));
    }
    Ok(None)
}

// ─── TLS identity loading ───────────────────────────────────────────────────

/// Load client TLS identity (cert + key) from config.
/// Checks inline PEM first, then file paths.
pub fn load_tls_identity(
    cfg: &ClientConfig,
) -> anyhow::Result<Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>> {
    if let Some(ref qc) = cfg.quic {
        // Inline PEM has priority
        if let (Some(ref cert_pem), Some(ref key_pem)) = (&qc.cert_pem, &qc.key_pem) {
            tracing::info!("Loading client TLS certificate from inline PEM");
            let identity = phantom_core::quic::parse_pem_identity(
                cert_pem.as_bytes(), key_pem.as_bytes(),
            ).context("Failed to parse inline client TLS certificate")?;
            return Ok(Some(identity));
        }
        // Fallback to file paths
        if let (Some(ref cp), Some(ref kp)) = (&qc.cert_path, &qc.key_path) {
            tracing::info!("Loading client TLS certificate from {}", cp);
            let identity = phantom_core::quic::load_pem_certs(Path::new(cp), Path::new(kp))
                .context("Failed to load client TLS certificate")?;
            return Ok(Some(identity));
        }
    }
    Ok(None)
}

/// Load server CA cert from config.
/// Checks inline PEM first, then file path.
pub fn load_server_ca(
    cfg: &ClientConfig,
) -> anyhow::Result<Option<Vec<CertificateDer<'static>>>> {
    if let Some(ref qc) = cfg.quic {
        // Inline PEM has priority
        if let Some(ref ca_pem) = qc.ca_cert_pem {
            tracing::info!("Loading server CA cert from inline PEM");
            let certs = phantom_core::quic::parse_pem_cert_chain(ca_pem.as_bytes())
                .context("Failed to parse inline CA cert")?;
            return Ok(Some(certs));
        }
        // Fallback to file path
        if let Some(ref ca_path) = qc.ca_cert_path {
            let certs = phantom_core::quic::load_pem_cert_chain(Path::new(ca_path))
                .context("Failed to load server CA cert")?;
            return Ok(Some(certs));
        }
    }
    Ok(None)
}

