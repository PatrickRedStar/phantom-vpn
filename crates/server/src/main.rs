//! phantom-server: точка входа.
//! Инициализирует TUN интерфейс, настраивает NAT, запускает QUIC сервер.

pub mod sessions;
pub mod tun_iface;
pub mod worker;
pub mod quic_server;
pub mod admin;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Context;
use clap::Parser;
use tokio::sync::mpsc;
use tokio::io::AsyncWriteExt;

use phantom_core::config::ServerConfig;

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

    // Load CA cert for mTLS client verification (if configured)
    let client_ca = if let Some(ref ca_path) = cfg.quic.as_ref().and_then(|q| q.ca_cert_path.clone()) {
        tracing::info!("Loading client CA cert from {}", ca_path);
        Some(phantom_core::quic::load_pem_cert_chain(Path::new(ca_path))
            .context("Failed to load client CA cert")?)
    } else {
        tracing::warn!("No ca_cert_path in [quic] config — client authentication disabled");
        None
    };

    let server_config = phantom_core::quic::make_server_config(certs, key, idle_timeout, client_ca)
        .context("Failed to create QUIC server config")?;

    // ─── TUN interface ──────────────────────────────────────────────────────

    let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.1/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

    // ─── Multiqueue TUN + io_uring I/O ──────────────────────────────────────
    let n_queues: usize = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);

    tracing::info!("Creating TUN {} with {} queue(s)...", tun_name, n_queues);

    let mut tun_fds: Vec<std::os::unix::io::RawFd> = Vec::new();
    if n_queues > 1 {
        let (tun_main, extra) = tun_iface::TunInterface::create_multiqueue(tun_name, n_queues)
            .with_context(|| format!("Failed to create multiqueue TUN {}", tun_name))?;
        tun_main.configure(tun_addr, tun_mtu as u32)?;

        let f0 = tun_main.into_file();
        tun_fds.push(std::os::unix::io::AsRawFd::as_raw_fd(&f0));
        std::mem::forget(f0);
        for f in extra {
            tun_fds.push(std::os::unix::io::AsRawFd::as_raw_fd(&f));
            std::mem::forget(f);
        }
    } else {
        let tun = tun_iface::TunInterface::create(tun_name)
            .with_context(|| format!("Failed to create TUN {}", tun_name))?;
        tun.configure(tun_addr, tun_mtu as u32)?;
        let f = tun.into_file();
        tun_fds.push(std::os::unix::io::AsRawFd::as_raw_fd(&f));
        std::mem::forget(f);
    }
    tracing::info!("TUN {} configured: addr={} mtu={}", tun_name, tun_addr, tun_mtu);

    // NAT
    let nat_info = if let Some(ref wan) = cfg.network.wan_iface {
        let subnet = cidr_to_network(tun_addr);
        let exit_ip = cfg.network.exit_ip.as_deref();
        tun_iface::teardown_nat(tun_name, wan, &subnet, exit_ip);
        tun_iface::setup_nat(tun_name, wan, &subnet, exit_ip)
            .unwrap_or_else(|e| tracing::warn!("NAT setup failed: {}", e));
        Some((tun_name.to_string(), wan.clone(), subnet, exit_ip.map(str::to_string)))
    } else {
        None
    };

    let (mut tun_read_rx, tun_tx) = phantom_core::tun_uring::spawn_multiqueue(tun_fds, 4096)
        .context("Failed to start io_uring TUN handler")?;

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

    // ─── Client allowlist (fingerprint-based) ────────────────────────────
    let allow_list = quic_server::new_allow_list();
    let allow_list_path = cfg.quic.as_ref()
        .and_then(|q| q.allowed_clients_path.clone());

    if let Some(ref path) = allow_list_path {
        match quic_server::load_allow_list(Path::new(path)) {
            Ok(fps) => {
                tracing::info!("Loaded {} allowed client fingerprints from {}", fps.len(), path);
                *allow_list.write().await = fps;
            }
            Err(e) => {
                tracing::warn!("Failed to load client allowlist from {}: {} — allowing all", path, e);
            }
        }
    } else {
        tracing::info!("No allowed_clients_path configured — all authenticated clients accepted");
    }

    // SIGHUP → hot-reload allowlist
    {
        let allow_list = allow_list.clone();
        let path = allow_list_path.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sighup = signal(SignalKind::hangup()).unwrap();
            while sighup.recv().await.is_some() {
                if let Some(ref p) = path {
                    match quic_server::load_allow_list(Path::new(p)) {
                        Ok(fps) => {
                            tracing::info!("SIGHUP: reloaded {} allowed fingerprints from {}", fps.len(), p);
                            *allow_list.write().await = fps;
                        }
                        Err(e) => {
                            tracing::error!("SIGHUP: failed to reload {}: {}", p, e);
                        }
                    }
                }
            }
        });
    }

    // ─── Admin HTTP API ──────────────────────────────────────────────────────────
    if let Some(ref admin_cfg) = cfg.admin {
        if let Some(ref token) = admin_cfg.token {
            let listen_str = admin_cfg.listen_addr.as_deref().unwrap_or("10.7.0.1:8080");
            match listen_str.parse::<SocketAddr>() {
                Ok(admin_addr) => {
                    // Resolve server SNI from cert path
                    let server_name = cfg.quic.as_ref()
                        .and_then(|q| q.cert_path.as_deref())
                        .and_then(|p| {
                            // Extract domain from /etc/letsencrypt/live/<domain>/fullchain.pem
                            p.split('/').find(|s| s.contains('.') && !s.contains("letsencrypt")).map(String::from)
                        })
                        .unwrap_or_else(|| cfg.network.listen_addr.clone());

                    let ca_cert_path = admin_cfg.ca_cert_path.as_ref()
                        .map(PathBuf::from)
                        .or_else(|| cfg.quic.as_ref().and_then(|q| q.ca_cert_path.as_deref()).map(PathBuf::from));
                    let ca_key_path = admin_cfg.ca_key_path.as_ref()
                        .map(PathBuf::from)
                        .or_else(|| ca_cert_path.as_ref().map(|p| p.with_extension("key")));

                    let admin_state = admin::AdminState {
                        sessions: sessions.clone(),
                        clients_path: PathBuf::from(cfg.quic.as_ref()
                            .and_then(|q| q.allowed_clients_path.as_deref())
                            .unwrap_or("/opt/phantom-vpn/config/clients.json")),
                        token: token.clone(),
                        started_at: std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs(),
                        allow_list: allow_list.clone(),
                        ca_cert_path,
                        ca_key_path,
                        server_addr: cfg.network.listen_addr.clone(),
                        server_name,
                    };
                    tokio::spawn(async move {
                        if let Err(e) = admin::run(admin_addr, admin_state).await {
                            tracing::error!("Admin server error: {}", e);
                        }
                    });
                }
                Err(e) => tracing::warn!("Invalid admin listen_addr '{}': {}", listen_str, e),
            }
        }
    }

    // ─── TUN → QUIC loop (io_uring reader feeds directly) ─────────────────
    {
        let sess = sessions.clone();
        tokio::spawn(async move {
            if let Err(e) = quic_server::tun_to_quic_loop(tun_read_rx, sess).await {
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

    let (tun_network, tun_prefix) = parse_cidr(tun_addr).unwrap_or_else(|| {
        tracing::warn!("Could not parse tun_addr CIDR '{}', defaulting to 10.7.0.0/24", tun_addr);
        ("10.7.0.0".parse().unwrap(), 24)
    });

    tokio::select! {
        result = quic_server::run_accept_loop(endpoint.clone(), tun_tx, sessions, tun_network, tun_prefix, allow_list) => {
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
    if let Some((tun, wan, subnet, exit_ip)) = nat_info {
        tun_iface::teardown_nat(&tun, &wan, &subnet, exit_ip.as_deref());
    }
    tracing::info!("Server stopped.");

    Ok(())
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// "10.7.0.1/24" → (Ipv4Addr("10.7.0.0"), 24)
fn parse_cidr(cidr: &str) -> Option<(std::net::Ipv4Addr, u8)> {
    let (ip_str, prefix_str) = cidr.split_once('/')?;
    let ip: std::net::Ipv4Addr = ip_str.parse().ok()?;
    let prefix: u8 = prefix_str.parse().ok()?;
    let mask: u32 = if prefix == 0 { 0 } else { !0u32 << (32 - prefix) };
    let network = std::net::Ipv4Addr::from(u32::from(ip) & mask);
    Some((network, prefix))
}

/// "10.7.0.1/24" → "10.7.0.0/24"
fn cidr_to_network(cidr: &str) -> String {
    let parts: Vec<&str> = cidr.split('/').collect();
    if parts.len() != 2 { return cidr.to_string(); }
    let ip_parts: Vec<&str> = parts[0].split('.').collect();
    if ip_parts.len() != 4 { return cidr.to_string(); }
    format!("{}.{}.{}.0/{}", ip_parts[0], ip_parts[1], ip_parts[2], parts[1])
}

