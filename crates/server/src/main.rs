//! phantom-server: точка входа.
//! Инициализирует TUN интерфейс, настраивает NAT, запускает H2/TLS сервер.

pub mod tun_iface;
pub mod vpn_session;
pub mod h2_server;
pub mod admin;
pub mod admin_tls;
pub mod mimicry;
pub mod fakeapp;

use std::net::SocketAddr;
use tokio::net::TcpListener;
use std::path::{Path, PathBuf};

use anyhow::Context;
use clap::Parser;

use phantom_core::config::ServerConfig;

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(
    name  = "phantom-server",
    about = "PhantomVPN server — H2/TLS transport with mTLS"
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

    tracing::info!("PhantomVPN Server starting (H2/TLS transport)...");

    // Загрузка конфига
    let cfg = if std::path::Path::new(&args.config).exists() {
        ServerConfig::from_file(&args.config)
            .with_context(|| format!("Failed to load config: {}", args.config))?
    } else {
        tracing::warn!("Config file not found ({}), using defaults", args.config);
        ServerConfig::default()
    };

    tracing::info!("Config loaded: listen={}", cfg.network.listen_addr);

    // --listen is accepted for backward compatibility but no longer used —
    // the active transport is H2/TLS on [h2].listen_addr. Warn if supplied.
    if args.listen.is_some() {
        tracing::warn!("--listen flag is deprecated (QUIC transport removed); configure [h2].listen_addr instead");
    }

    // ─── TLS сертификаты ──────────────────────────────────────────────────
    let (certs, key) = if let Some(ref qc) = cfg.tls {
        if let (Some(ref cp), Some(ref kp)) = (&qc.cert_path, &qc.key_path) {
            tracing::info!("Loading TLS certificates from PEM files...");
            phantom_core::tls::load_pem_certs(Path::new(cp), Path::new(kp))
                .context("Failed to load PEM certificates")?
        } else {
            let subjects = qc.cert_subjects.clone()
                .unwrap_or_else(|| vec!["localhost".into()]);
            tracing::info!("Generating self-signed certificate for {:?}", subjects);
            phantom_core::tls::self_signed_cert(subjects)
                .context("Failed to generate self-signed cert")?
        }
    } else {
        tracing::info!("No [tls] config section — generating self-signed cert for localhost");
        phantom_core::tls::self_signed_cert(vec!["localhost".into()])
            .context("Failed to generate self-signed cert")?
    };

    // Load CA cert for mTLS client verification (if configured)
    let client_ca = if let Some(ref ca_path) = cfg.tls.as_ref().and_then(|q| q.ca_cert_path.clone()) {
        tracing::info!("Loading client CA cert from {}", ca_path);
        Some(phantom_core::tls::load_pem_cert_chain(Path::new(ca_path))
            .context("Failed to load client CA cert")?)
    } else {
        tracing::warn!("No ca_cert_path in [tls] config — client authentication disabled");
        None
    };

    // ─── HTTP/2 TLS config ─────────────────────────────────────────────────
    let h2_tls_config = phantom_core::h2_transport::make_h2_server_tls(
        certs, key, client_ca
    ).context("Failed to create HTTP/2 TLS config")?;

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
        tun_fds.push(std::os::unix::io::IntoRawFd::into_raw_fd(f0));
        for f in extra {
            tun_fds.push(std::os::unix::io::IntoRawFd::into_raw_fd(f));
        }
    } else {
        let tun = tun_iface::TunInterface::create(tun_name)
            .with_context(|| format!("Failed to create TUN {}", tun_name))?;
        tun.configure(tun_addr, tun_mtu as u32)?;
        let f = tun.into_file();
        tun_fds.push(std::os::unix::io::IntoRawFd::into_raw_fd(f));
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

    let (tun_read_rx, tun_tx) = phantom_core::tun_uring::spawn_multiqueue(tun_fds, 4096)
        .context("Failed to start io_uring TUN handler")?;

    // ─── Sessions ───────────────────────────────────────────────────────────
    let sessions = vpn_session::new_session_map();
    let sessions_by_fp = vpn_session::new_session_by_fp();
    let idle_secs = cfg.timeouts.as_ref()
        .and_then(|t| t.idle_timeout_secs)
        .unwrap_or(300);
    let hard_timeout_secs = cfg.timeouts.as_ref()
        .and_then(|t| t.hard_timeout_secs)
        .unwrap_or(86_400);
    tokio::spawn(vpn_session::cleanup_task(
        sessions.clone(),
        sessions_by_fp.clone(),
        idle_secs,
        hard_timeout_secs,
    ));

    // ─── Client allowlist (fingerprint-based) ────────────────────────────
    let allow_list = vpn_session::new_allow_list();
    let allow_list_path = cfg.tls.as_ref()
        .and_then(|q| q.allowed_clients_path.clone());

    if let Some(ref path) = allow_list_path {
        match vpn_session::load_allow_list(Path::new(path)) {
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

    // Keyring lock: guards all read-modify-write on clients.json
    let keyring_lock: admin::KeyringLock = std::sync::Arc::new(tokio::sync::Mutex::new(()));

    // Subscription expiry checker
    if let Some(ref cp) = allow_list_path {
        let cp2 = std::path::PathBuf::from(cp);
        let sessions2 = sessions.clone();
        let allow_list2 = allow_list.clone();
        let kl2 = keyring_lock.clone();
        tokio::spawn(admin::run_subscription_checker(cp2, sessions2, allow_list2, kl2));
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
                    match vpn_session::load_allow_list(Path::new(p)) {
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
                    // Resolve server SNI: explicit config > cert path > listen_addr
                    let server_name = cfg.network.server_name.clone()
                        .or_else(|| cfg.tls.as_ref()
                            .and_then(|q| q.cert_path.as_deref())
                            .and_then(|p| {
                                // Extract domain from /etc/letsencrypt/live/<domain>/fullchain.pem
                                p.split('/').find(|s| s.contains('.') && !s.contains("letsencrypt")).map(String::from)
                            }))
                        .unwrap_or_else(|| cfg.network.listen_addr.clone());

                    let ca_cert_path = admin_cfg.ca_cert_path.as_ref()
                        .map(PathBuf::from)
                        .or_else(|| cfg.tls.as_ref().and_then(|q| q.ca_cert_path.as_deref()).map(PathBuf::from));
                    let ca_key_path = admin_cfg.ca_key_path.as_ref()
                        .map(PathBuf::from)
                        .or_else(|| ca_cert_path.as_ref().map(|p| p.with_extension("key")));

                    let admin_state = admin::AdminState {
                        sessions: sessions.clone(),
                        clients_path: PathBuf::from(cfg.tls.as_ref()
                            .and_then(|q| q.allowed_clients_path.as_deref())
                            .unwrap_or("/opt/phantom-vpn/config/clients.json")),
                        token: token.clone(),
                        admin_url: format!("http://{}", listen_str),
                        started_at: std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs(),
                        allow_list: allow_list.clone(),
                        ca_cert_path,
                        ca_key_path,
                        server_addr: cfg.network.public_addr.clone()
                            .unwrap_or_else(|| cfg.network.listen_addr.clone()),
                        server_name,
                        exit_ip: cfg.network.exit_ip.clone(),
                        keyring_lock: keyring_lock.clone(),
                    };
                    let bot_listen_str = admin_cfg.bot_listen_addr.as_deref()
                        .unwrap_or("127.0.0.1:8081")
                        .to_string();
                    let ca_for_mtls = admin_state.ca_cert_path.clone();
                    let config_dir = admin_state.clients_path.parent()
                        .map(|p| p.to_path_buf())
                        .unwrap_or_else(|| PathBuf::from("/opt/phantom-vpn/config"));

                    // mTLS primary listener (10.7.0.1:8080)
                    let mtls_state = admin_state.clone();
                    let mtls_ca = ca_for_mtls.clone();
                    let mtls_cfg_dir = config_dir.clone();
                    tokio::spawn(async move {
                        match mtls_ca {
                            Some(ca) => {
                                if let Err(e) = admin_tls::run_mtls(admin_addr, mtls_state, &ca, &mtls_cfg_dir).await {
                                    tracing::error!("Admin mTLS server error: {}", e);
                                }
                            }
                            None => {
                                tracing::warn!("No CA cert configured — falling back to plain HTTP for admin listener");
                                if let Err(e) = admin_tls::run_plain(admin_addr, mtls_state).await {
                                    tracing::error!("Admin HTTP server error: {}", e);
                                }
                            }
                        }
                    });

                    // Loopback Bearer listener for the Telegram bot (127.0.0.1:8081)
                    if let Ok(bot_addr) = bot_listen_str.parse::<SocketAddr>() {
                        let bot_state = admin_state.clone();
                        tokio::spawn(async move {
                            if let Err(e) = admin_tls::run_plain(bot_addr, bot_state).await {
                                tracing::error!("Admin bot HTTP listener error: {}", e);
                            }
                        });
                    } else {
                        tracing::warn!("Invalid bot_listen_addr '{}', skipping bot listener", bot_listen_str);
                    }
                }
                Err(e) => tracing::warn!("Invalid admin listen_addr '{}': {}", listen_str, e),
            }
        }
    }

    // ─── TUN → per-session dispatch (lightweight routing) ──────────────────
    {
        let sess = sessions.clone();
        tokio::spawn(async move {
            if let Err(e) = vpn_session::tun_dispatch_loop(tun_read_rx, sess).await {
                tracing::error!("tun_dispatch_loop exited: {}", e);
            }
        });
    }

    // ─── HTTP/2 TCP listener ───────────────────────────────────────────────
    // Parse tun_network/tun_prefix early so both QUIC and H2 can use it
    let (tun_network, tun_prefix) = parse_cidr(tun_addr).unwrap_or_else(|| {
        tracing::warn!("Could not parse tun_addr CIDR '{}', defaulting to 10.7.0.0/24", tun_addr);
        ("10.7.0.0".parse().unwrap(), 24)
    });

    if cfg.h2.as_ref().and_then(|h| h.enabled).unwrap_or(true) {
        let h2_addr = cfg.h2.as_ref()
            .and_then(|h| h.listen_addr.as_deref())
            .unwrap_or("0.0.0.0:9443");  // Default to 9443 TCP (QUIC is 8443 UDP)
        match h2_addr.parse::<SocketAddr>() {
            Ok(h2_listen_addr) => {
                let h2_listener = TcpListener::bind(h2_listen_addr).await
                    .context(format!("Failed to bind HTTP/2 on {}", h2_listen_addr))?;
                let h2_tls = h2_tls_config.clone();
                let tun_tx = tun_tx.clone();
                let sessions = sessions.clone();
                let sessions_by_fp = sessions_by_fp.clone();
                let allow_list = allow_list.clone();
                tokio::spawn(async move {
                    if let Err(e) = h2_server::run_h2_accept_loop(
                        h2_listener, h2_tls, tun_tx, sessions, sessions_by_fp, tun_network, tun_prefix, allow_list
                    ).await {
                        tracing::error!("HTTP/2 accept loop error: {}", e);
                    }
                });
                tracing::info!("HTTP/2 listener bound on {}", h2_listen_addr);
            }
            Err(e) => tracing::warn!("Invalid h2 listen_addr '{}': {}", h2_addr, e),
        }
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

    // ─── Wait for shutdown ────────────────────────────────────────────────────
    tracing::info!("Server ready (H2/TLS transport).");

    let _ = shutdown_rx.await;
    tracing::info!("Shutdown signal received");

    // ─── Cleanup ────────────────────────────────────────────────────────────
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

/// "10.7.0.1/24" → "10.7.0.0/24"  (works for any prefix length, not just /24)
fn cidr_to_network(cidr: &str) -> String {
    let parts: Vec<&str> = cidr.split('/').collect();
    if parts.len() != 2 { return cidr.to_string(); }
    let prefix: u32 = match parts[1].parse() {
        Ok(p) => p,
        Err(_) => return cidr.to_string(),
    };
    let ip: std::net::Ipv4Addr = match parts[0].parse() {
        Ok(ip) => ip,
        Err(_) => return cidr.to_string(),
    };
    let mask = if prefix == 0 { 0 } else { !0u32 << (32 - prefix) };
    let network = std::net::Ipv4Addr::from(u32::from(ip) & mask);
    format!("{}/{}", network, prefix)
}
