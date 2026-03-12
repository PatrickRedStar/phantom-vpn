//! phantom-server: точка входа.
//! Инициализирует TUN интерфейс, настраивает NAT, запускает UDP RX loop и TUN→UDP loop.

pub mod sessions;
pub mod tun_iface;
pub mod worker;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use clap::Parser;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::io::AsyncWriteExt;

use phantom_core::config::ServerConfig;
use phantom_core::crypto::KeyPair;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(
    name  = "phantom-server",
    about = "PhantomVPN server — WebRTC/SRTP masquerade VPN"
)]
struct Args {
    /// Path to TOML config file
    #[arg(short, long, default_value = "config/server.toml")]
    config: String,

    /// Override listen address (e.g. 0.0.0.0:3478)
    #[arg(short, long)]
    listen: Option<String>,

    /// Verbose logging
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

// ─── Main ────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Инициализация tracing
    let level = match args.verbose {
        0 => tracing::Level::INFO,
        1 => tracing::Level::DEBUG,
        _ => tracing::Level::TRACE,
    };
    tracing_subscriber::fmt()
        .with_max_level(level)
        .with_target(false)
        .compact()
        .init();

    tracing::info!("PhantomVPN Server starting...");

    // Загрузка конфига
    let cfg = if std::path::Path::new(&args.config).exists() {
        ServerConfig::from_file(&args.config)
            .with_context(|| format!("Failed to load config: {}", args.config))?
    } else {
        tracing::warn!("Config file not found ({}), using defaults", args.config);
        ServerConfig::default()
    };

    tracing::info!("Config loaded: listen={}", cfg.network.listen_addr);

    // Override listen addr from CLI if provided
    let listen_addr: SocketAddr = if let Some(ref la) = args.listen {
        la.parse().context("Invalid --listen address")?
    } else {
        cfg.network.listen_addr.parse().context("Invalid config listen_addr")?
    };

    // Загрузка ключей
    let server_keys = Arc::new(load_or_generate_keys(&cfg)?);
    tracing::info!("Server public key: {}", hex::encode(&server_keys.public));

    // Загрузка shared secret
    let shared_secret = Arc::new(load_shared_secret(&cfg)?);
    tracing::info!("Shared secret loaded ({} bytes)", shared_secret.len());

    // ─── TUN interface ──────────────────────────────────────────────────────

    let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.1/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1380);

    tracing::info!("Creating TUN interface {} ...", tun_name);
    let tun = tun_iface::TunInterface::create(tun_name)
        .with_context(|| format!("Failed to create TUN interface {}", tun_name))?;
    tun.configure(tun_addr, tun_mtu as u32)
        .with_context(|| "Failed to configure TUN interface")?;
    tracing::info!("TUN {} configured: addr={} mtu={}", tun_name, tun_addr, tun_mtu);

    // Настраиваем NAT если задан WAN интерфейс
    if let Some(ref wan) = cfg.network.wan_iface {
        // Вычисляем подсеть из tun_addr (e.g. "10.7.0.1/24" -> "10.7.0.0/24")
        let subnet = cidr_to_network(tun_addr);
        tun_iface::setup_nat(tun_name, wan, &subnet)
            .unwrap_or_else(|e| tracing::warn!("NAT setup failed (may need root): {}", e));
        tracing::info!("NAT configured: {} -> {} (subnet {})", tun_name, wan, subnet);
    }

    // Wrap TUN в async
    let async_tun = tun_iface::AsyncTun::new(tun.into_file())
        .context("Failed to create async TUN")?;
    let (tun_reader, mut tun_writer) = tokio::io::split(async_tun);

    // MPSC канал: worker (RX) → TUN writer
    let (tun_tx, mut tun_rx) = mpsc::channel::<Vec<u8>>(1024);

    // ─── TUN writer task ────────────────────────────────────────────────────
    tokio::spawn(async move {
        while let Some(pkt) = tun_rx.recv().await {
            if let Err(e) = tun_writer.write_all(&pkt).await {
                tracing::error!("TUN write error: {}", e);
            }
        }
        tracing::warn!("TUN writer channel closed");
    });

    // ─── UDP socket ─────────────────────────────────────────────────────────

    tracing::info!("Binding UDP socket on {} ...", listen_addr);
    let socket = Arc::new(
        UdpSocket::bind(listen_addr).await
            .with_context(|| format!("Failed to bind UDP socket on {}", listen_addr))?
    );
    tracing::info!("UDP socket bound on {}", listen_addr);

    // ─── Sessions ───────────────────────────────────────────────────────────
    let sessions = sessions::new_session_map();
    let idle_secs = cfg.timeouts.as_ref()
        .and_then(|t| t.idle_timeout_secs)
        .unwrap_or(300);
    tokio::spawn(sessions::cleanup_task(sessions.clone(), idle_secs));

    // ─── TUN → UDP loop ─────────────────────────────────────────────────────
    {
        let sock2     = socket.clone();
        let sess2     = sessions.clone();
        tokio::spawn(async move {
            if let Err(e) = worker::tun_to_udp_loop(tun_reader, sock2, sess2).await {
                tracing::error!("tun_to_udp_loop exited: {}", e);
            }
        });
    }

    // ─── RX loop (main) ─────────────────────────────────────────────────────
    tracing::info!("Server ready. Listening on {}", listen_addr);
    worker::rx_loop(socket, tun_tx, sessions, server_keys, shared_secret).await?;

    Ok(())
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// "10.7.0.1/24" → "10.7.0.0/24"
fn cidr_to_network(cidr: &str) -> String {
    let parts: Vec<&str> = cidr.split('/').collect();
    if parts.len() != 2 { return cidr.to_string(); }
    let ip_parts: Vec<&str> = parts[0].split('.').collect();
    if ip_parts.len() != 4 { return cidr.to_string(); }
    format!("{}.{}.{}.0/{}", ip_parts[0], ip_parts[1], ip_parts[2], parts[1])
}

fn load_or_generate_keys(cfg: &ServerConfig) -> anyhow::Result<KeyPair> {
    if let Some(ref keys_cfg) = cfg.keys {
        if let (Some(ref priv_b64), Some(ref pub_b64)) =
            (&keys_cfg.server_private_key, &keys_cfg.server_public_key)
        {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let private = STANDARD.decode(priv_b64)
                .context("Invalid base64 in server_private_key")?;
            let public  = STANDARD.decode(pub_b64)
                .context("Invalid base64 in server_public_key")?;
            tracing::info!("Loaded server keypair from config");
            return Ok(KeyPair { private, public });
        }
    }

    // Ключ не задан — генерируем и предупреждаем
    tracing::warn!("No server keys in config — generating ephemeral keys (NOT persistent!)");
    tracing::warn!("Run `phantom-keygen` to generate permanent keys and add them to config.");
    KeyPair::generate().context("Key generation failed")
}

fn load_shared_secret(cfg: &ServerConfig) -> anyhow::Result<[u8; 32]> {
    if let Some(ref keys_cfg) = cfg.keys {
        if let Some(ref secret_b64) = keys_cfg.shared_secret {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let bytes = STANDARD.decode(secret_b64)
                .context("Invalid base64 in shared_secret")?;
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
