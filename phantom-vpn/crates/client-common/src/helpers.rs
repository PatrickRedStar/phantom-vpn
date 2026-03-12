//! Общие хелперы клиента: handshake, загрузка ключей из конфига.

use std::sync::Arc;
use anyhow::Context;
use tokio::net::UdpSocket;

use phantom_core::{
    config::ClientConfig,
    crypto::{KeyPair, NoiseHandshake, NoiseSession},
    wire::{SrtpHeader, SRTP_HEADER_LEN, compute_ssrc},
};

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
