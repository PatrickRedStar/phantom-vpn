//! phantom-server: точка входа.
//! Инициализирует TUN интерфейс, настраивает NAT, запускает QUIC сервер.

pub mod sessions;
pub mod tun_iface;
pub mod worker;
pub mod quic_server;

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;

use anyhow::Context;
use clap::Parser;
use tokio::sync::mpsc;
use tokio::io::AsyncWriteExt;

use phantom_core::config::ServerConfig;
use phantom_core::crypto::KeyPair;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(
    name  = "phantom-server",
    about = "PhantomVPN server — QUIC transport with Noise encryption"
)]
struct Args {
    /// Path to TOML config file
    #[arg(short, long, default_value = "config/server.toml")]
    config: String,

    /// Override listen address (e.g. 0.0.0.0:443)
    #[arg(short, long)]
    listen: Option<String>,

    /// Verbose logging
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

// ─── Main ────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Явно выбираем ring как TLS-провайдер — обязательно в rustls 0.23
    // когда в дереве зависимостей присутствуют оба провайдера (ring + aws-lc-rs).
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install ring crypto provider");

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

    tracing::info!("PhantomVPN Server starting (QUIC transport)...");

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

    // ─── TLS сертификаты ──────────────────────────────────────────────────
    let (certs, key) = if let Some(ref qc) = cfg.quic {
        if let (Some(ref cp), Some(ref kp)) = (&qc.cert_path, &qc.key_path) {
            tracing::info!("Loading TLS certificates from PEM files...");
            phantom_core::quic::load_pem_certs(Path::new(cp), Path::new(kp))
                .context("Failed to load PEM certificates")?
        } else {
            let subjects = qc.cert_subjects.clone()
                .unwrap_or_else(|| vec!["localhost".into()]);
            tracing::info!("Generating self-signed certificate for {:?}", subjects);
            phantom_core::quic::self_signed_cert(subjects)
                .context("Failed to generate self-signed cert")?
        }
    } else {
        tracing::info!("No [quic] config section — generating self-signed cert for localhost");
        phantom_core::quic::self_signed_cert(vec!["localhost".into()])
            .context("Failed to generate self-signed cert")?
    };

    let idle_timeout = cfg.quic.as_ref()
        .and_then(|q| q.idle_timeout_secs)
        .unwrap_or(30);

    let server_config = phantom_core::quic::make_server_config(certs, key, idle_timeout)
        .context("Failed to create QUIC server config")?;

    // ─── TUN interface ──────────────────────────────────────────────────────

    let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.1/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

    tracing::info!("Creating TUN interface {} ...", tun_name);
    let tun = tun_iface::TunInterface::create(tun_name)
        .with_context(|| format!("Failed to create TUN interface {}", tun_name))?;
    tun.configure(tun_addr, tun_mtu as u32)
        .with_context(|| "Failed to configure TUN interface")?;
    tracing::info!("TUN {} configured: addr={} mtu={}", tun_name, tun_addr, tun_mtu);

    // Настраиваем NAT если задан WAN интерфейс
    let nat_info = if let Some(ref wan) = cfg.network.wan_iface {
        let subnet = cidr_to_network(tun_addr);
        tun_iface::setup_nat(tun_name, wan, &subnet)
            .unwrap_or_else(|e| tracing::warn!("NAT setup failed (may need root): {}", e));
        tracing::info!("NAT configured: {} -> {} (subnet {})", tun_name, wan, subnet);
        Some((tun_name.to_string(), wan.clone(), subnet))
    } else {
        None
    };

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

    // ─── QUIC endpoint ──────────────────────────────────────────────────────

    tracing::info!("Binding QUIC endpoint on {} ...", listen_addr);
    let endpoint = quinn::Endpoint::server(server_config, listen_addr)
        .with_context(|| format!("Failed to bind QUIC endpoint on {}", listen_addr))?;
    tracing::info!("QUIC endpoint bound on {}", listen_addr);

    // ─── Sessions ───────────────────────────────────────────────────────────
    let sessions = quic_server::new_quic_session_map();
    let idle_secs = cfg.timeouts.as_ref()
        .and_then(|t| t.idle_timeout_secs)
        .unwrap_or(300);
    tokio::spawn(quic_server::cleanup_task(sessions.clone(), idle_secs));

    // ─── TUN → QUIC loop ────────────────────────────────────────────────────
    {
        let sess = sessions.clone();
        tokio::spawn(async move {
            if let Err(e) = quic_server::tun_to_quic_loop(tun_reader, sess).await {
                tracing::error!("tun_to_quic_loop exited: {}", e);
            }
        });
    }

    // ─── Signal handling for graceful shutdown ───────────────────────────────
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    tokio::spawn(async move {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigint = signal(SignalKind::interrupt()).unwrap();
        let mut sigterm = signal(SignalKind::terminate()).unwrap();
        tokio::select! {
            _ = sigint.recv() => { tracing::info!("Received SIGINT, shutting down..."); }
            _ = sigterm.recv() => { tracing::info!("Received SIGTERM, shutting down..."); }
        }
        let _ = shutdown_tx.send(());
    });

    // ─── QUIC accept loop (main) ────────────────────────────────────────────
    tracing::info!("Server ready. Listening on {} (QUIC/UDP)", listen_addr);

    tokio::select! {
        result = quic_server::run_accept_loop(endpoint.clone(), tun_tx, sessions, server_keys) => {
            if let Err(e) = result {
                tracing::error!("Accept loop exited: {}", e);
            }
        }
        _ = shutdown_rx => {
            tracing::info!("Shutdown signal received");
        }
    }

    // ─── Cleanup ────────────────────────────────────────────────────────────
    endpoint.close(0u32.into(), b"server shutdown");
    if let Some((tun, wan, subnet)) = nat_info {
        tun_iface::teardown_nat(&tun, &wan, &subnet);
    }
    tracing::info!("Server stopped.");

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

    tracing::warn!("No server keys in config — generating ephemeral keys (NOT persistent!)");
    tracing::warn!("Run `phantom-keygen` to generate permanent keys and add them to config.");
    KeyPair::generate().context("Key generation failed")
}
