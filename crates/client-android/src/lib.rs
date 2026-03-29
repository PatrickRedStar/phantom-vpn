//! phantom-client-android: Android VPN client via JNI.
//!
//! GhostStreamVpnService calls nativeStart(tunFd, serverAddr, serverName, insecure, certPath, keyPath)
//! Rust runs the QUIC tunnel in a background thread with VpnService.protect() on the socket.
//!
//! TUN I/O runs on dedicated OS threads (not tokio) to avoid contention with
//! QUIC encryption/batching, similar to the Linux client's io_uring threads.

use std::collections::VecDeque;
use std::ffi::CString;
use std::io;
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use jni::objects::{JClass, JObject, JString, JValue};
use jni::sys::{jboolean, jint, jlong, jstring};
use jni::JNIEnv;

// ─── Custom logger (logcat + ring buffer) ────────────────────────────────────

#[link(name = "log")]
extern "C" {
    fn __android_log_write(
        prio: libc::c_int,
        tag: *const libc::c_char,
        text: *const libc::c_char,
    ) -> libc::c_int;
}

struct LogEntryData {
    seq: u64,
    ts_secs: u64,
    level: &'static str,
    msg: String,
}

static LOG_SEQ: AtomicU64 = AtomicU64::new(0);
static LOG_BUFFER: Mutex<VecDeque<LogEntryData>> = Mutex::new(VecDeque::new());
static LOG_BUFFER_BYTES: AtomicU64 = AtomicU64::new(0);

// 3=Info (default), 4=Debug, 5=Trace
static LOG_LEVEL: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(3);

struct GhostStreamLogger;
static LOGGER: GhostStreamLogger = GhostStreamLogger;

impl log::Log for GhostStreamLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        let max = match LOG_LEVEL.load(Ordering::Relaxed) {
            4 => log::Level::Debug,
            5 => log::Level::Trace,
            _ => log::Level::Info,
        };
        metadata.level() <= max
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let msg_str = format!("{}", record.args());
        if let (Ok(tag), Ok(msg)) = (
            CString::new("GhostStream"),
            CString::new(msg_str.as_str()),
        ) {
            let prio = match record.level() {
                log::Level::Error => 6,
                log::Level::Warn => 5,
                log::Level::Info => 4,
                log::Level::Debug => 3,
                log::Level::Trace => 2,
            };
            unsafe { __android_log_write(prio, tag.as_ptr(), msg.as_ptr()); }
        }
        let entry = LogEntryData {
            seq: LOG_SEQ.fetch_add(1, Ordering::Relaxed),
            ts_secs: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            level: match record.level() {
                log::Level::Error => "ERROR",
                log::Level::Warn => "WARN",
                log::Level::Info => "INFO",
                log::Level::Debug => "DEBUG",
                log::Level::Trace => "TRACE",
            },
            msg: msg_str,
        };
        if let Ok(mut buf) = LOG_BUFFER.lock() {
            let entry_bytes = entry.msg.len() as u64 + 64;
            buf.push_back(entry);
            LOG_BUFFER_BYTES.fetch_add(entry_bytes, Ordering::Relaxed);
            while LOG_BUFFER_BYTES.load(Ordering::Relaxed) > 10 * 1024 * 1024 {
                if let Some(old) = buf.pop_front() {
                    LOG_BUFFER_BYTES.fetch_sub(old.msg.len() as u64 + 64, Ordering::Relaxed);
                } else {
                    break;
                }
            }
        }
    }

    fn flush(&self) {}
}

// ─── Stats counters ──────────────────────────────────────────────────────────

static BYTES_RX: AtomicU64 = AtomicU64::new(0);
static BYTES_TX: AtomicU64 = AtomicU64::new(0);
static PKTS_RX: AtomicU64 = AtomicU64::new(0);
static PKTS_TX: AtomicU64 = AtomicU64::new(0);
static IS_CONNECTED: AtomicBool = AtomicBool::new(false);

fn reset_stats() {
    BYTES_RX.store(0, Ordering::Relaxed);
    BYTES_TX.store(0, Ordering::Relaxed);
    PKTS_RX.store(0, Ordering::Relaxed);
    PKTS_TX.store(0, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
}

// ─── Global tunnel state ─────────────────────────────────────────────────────

struct TunnelHandle {
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
}

static TUNNEL: Mutex<Option<TunnelHandle>> = Mutex::new(None);

// Protected socket fds for Android VPN Service
static PROTECTED_TCP_FD: AtomicU64 = AtomicU64::new(0);
static PROTECTED_UDP_FD: AtomicU64 = AtomicU64::new(0);

// ─── JNI entry points ────────────────────────────────────────────────────────

#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeSetLogLevel(
    mut env: JNIEnv,
    _class: JClass,
    level: JString,
) {
    let level_str = env.get_string(&level).map(String::from).unwrap_or_default();
    match level_str.to_lowercase().as_str() {
        "debug" => { LOG_LEVEL.store(4, Ordering::Relaxed); log::set_max_level(log::LevelFilter::Debug); }
        "trace" => { LOG_LEVEL.store(5, Ordering::Relaxed); log::set_max_level(log::LevelFilter::Trace); }
        _       => { LOG_LEVEL.store(3, Ordering::Relaxed); log::set_max_level(log::LevelFilter::Info);  }
    }
    log::info!("Log level → {}", level_str);
}

#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeStart(
    mut env: JNIEnv,
    this: JObject,
    tun_fd: jint,
    server_addr: JString,
    server_name: JString,
    insecure: jboolean,
    cert_path: JString,
    key_path: JString,
    ca_cert_path: JString,
    transport: JString,
) -> jint {
    // Set max level permissive; GhostStreamLogger::enabled() gates by LOG_LEVEL
    let _ = log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Trace));

    macro_rules! jstr {
        ($name:expr, $field:literal) => {
            match env.get_string(&$name) {
                Ok(s) => String::from(s),
                Err(_) => { log::error!("nativeStart: bad {}", $field); return -1; }
            }
        };
    }

    let server_addr_str = jstr!(server_addr, "serverAddr");
    let server_name_str = jstr!(server_name, "serverName");
    let cert_path_str = jstr!(cert_path, "certPath");
    let key_path_str = jstr!(key_path, "keyPath");
    let ca_cert_path_str = jstr!(ca_cert_path, "caCertPath");
    let transport_str = jstr!(transport, "transport");
    let insecure = insecure != 0;

    reset_stats();

    let fd = unsafe { libc::dup(tun_fd as RawFd) };
    if fd < 0 {
        log::error!("nativeStart: dup() failed: {}", io::Error::last_os_error());
        return -1;
    }
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    // Branch on transport type for socket creation
    let is_h2 = transport_str == "h2";

    if is_h2 {
        // HTTP/2: Create TCP socket for later connection
        let tcp_fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
        if tcp_fd < 0 {
            log::error!("nativeStart: failed to create TCP socket");
            unsafe { libc::close(fd); }
            return -1;
        }

        // Protect TCP socket from VPN tunnel
        let protected = env
            .call_method(&this, "protect", "(I)Z", &[JValue::Int(tcp_fd)])
            .ok()
            .and_then(|v| v.z().ok())
            .unwrap_or(false);

        if !protected {
            log::error!("nativeStart: VpnService.protect() returned false for TCP socket");
            unsafe { libc::close(fd); }
            unsafe { libc::close(tcp_fd); }
            return -1;
        }
        // TCP socket tuning: TCP_NODELAY + large buffers (matching QUIC's 4MB UDP buffers)
        unsafe {
            let one: libc::c_int = 1;
            libc::setsockopt(tcp_fd, libc::IPPROTO_TCP, libc::TCP_NODELAY,
                &one as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t);
            let buf_size: libc::c_int = 4 * 1024 * 1024;
            libc::setsockopt(tcp_fd, libc::SOL_SOCKET, libc::SO_RCVBUF,
                &buf_size as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t);
            libc::setsockopt(tcp_fd, libc::SOL_SOCKET, libc::SO_SNDBUF,
                &buf_size as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t);
        }
        log::info!("HTTP/2 TCP socket fd={} protected + tuned (NODELAY, 4MB bufs)", tcp_fd);

        // Store TCP fd in a way that run_tunnel can access it
        PROTECTED_TCP_FD.store(tcp_fd as u64, Ordering::Relaxed);
    } else {
        // QUIC: Create UDP socket using raw fd directly (don't drop!)
        let socket_fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
        if socket_fd < 0 {
            log::error!("nativeStart: failed to create UDP socket: {}", io::Error::last_os_error());
            unsafe { libc::close(fd); }
            return -1;
        }

        // Increase UDP socket buffers — critical for download throughput.
        unsafe {
            let buf_size: libc::c_int = 4 * 1024 * 1024;
            libc::setsockopt(
                socket_fd, libc::SOL_SOCKET, libc::SO_RCVBUF,
                &buf_size as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
            libc::setsockopt(
                socket_fd, libc::SOL_SOCKET, libc::SO_SNDBUF,
                &buf_size as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }

        let protected = env
            .call_method(&this, "protect", "(I)Z", &[JValue::Int(socket_fd)])
            .ok()
            .and_then(|v| v.z().ok())
            .unwrap_or(false);

        if !protected {
            log::error!("nativeStart: VpnService.protect() returned false for UDP socket");
            unsafe { libc::close(fd); }
            unsafe { libc::close(socket_fd); }
            return -1;
        }
        log::info!("QUIC socket fd={} protected from VPN tunnel", socket_fd);

        // Set non-blocking
        unsafe {
            let flags = libc::fcntl(socket_fd, libc::F_GETFL, 0);
            libc::fcntl(socket_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        // Store UDP socket fd
        PROTECTED_UDP_FD.store(socket_fd as u64, Ordering::Relaxed);
    }

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    let transport_str_clone = transport_str.clone();
    let server_addr_str_clone = server_addr_str.clone();
    let server_name_str_clone = server_name_str.clone();
    let cert_path_str_clone = cert_path_str.clone();
    let key_path_str_clone = key_path_str.clone();
    let ca_cert_path_str_clone = ca_cert_path_str.clone();

    std::thread::Builder::new()
        .name("ghoststream-tunnel".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(6)
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("Failed to create tokio runtime: {}", e);
                    unsafe { libc::close(fd); }
                    return;
                }
            };

            rt.block_on(async move {
                log::info!(
                    "Tunnel starting: server={} sni={} insecure={} transport={} cert={}",
                    server_addr_str_clone, server_name_str_clone, insecure, transport_str_clone,
                    if cert_path_str_clone.is_empty() { "none" } else { &cert_path_str_clone }
                );
                if let Err(e) = run_tunnel(
                    fd,
                    &server_addr_str_clone, &server_name_str_clone,
                    insecure, &cert_path_str_clone, &key_path_str_clone, &ca_cert_path_str_clone,
                    &transport_str_clone,
                    shutdown_rx,
                ).await {
                    log::error!("Tunnel error: {:#}", e);
                }
                IS_CONNECTED.store(false, Ordering::Relaxed);
                unsafe { libc::close(fd); }
                log::info!("Tunnel stopped");
            });
        })
        .unwrap();

    *TUNNEL.lock().unwrap() = Some(TunnelHandle { shutdown_tx });
    0
}

#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeStop(
    _env: JNIEnv,
    _class: JClass,
) {
    IS_CONNECTED.store(false, Ordering::Relaxed);
    if let Some(handle) = TUNNEL.lock().unwrap().take() {
        let _ = handle.shutdown_tx.send(());
        log::info!("Tunnel stop signal sent");
    }
}

#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeGetStats(
    mut env: JNIEnv,
    _class: JClass,
) -> jstring {
    let json = format!(
        r#"{{"bytes_rx":{},"bytes_tx":{},"pkts_rx":{},"pkts_tx":{},"connected":{}}}"#,
        BYTES_RX.load(Ordering::Relaxed),
        BYTES_TX.load(Ordering::Relaxed),
        PKTS_RX.load(Ordering::Relaxed),
        PKTS_TX.load(Ordering::Relaxed),
        IS_CONNECTED.load(Ordering::Relaxed),
    );
    env.new_string(&json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeGetLogs(
    mut env: JNIEnv,
    _class: JClass,
    since_seq: jlong,
) -> jstring {
    let entries: Vec<String> = if let Ok(buf) = LOG_BUFFER.lock() {
        buf.iter()
            .filter(|e| (e.seq as i64) > since_seq)
            .map(|e| {
                let secs = e.ts_secs % 86400;
                format!(
                    r#"{{"seq":{},"ts":"{:02}:{:02}:{:02}","level":"{}","msg":"{}"}}"#,
                    e.seq,
                    secs / 3600, (secs % 3600) / 60, secs % 60,
                    e.level,
                    e.msg.replace('\\', "\\\\").replace('"', "\\\""),
                )
            })
            .collect()
    } else {
        vec![]
    };
    let json = format!("[{}]", entries.join(","));
    env.new_string(&json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

// ─── Routing ────────────────────────────────────────────────────────────────

/// Compute VPN routes (complement of "direct" CIDRs).
/// Input: path to a text file with one CIDR per line.
/// Output: JSON array of {"addr":"...","prefix":N} objects, or null on error.
#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeComputeVpnRoutes(
    mut env: JNIEnv,
    _class: JClass,
    direct_cidrs_path: JString,
) -> jstring {
    let _ = log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Info));

    let path_str = match env.get_string(&direct_cidrs_path) {
        Ok(s) => String::from(s),
        Err(_) => {
            log::error!("nativeComputeVpnRoutes: bad path string");
            return std::ptr::null_mut();
        }
    };

    let text = match std::fs::read_to_string(&path_str) {
        Ok(t) => t,
        Err(e) => {
            log::error!("nativeComputeVpnRoutes: failed to read {}: {}", path_str, e);
            return std::ptr::null_mut();
        }
    };

    let table = phantom_core::routing::RoutingTable::from_cidrs(&text);
    log::info!("Routing: loaded {} direct CIDRs from {}", table.direct_count(), path_str);

    let routes = table.compute_vpn_routes();
    log::info!("Routing: computed {} VPN routes", routes.len());

    let json = phantom_core::routing::routes_to_json(&routes);
    env.new_string(&json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

// ─── Tunnel runner ───────────────────────────────────────────────────────────

async fn run_tunnel(
    fd: RawFd,
    server_addr: &str,
    server_name: &str,
    insecure: bool,
    cert_path: &str,
    key_path: &str,
    ca_cert_path: &str,
    transport: &str,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    use tokio::sync::mpsc;

    let _ = rustls::crypto::ring::default_provider().install_default();

    let client_identity = if !cert_path.is_empty() && !key_path.is_empty() {
        log::info!("Loading client cert: {}", cert_path);
        Some(
            phantom_core::quic::load_pem_certs(Path::new(cert_path), Path::new(key_path))
                .context("Failed to load client cert/key")?,
        )
    } else {
        log::warn!("No client cert configured — server may reject connection");
        None
    };

    let server_ca = if !ca_cert_path.is_empty() {
        match std::fs::read(ca_cert_path) {
            Ok(bytes) => match phantom_core::quic::parse_pem_cert_chain(&bytes) {
                Ok(certs) => { log::info!("Loaded CA cert from {}", ca_cert_path); Some(certs) }
                Err(e)    => { log::error!("Failed to parse CA cert: {}", e); None }
            },
            Err(e) => { log::error!("Failed to read CA cert {}: {}", ca_cert_path, e); None }
        }
    } else {
        None
    };

    let server_addr: std::net::SocketAddr = if let Ok(addr) = server_addr.parse() {
        addr
    } else {
        log::info!("Resolving DNS for {}", server_addr);
        tokio::net::lookup_host(server_addr).await
            .context("DNS lookup failed")?
            .next()
            .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", server_addr))?
    };

    // Branch on transport type
    if transport == "h2" {
        run_h2_tunnel(fd, server_addr, server_name, insecure, server_ca, client_identity, shutdown_rx).await
    } else {
        // Read UDP socket fd from global
        let udp_fd = PROTECTED_UDP_FD.load(Ordering::Relaxed) as RawFd;
        if udp_fd <= 0 {
            return Err(anyhow::anyhow!("UDP socket not initialized"));
        }
        // Convert raw fd to std::net::UdpSocket
        unsafe {
            let udp_socket = std::net::UdpSocket::from_raw_fd(udp_fd);
            run_quic_tunnel(fd, udp_socket, server_addr, server_name, insecure, server_ca, client_identity, shutdown_rx).await
        }
    }
}

/// HTTP/2 tunnel implementation for Android
async fn run_h2_tunnel(
    fd: RawFd,
    server_addr: std::net::SocketAddr,
    server_name: &str,
    insecure: bool,
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(Vec<rustls::pki_types::CertificateDer<'static>>, rustls::pki_types::PrivateKeyDer<'static>)>,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    use tokio::sync::mpsc;
    use bytes::Bytes;
    use client_common::{h2_connect_with_tcp_stream, h2_stream_rx_loop, h2_stream_tx_loop};

    let client_config = phantom_core::h2_transport::make_h2_client_tls(insecure, server_ca, client_identity)
        .context("Failed to build HTTP/2 client config")?;

    // Read protected TCP socket fd from global
    let tcp_fd = PROTECTED_TCP_FD.load(Ordering::Relaxed) as RawFd;
    if tcp_fd <= 0 {
        return Err(anyhow::anyhow!("TCP socket not initialized"));
    }

    // Set socket non-blocking
    unsafe {
        let flags = libc::fcntl(tcp_fd, libc::F_GETFL, 0);
        libc::fcntl(tcp_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    // Connect to server
    let socket_addr = socket2::SockAddr::from(server_addr);
    let _ = unsafe { libc::connect(tcp_fd, socket_addr.as_ptr(), socket_addr.len()) };
    // Non-blocking connect returns EINPROGRESS, which is expected

    // Convert raw fd to std::net::TcpStream first, then to tokio
    let std_tcp = unsafe { std::net::TcpStream::from_raw_fd(tcp_fd) };
    let tcp = tokio::net::TcpStream::from_std(std_tcp).context("Failed to convert TCP socket to tokio")?;

    log::info!("HTTP/2 TCP socket fd={} connected to {}", tcp_fd, server_addr);

    let server_name = server_name.to_string();
    let (send_request, streams) = h2_connect_with_tcp_stream(tcp, server_name, client_config)
        .await
        .context("HTTP/2 connect failed")?;

    log::info!("HTTP/2 connected ({} streams)", streams.len());
    IS_CONNECTED.store(true, Ordering::Relaxed);
    IS_CONNECTED.store(true, Ordering::Relaxed);

    // Dup fd for dedicated TUN I/O threads
    let fd_read = fd;
    let fd_write = unsafe { libc::dup(fd) };
    if fd_write < 0 {
        return Err(anyhow::anyhow!("dup fd for writer failed: {}", io::Error::last_os_error()));
    }

    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);
    let (h2_pkt_tx, mut h2_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);

    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // TUN reader thread
    log::info!("TUN reader thread starting (fd={})", fd_read);
    let sf = shutdown_flag.clone();
    std::thread::Builder::new()
        .name("tun-reader".into())
        .spawn(move || {
            let mut buf = [0u8; 2048];
            let mut pfd = libc::pollfd { fd: fd_read, events: libc::POLLIN, revents: 0 };
            log::info!("TUN reader: entering poll loop");
            while !sf.load(Ordering::Relaxed) {
                let poll_ret = unsafe { libc::poll(&mut pfd, 1, 10) };
                if poll_ret <= 0 {
                    if poll_ret < 0 {
                        log::debug!("TUN reader: poll error: {}", io::Error::last_os_error());
                    }
                    continue;
                }
                log::debug!("TUN reader: poll returned {}, revents={:x}", poll_ret, pfd.revents);
                loop {
                    let n = unsafe {
                        libc::read(fd_read, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
                    };
                    if n <= 0 {
                        if n < 0 {
                            log::debug!("TUN reader: read error: {}", io::Error::last_os_error());
                        }
                        break;
                    }
                    log::debug!("TUN reader: read {} bytes", n);
                    BYTES_TX.fetch_add(n as u64, Ordering::Relaxed);
                    PKTS_TX.fetch_add(1, Ordering::Relaxed);
                    if tun_pkt_tx.blocking_send(buf[..n as usize].to_vec()).is_err() {
                        log::warn!("TUN reader: tun_pkt_tx send error, exiting");
                        return;
                    }
                }
            }
            log::info!("TUN reader thread exiting");
        })
        .context("spawn tun-reader")?;

    // TUN writer thread
    log::info!("TUN writer thread starting (fd={})", fd_write);
    std::thread::Builder::new()
        .name("tun-writer".into())
        .spawn(move || {
            log::info!("TUN writer: entering receive loop");
            while let Some(pkt) = h2_pkt_rx.blocking_recv() {
                log::debug!("TUN writer: writing {} bytes", pkt.len());
                BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                PKTS_RX.fetch_add(1, Ordering::Relaxed);
                unsafe { libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len()); }
                for _ in 0..255 {
                    match h2_pkt_rx.try_recv() {
                        Ok(pkt) => {
                            BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                            PKTS_RX.fetch_add(1, Ordering::Relaxed);
                            unsafe {
                                libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len());
                            }
                        }
                        Err(_) => break,
                    }
                }
            }
            log::info!("TUN writer thread exiting");
            unsafe { libc::close(fd_write); }
        })
        .context("spawn tun-writer")?;

    // HTTP/2 stream loops
    let (sends, recvs): (Vec<h2::SendStream<Bytes>>, Vec<h2::RecvStream>) = streams.into_iter().unzip();
    let mut set = tokio::task::JoinSet::new();

    for recv in recvs {
        let tx = h2_pkt_tx.clone();
        set.spawn(async move { h2_stream_rx_loop(recv, tx).await });
    }
    set.spawn(async move { h2_stream_tx_loop(tun_pkt_rx, sends).await });

    // Wait for shutdown or ALL tasks to complete (not just one!)
    tokio::select! {
        _ = shutdown_rx => { log::info!("Shutdown received"); }
        _ = async {
            while let Some(res) = set.join_next().await {
                if let Err(e) = res {
                    log::error!("Tunnel task panicked: {}", e);
                }
            }
        } => {
            log::info!("All HTTP/2 stream tasks completed");
        }
    }

    shutdown_flag.store(true, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
    drop(send_request);
    Ok(())
}

/// QUIC tunnel implementation for Android (original code)
async fn run_quic_tunnel(
    fd: RawFd,
    udp_socket: std::net::UdpSocket,
    server_addr: std::net::SocketAddr,
    server_name: &str,
    insecure: bool,
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(Vec<rustls::pki_types::CertificateDer<'static>>, rustls::pki_types::PrivateKeyDer<'static>)>,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    use tokio::sync::mpsc;

    let client_config = phantom_core::quic::make_client_config(insecure, server_ca, client_identity)
        .context("Failed to build QUIC client config")?;

    let runtime = quinn::default_runtime()
        .ok_or_else(|| anyhow::anyhow!("No async runtime"))?;
    let mut endpoint = quinn::Endpoint::new(
        quinn::EndpointConfig::default(), None, udp_socket, runtime,
    ).context("Failed to create QUIC endpoint")?;
    endpoint.set_default_client_config(client_config);

    let (connection, streams) =
        client_common::connect_and_handshake(&endpoint, server_addr, server_name)
            .await
            .context("QUIC connect failed")?;

    log::info!("QUIC connected ({} streams)", streams.len());
    IS_CONNECTED.store(true, Ordering::Relaxed);

    // Dup fd for dedicated TUN I/O threads
    let fd_read = fd;
    let fd_write = unsafe { libc::dup(fd) };
    if fd_write < 0 {
        return Err(anyhow::anyhow!("dup fd for writer failed: {}", io::Error::last_os_error()));
    }

    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);
    let (quic_pkt_tx, mut quic_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);

    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // TUN reader thread
    log::info!("TUN reader thread starting (fd={})", fd_read);
    let sf = shutdown_flag.clone();
    std::thread::Builder::new()
        .name("tun-reader".into())
        .spawn(move || {
            let mut buf = [0u8; 2048];
            let mut pfd = libc::pollfd { fd: fd_read, events: libc::POLLIN, revents: 0 };
            log::info!("TUN reader: entering poll loop");
            while !sf.load(Ordering::Relaxed) {
                let poll_ret = unsafe { libc::poll(&mut pfd, 1, 10) };
                if poll_ret <= 0 {
                    if poll_ret < 0 {
                        log::debug!("TUN reader: poll error: {}", io::Error::last_os_error());
                    }
                    continue;
                }
                log::debug!("TUN reader: poll returned {}, revents={:x}", poll_ret, pfd.revents);
                loop {
                    let n = unsafe {
                        libc::read(fd_read, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
                    };
                    if n <= 0 {
                        if n < 0 {
                            log::debug!("TUN reader: read error: {}", io::Error::last_os_error());
                        }
                        break;
                    }
                    log::debug!("TUN reader: read {} bytes", n);
                    BYTES_TX.fetch_add(n as u64, Ordering::Relaxed);
                    PKTS_TX.fetch_add(1, Ordering::Relaxed);
                    if tun_pkt_tx.blocking_send(buf[..n as usize].to_vec()).is_err() {
                        log::warn!("TUN reader: tun_pkt_tx send error, exiting");
                        return;
                    }
                }
            }
            log::info!("TUN reader thread exiting");
        })
        .context("spawn tun-reader")?;

    // TUN writer thread
    std::thread::Builder::new()
        .name("tun-writer".into())
        .spawn(move || {
            while let Some(pkt) = quic_pkt_rx.blocking_recv() {
                BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                PKTS_RX.fetch_add(1, Ordering::Relaxed);
                unsafe { libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len()); }
                for _ in 0..255 {
                    match quic_pkt_rx.try_recv() {
                        Ok(pkt) => {
                            BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                            PKTS_RX.fetch_add(1, Ordering::Relaxed);
                            unsafe {
                                libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len());
                            }
                        }
                        Err(_) => break,
                    }
                }
            }
            unsafe { libc::close(fd_write); }
        })
        .context("spawn tun-writer")?;

    // QUIC stream loops
    let (sends, recvs): (Vec<_>, Vec<_>) = streams.into_iter().unzip();
    let mut set = tokio::task::JoinSet::new();

    for recv in recvs {
        let tx = quic_pkt_tx.clone();
        set.spawn(async move { client_common::quic_stream_rx_loop(recv, tx).await });
    }
    set.spawn(async move { client_common::quic_stream_tx_loop(tun_pkt_rx, sends).await });

    tokio::select! {
        _ = shutdown_rx => { log::info!("Shutdown received"); }
        Some(res) = set.join_next() => {
            if let Ok(Err(e)) = res { log::error!("Tunnel task failed: {}", e); }
        }
    }

    shutdown_flag.store(true, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
    connection.close(0u32.into(), b"client shutdown");
    Ok(())
}
