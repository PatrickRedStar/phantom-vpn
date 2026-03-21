//! Общие хелперы клиента: handshake, загрузка ключей из конфига, connection string.

use std::path::Path;
use anyhow::Context;
use tokio::net::UdpSocket;

use phantom_core::{
    config::{ClientConfig, ClientNetworkConfig, QuicConfig},
    crypto::{KeyPair, NoiseHandshake, NoiseSession},
    wire::{SrtpHeader, SRTP_HEADER_LEN, compute_ssrc},
};
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
///   "cert": "-----BEGIN CERTIFICATE-----\n...",
///   "key": "-----BEGIN EC PRIVATE KEY-----\n...",
///   "ca": "-----BEGIN CERTIFICATE-----\n..."  // optional
/// }
/// ```
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

// ─── Handshake ───────────────────────────────────────────────────────────────

pub async fn perform_handshake(
    socket:        &UdpSocket,
    client_keys:   &KeyPair,
    server_public: &[u8; 32],
    shared_secret: &[u8; 32],
) -> anyhow::Result<(NoiseSession, u32)> {
    // SSRC = HMAC-SHA256(shared_secret, client_pub_key)[0..4]
    let our_ssrc = compute_ssrc(
        shared_secret,
        &client_keys.public_bytes(),
    );

    // Создаём инициатора Noise IK
    let (mut hs, init_msg) = NoiseHandshake::initiate(client_keys, server_public)
        .context("Noise initiate failed")?;

    // Оборачиваем в фейковый SRTP пакет
    let mut pkt = vec![0u8; SRTP_HEADER_LEN + init_msg.len()];
    let hdr = SrtpHeader {
        seq_num:   rand::random(),
        timestamp: rand::random(),
        ssrc:      our_ssrc,
        is_last:   false,
    };
    hdr.write(&mut pkt[..SRTP_HEADER_LEN]);
    pkt[SRTP_HEADER_LEN..].copy_from_slice(&init_msg);

    // Отправляем
    socket.send(&pkt).await.context("Send handshake init failed")?;
    tracing::debug!("Sent handshake init ({} bytes), SSRC={:#010x}", pkt.len(), our_ssrc);

    // Ждём ответа с таймаутом
    let mut resp_buf = vec![0u8; 4096];
    let n = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        socket.recv(&mut resp_buf),
    ).await
        .context("Handshake timeout (10s)")?
        .context("Recv handshake response failed")?;

    tracing::debug!("Received handshake response ({} bytes)", n);

    if n < SRTP_HEADER_LEN {
        anyhow::bail!("Handshake response too short: {} bytes", n);
    }

    let resp_payload = &resp_buf[SRTP_HEADER_LEN..n];

    // Читаем ответ сервера (<- e, ee, se)
    hs.read_response(resp_payload).context("Noise read_response failed")?;

    // Переходим в transport mode
    let session = hs.into_transport().context("Noise into_transport failed")?;

    Ok((session, our_ssrc))
}

// ─── Key helpers ─────────────────────────────────────────────────────────────

pub fn load_client_keys(cfg: &ClientConfig) -> anyhow::Result<KeyPair> {
    if let Some(ref keys) = cfg.keys {
        if let (Some(ref priv_b64), Some(ref pub_b64)) =
            (&keys.client_private_key, &keys.client_public_key)
        {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let private = STANDARD.decode(priv_b64).context("Invalid client_private_key base64")?;
            let public  = STANDARD.decode(pub_b64).context("Invalid client_public_key base64")?;
            tracing::info!("Loaded client keypair from config");
            return Ok(KeyPair { private, public });
        }
    }
    tracing::warn!("No client keys in config — generating ephemeral keys (NOT persistent!)");
    tracing::warn!("Run `phantom-keygen` to generate permanent keys.");
    KeyPair::generate().context("Key generation failed")
}

pub fn load_server_public_key(cfg: &ClientConfig) -> anyhow::Result<[u8; 32]> {
    if let Some(ref keys) = cfg.keys {
        if let Some(ref pub_b64) = keys.server_public_key {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let bytes = STANDARD.decode(pub_b64).context("Invalid server_public_key base64")?;
            if bytes.len() != 32 {
                anyhow::bail!("server_public_key must be 32 bytes (got {})", bytes.len());
            }
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&bytes);
            return Ok(arr);
        }
    }
    anyhow::bail!("server_public_key is required in [keys] config section")
}

pub fn load_shared_secret(cfg: &ClientConfig) -> anyhow::Result<[u8; 32]> {
    if let Some(ref keys) = cfg.keys {
        if let Some(ref secret_b64) = keys.shared_secret {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let bytes = STANDARD.decode(secret_b64).context("Invalid shared_secret base64")?;
            if bytes.len() != 32 {
                anyhow::bail!("shared_secret must be exactly 32 bytes (got {})", bytes.len());
            }
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&bytes);
            return Ok(arr);
        }
    }
    tracing::warn!("No shared_secret in config — using zero secret (INSECURE!)");
    Ok([0u8; 32])
}
