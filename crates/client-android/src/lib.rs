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
use std::os::unix::io::{AsRawFd, RawFd};
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

    let std_socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(e) => {
            log::error!("nativeStart: bind UDP failed: {}", e);
            unsafe { libc::close(fd); }
            return -1;
        }
    };
    let socket_fd = std_socket.as_raw_fd();

    // Increase UDP socket buffers — critical for download throughput.
    // Default Android SO_RCVBUF is ~200KB; at high pps QUIC packets get dropped.
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
        let mut actual_rcv: libc::c_int = 0;
        let mut actual_snd: libc::c_int = 0;
        let mut len: libc::socklen_t = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        libc::getsockopt(
            socket_fd, libc::SOL_SOCKET, libc::SO_RCVBUF,
            &mut actual_rcv as *mut _ as *mut libc::c_void, &mut len,
        );
        libc::getsockopt(
            socket_fd, libc::SOL_SOCKET, libc::SO_SNDBUF,
            &mut actual_snd as *mut _ as *mut libc::c_void, &mut len,
        );
        log::info!("UDP buffers: SO_RCVBUF={}KB SO_SNDBUF={}KB", actual_rcv / 1024, actual_snd / 1024);
    }

    let protected = env
        .call_method(&this, "protect", "(I)Z", &[JValue::Int(socket_fd)])
        .ok()
        .and_then(|v| v.z().ok())
        .unwrap_or(false);

    if !protected {
        log::error!("nativeStart: VpnService.protect() returned false");
        unsafe { libc::close(fd); }
        return -1;
    }
    log::info!("QUIC socket fd={} protected from VPN tunnel", socket_fd);
    std_socket.set_nonblocking(true).unwrap_or(());

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    std::thread::Builder::new()
        .name("ghoststream-tunnel".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(4)
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
                    "Tunnel starting: server={} sni={} insecure={} cert={}",
                    server_addr_str, server_name_str, insecure,
                    if cert_path_str.is_empty() { "none" } else { &cert_path_str }
                );
                if let Err(e) = run_tunnel(
                    fd, std_socket,
                    &server_addr_str, &server_name_str,
                    insecure, &cert_path_str, &key_path_str, &ca_cert_path_str,
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
    udp_socket: std::net::UdpSocket,
    server_addr: &str,
    server_name: &str,
    insecure: bool,
    cert_path: &str,
    key_path: &str,
    ca_cert_path: &str,
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

    let client_config = phantom_core::quic::make_client_config(insecure, server_ca, client_identity)
        .context("Failed to build QUIC client config")?;

    let runtime = quinn::default_runtime()
        .ok_or_else(|| anyhow::anyhow!("No async runtime"))?;
    let mut endpoint = quinn::Endpoint::new(
        quinn::EndpointConfig::default(), None, udp_socket, runtime,
    ).context("Failed to create QUIC endpoint")?;
    endpoint.set_default_client_config(client_config);

    let server_addr: std::net::SocketAddr = server_addr.parse()
        .context("Invalid server address")?;
    let (connection, streams) =
        client_common::connect_and_handshake(&endpoint, server_addr, server_name)
            .await
            .context("QUIC connect failed")?;

    log::info!("QUIC connected ({} streams)", streams.len());
    IS_CONNECTED.store(true, Ordering::Relaxed);

    // Dup fd for dedicated TUN I/O threads so each can close independently
    let fd_read = fd; // original fd — reader owns it conceptually
    let fd_write = unsafe { libc::dup(fd) };
    if fd_write < 0 {
        return Err(anyhow::anyhow!("dup fd for writer failed: {}", io::Error::last_os_error()));
    }

    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);
    let (quic_pkt_tx, mut quic_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);

    let shutdown_flag = Arc::new(AtomicBool::new(false));

    // ── Dedicated TUN reader thread ──────────────────────────────────────
    // Runs outside tokio so TUN I/O doesn't steal cycles from QUIC crypto.
    // Uses poll() + drain loop, similar to Linux client's io_uring reader.
    let sf = shutdown_flag.clone();
    std::thread::Builder::new()
        .name("tun-reader".into())
        .spawn(move || {
            let mut buf = [0u8; 2048];
            let mut pfd = libc::pollfd { fd: fd_read, events: libc::POLLIN, revents: 0 };
            while !sf.load(Ordering::Relaxed) {
                if unsafe { libc::poll(&mut pfd, 1, 100) } <= 0 {
                    continue;
                }
                // Drain all available packets after poll wakes
                loop {
                    let n = unsafe {
                        libc::read(fd_read, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
                    };
                    if n <= 0 { break; }
                    BYTES_TX.fetch_add(n as u64, Ordering::Relaxed);
                    PKTS_TX.fetch_add(1, Ordering::Relaxed);
                    if tun_pkt_tx.blocking_send(buf[..n as usize].to_vec()).is_err() {
                        return;
                    }
                }
            }
        })
        .context("spawn tun-reader")?;

    // ── Dedicated TUN writer thread ──────────────────────────────────────
    // Drains channel in batches to reduce syscall overhead.
    std::thread::Builder::new()
        .name("tun-writer".into())
        .spawn(move || {
            while let Some(pkt) = quic_pkt_rx.blocking_recv() {
                BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                PKTS_RX.fetch_add(1, Ordering::Relaxed);
                unsafe { libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len()); }
                // Batch: drain up to 255 more packets without blocking
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

    // ── QUIC stream loops (tokio tasks, same as before) ──────────────────
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
