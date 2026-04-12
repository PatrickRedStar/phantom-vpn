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
use std::os::unix::io::{FromRawFd, RawFd};
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

/// Blocking, non-sleeping TUN writer. The TUN fd is in O_NONBLOCK mode, so
/// full buffers return EAGAIN; instead of `sleep(1ms)` we `poll()` the fd
/// for POLLOUT with a 10 ms bound. This eliminates the latency floor on
/// bursty writes and surrenders the CPU to the kernel until the TUN queue
/// drains.
fn write_tun_packet(fd: RawFd, pkt: &[u8], writer_name: &str) -> io::Result<()> {
    let mut written = 0usize;

    while written < pkt.len() {
        let rc = unsafe {
            libc::write(
                fd,
                pkt[written..].as_ptr() as *const libc::c_void,
                pkt.len() - written,
            )
        };

        if rc > 0 {
            let n = rc as usize;
            written += n;
            BYTES_RX.fetch_add(n as u64, Ordering::Relaxed);
            continue;
        }

        if rc == 0 {
            let err = io::Error::new(
                io::ErrorKind::WriteZero,
                format!(
                    "{}: write returned 0 after {}/{} bytes",
                    writer_name,
                    written,
                    pkt.len()
                ),
            );
            log::error!("{}", err);
            return Err(err);
        }

        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK => {
                // Block on POLLOUT instead of busy-sleeping. 10 ms cap avoids
                // stalling forever if the TUN fd was silently closed.
                let mut pfd = libc::pollfd {
                    fd,
                    events: libc::POLLOUT,
                    revents: 0,
                };
                let pret = unsafe { libc::poll(&mut pfd, 1, 10) };
                if pret < 0 {
                    let e = io::Error::last_os_error();
                    if e.raw_os_error() == Some(libc::EINTR) {
                        continue;
                    }
                    log::error!("{}: poll(POLLOUT) failed: {}", writer_name, e);
                    return Err(e);
                }
                // pret == 0 (timeout) or >0 (ready): retry write.
                if pfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        format!("{}: TUN fd hangup (revents={:x})", writer_name, pfd.revents),
                    ));
                }
            }
            _ => {
                log::error!(
                    "{}: write failed after {}/{} bytes: {}",
                    writer_name,
                    written,
                    pkt.len(),
                    err
                );
                return Err(err);
            }
        }
    }

    PKTS_RX.fetch_add(1, Ordering::Relaxed);
    Ok(())
}

// ─── Global tunnel state ─────────────────────────────────────────────────────

struct TunnelHandle {
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
    join_handle: std::thread::JoinHandle<()>,
}

static TUNNEL: Mutex<Option<TunnelHandle>> = Mutex::new(None);

// Protected TCP fds for all N parallel TLS streams, filled before the tunnel
// thread starts (VpnService.protect() must run on the JNI thread that owns the
// JNIEnv). Consumed by `run_tls_tunnel`.
static PROTECTED_TCP_FDS: Mutex<Vec<RawFd>> = Mutex::new(Vec::new());

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

    // Create + protect() N parallel TCP sockets now, on the JNI thread that
    // owns the JNIEnv. They are later consumed by the tunnel thread.
    {
        use phantom_core::wire::n_data_streams;
        let n_streams = n_data_streams();
        let mut fds: Vec<RawFd> = Vec::with_capacity(n_streams);
        for i in 0..n_streams {
            let tcp_fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
            if tcp_fd < 0 {
                log::error!("nativeStart: socket() failed for stream {}", i);
                for f in &fds { unsafe { libc::close(*f); } }
                unsafe { libc::close(fd); }
                return -1;
            }

            let protected = env
                .call_method(&this, "protect", "(I)Z", &[JValue::Int(tcp_fd)])
                .ok()
                .and_then(|v| v.z().ok())
                .unwrap_or(false);

            if !protected {
                log::error!("nativeStart: VpnService.protect() returned false on stream {}", i);
                unsafe { libc::close(tcp_fd); }
                for f in &fds { unsafe { libc::close(*f); } }
                unsafe { libc::close(fd); }
                return -1;
            }

            unsafe {
                let one: libc::c_int = 1;
                libc::setsockopt(tcp_fd, libc::IPPROTO_TCP, libc::TCP_NODELAY,
                    &one as *const _ as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t);
            }
            log::info!("Stream {}: TCP fd={} protected + TCP_NODELAY", i, tcp_fd);
            fds.push(tcp_fd);
        }

        *PROTECTED_TCP_FDS.lock().unwrap() = fds;
    }

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    let transport_str_clone = transport_str.clone();
    let server_addr_str_clone = server_addr_str.clone();
    let server_name_str_clone = server_name_str.clone();
    let cert_path_str_clone = cert_path_str.clone();
    let key_path_str_clone = key_path_str.clone();
    let ca_cert_path_str_clone = ca_cert_path_str.clone();

    let join_handle = std::thread::Builder::new()
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
            // Runtime is dropped here, ensuring all worker threads are joined
            // before the tunnel thread exits.
        })
        .unwrap();

    *TUNNEL.lock().unwrap() = Some(TunnelHandle { shutdown_tx, join_handle });
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
        log::info!("Tunnel stop signal sent, waiting for tunnel thread to finish");
        if let Err(_) = handle.join_handle.join() {
            log::error!("Tunnel thread panicked during join");
        }
        log::info!("Tunnel thread joined");
    }
}

#[no_mangle]
pub extern "system" fn Java_com_ghoststream_vpn_service_GhostStreamVpnService_nativeGetStats(
    env: JNIEnv,
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
    env: JNIEnv,
    _class: JClass,
    since_seq: jlong,
) -> jstring {
    let entries: Vec<String> = if let Ok(buf) = LOG_BUFFER.lock() {
        buf.iter()
            .filter(|e| (e.seq as i64) > since_seq)
            .map(|e| {
                let secs = e.ts_secs % 86400;
                let escaped_msg = serde_json::to_string(&e.msg).unwrap_or_else(|_| "\"\"".to_string());
                format!(
                    r#"{{"seq":{},"ts":"{:02}:{:02}:{:02}","level":"{}","msg":{}}}"#,
                    e.seq,
                    secs / 3600, (secs % 3600) / 60, secs % 60,
                    e.level,
                    escaped_msg,
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
    _transport: &str,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    

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

    // Defensive: UI lets user edit serverAddr by hand; strip/append `:443`
    // so a bare hostname doesn't blow up `lookup_host` with "invalid socket
    // address". See client_common::with_default_port.
    let normalized_addr = client_common::with_default_port(server_addr, 443);
    let server_addr: std::net::SocketAddr = if let Ok(addr) = normalized_addr.parse() {
        addr
    } else {
        log::info!("Resolving DNS for {}", normalized_addr);
        tokio::net::lookup_host(&normalized_addr).await
            .context("DNS lookup failed")?
            .next()
            .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", normalized_addr))?
    };

    run_tls_tunnel(fd, server_addr, server_name, insecure, server_ca, client_identity, shutdown_rx).await
}

/// Raw TLS tunnel implementation for Android (multi-stream).
///
/// Opens `n_data_streams()` TLS connections in parallel, writes a 2-byte
/// `[stream_idx, max_streams]` handshake on each, then runs independent
/// tx/rx loops per stream.
/// A TUN reader task distributes outgoing packets to per-stream tx channels
/// using a 5-tuple flow hash (`flow_stream_idx`) to keep each TCP flow pinned
/// to one stream (avoids reordering).
async fn run_tls_tunnel(
    fd: RawFd,
    server_addr: std::net::SocketAddr,
    server_name: &str,
    insecure: bool,
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(Vec<rustls::pki_types::CertificateDer<'static>>, rustls::pki_types::PrivateKeyDer<'static>)>,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    use bytes::Bytes;
    use phantom_core::wire::{flow_stream_idx, n_data_streams};
    use tokio::sync::mpsc;
    use client_common::{tls_connect_with_tcp, tls_rx_loop, tls_tx_loop, write_handshake};

    let n_streams = n_data_streams();

    let client_config = phantom_core::h2_transport::make_h2_client_tls(insecure, server_ca, client_identity)
        .context("Failed to build TLS client config")?;

    // Consume pre-protected fds prepared on the JNI thread.
    let tcp_fds: Vec<RawFd> = {
        let mut g = PROTECTED_TCP_FDS.lock().unwrap();
        std::mem::take(&mut *g)
    };
    if tcp_fds.len() != n_streams {
        return Err(anyhow::anyhow!(
            "expected {} protected TCP fds, got {}",
            n_streams,
            tcp_fds.len()
        ));
    }

    // Connect each socket + TLS handshake, sequentially. Parallel connect()
    // would save ~1 RTT × N, but linear is simpler and N=8 is small enough.
    let mut tls_writers = Vec::with_capacity(n_streams);
    let mut tls_readers = Vec::with_capacity(n_streams);

    for (idx, tcp_fd) in tcp_fds.iter().copied().enumerate() {
        unsafe {
            let flags = libc::fcntl(tcp_fd, libc::F_GETFL, 0);
            libc::fcntl(tcp_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        let socket_addr = socket2::SockAddr::from(server_addr);
        let _ = unsafe { libc::connect(tcp_fd, socket_addr.as_ptr(), socket_addr.len()) };

        let std_tcp = unsafe { std::net::TcpStream::from_raw_fd(tcp_fd) };
        let tcp = tokio::net::TcpStream::from_std(std_tcp)
            .with_context(|| format!("stream {}: fd→tokio failed", idx))?;

        log::info!("Stream {}: TCP connected to {}", idx, server_addr);

        let (r, mut w) = tls_connect_with_tcp(tcp, server_name.to_string(), client_config.clone())
            .await
            .with_context(|| format!("stream {}: TLS handshake failed", idx))?;

        write_handshake(&mut w, idx as u8, n_streams as u8)
            .await
            .with_context(|| format!("stream {}: write_handshake failed", idx))?;

        log::info!("Stream {}: TLS + stream_idx handshake OK", idx);

        tls_readers.push(r);
        tls_writers.push(w);
    }

    log::info!("All {} TLS streams up", n_streams);
    IS_CONNECTED.store(true, Ordering::Relaxed);

    // Dup fd for dedicated TUN I/O threads
    let fd_read = fd;
    let fd_write = unsafe { libc::dup(fd) };
    if fd_write < 0 {
        return Err(anyhow::anyhow!("dup fd for writer failed: {}", io::Error::last_os_error()));
    }

    // Per-stream TX channels: TUN reader → dispatcher → stream N
    let mut tx_senders: Vec<mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
    let mut tx_receivers: Vec<mpsc::Receiver<Bytes>> = Vec::with_capacity(n_streams);
    for _ in 0..n_streams {
        let (tx, rx) = mpsc::channel::<Bytes>(2048);
        tx_senders.push(tx);
        tx_receivers.push(rx);
    }

    // Single RX channel: all N rx loops → single TUN writer thread
    let (tls_pkt_tx, mut tls_pkt_rx) = mpsc::channel::<Bytes>(4096);

    // TUN reader thread: reads raw packets, sends `Bytes` into dispatcher mpsc.
    let (tun_pkt_tx, mut tun_pkt_rx) = mpsc::channel::<Bytes>(8192);

    let shutdown_flag = Arc::new(AtomicBool::new(false));

    log::info!("TUN reader thread starting (fd={})", fd_read);
    let sf = shutdown_flag.clone();
    std::thread::Builder::new()
        .name("tun-reader".into())
        .spawn(move || {
            // Reusable read buffer; every packet becomes its own owned `Bytes`.
            let mut buf = [0u8; 2048];
            let mut pfd = libc::pollfd { fd: fd_read, events: libc::POLLIN, revents: 0 };
            while !sf.load(Ordering::Relaxed) {
                let poll_ret = unsafe { libc::poll(&mut pfd, 1, 10) };
                if poll_ret <= 0 { continue; }
                loop {
                    let n = unsafe {
                        libc::read(fd_read, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
                    };
                    if n <= 0 { break; }
                    BYTES_TX.fetch_add(n as u64, Ordering::Relaxed);
                    PKTS_TX.fetch_add(1, Ordering::Relaxed);
                    let pkt = Bytes::copy_from_slice(&buf[..n as usize]);
                    if tun_pkt_tx.blocking_send(pkt).is_err() {
                        return;
                    }
                }
            }
        })
        .context("spawn tun-reader")?;

    // Dispatcher task: TUN-reader → per-stream channel, using flow hash.
    //
    // IMPORTANT: uses `try_send` — NOT `send().await`. With per-stream channels
    // pinned by 5-tuple, a single slow TLS stream would otherwise back-pressure
    // the dispatcher and stall ALL other streams (cross-stream head-of-line
    // blocking). That reproduced as wild upload asymmetry on v0.18: one
    // bottlenecked stream would freeze every flow regardless of hash. Dropping
    // on full lets TCP retransmit handle the slow stream while fast streams
    // stay fluid. Matches server's `tun_dispatch_loop` behavior exactly.
    let tx_senders_for_disp = tx_senders.clone();
    tokio::spawn(async move {
        let mut drop_full: u64 = 0;
        let mut drop_closed: u64 = 0;
        while let Some(pkt) = tun_pkt_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams);
            let target = &tx_senders_for_disp[idx];
            match target.try_send(pkt) {
                Ok(()) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    drop_full += 1;
                    if drop_full == 1 || drop_full % 1024 == 0 {
                        log::warn!(
                            "dispatcher: stream {} full (dropped_full={})",
                            idx, drop_full
                        );
                    }
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    drop_closed += 1;
                    log::warn!(
                        "dispatcher: stream {} closed (dropped_closed={}), exiting",
                        idx, drop_closed
                    );
                    return;
                }
            }
        }
    });
    drop(tx_senders); // dispatcher owns the last copy

    // TUN writer thread (blocking) — drains the single RX sink.
    std::thread::Builder::new()
        .name("tun-writer".into())
        .spawn(move || {
            'writer: while let Some(pkt) = tls_pkt_rx.blocking_recv() {
                if write_tun_packet(fd_write, &pkt, "TUN writer").is_err() {
                    break 'writer;
                }
                for _ in 0..255 {
                    match tls_pkt_rx.try_recv() {
                        Ok(pkt) => {
                            if write_tun_packet(fd_write, &pkt, "TUN writer").is_err() {
                                break 'writer;
                            }
                        }
                        Err(_) => break,
                    }
                }
            }
            unsafe { libc::close(fd_write); }
        })
        .context("spawn tun-writer")?;

    // Spawn N tx loops and N rx loops.
    let mut tx_handles = Vec::with_capacity(n_streams);
    let mut rx_handles = Vec::with_capacity(n_streams);
    for (idx, (writer, rx_chan)) in tls_writers.into_iter().zip(tx_receivers.into_iter()).enumerate() {
        tx_handles.push(tokio::spawn(async move {
            let res = tls_tx_loop(writer, rx_chan).await;
            log::warn!("stream {}: tx loop ended: {:?}", idx, res);
            res
        }));
    }
    for (idx, reader) in tls_readers.into_iter().enumerate() {
        let sink = tls_pkt_tx.clone();
        rx_handles.push(tokio::spawn(async move {
            let res = tls_rx_loop(reader, sink).await;
            log::warn!("stream {}: rx loop ended: {:?}", idx, res);
            res
        }));
    }
    drop(tls_pkt_tx); // writer thread will close when all rx tasks drop their clones

    // Wait until shutdown or any task dies.
    tokio::select! {
        _ = shutdown_rx => {
            log::info!("Tunnel: shutdown signal received");
        }
        _ = async {
            for h in &mut tx_handles {
                let _ = h.await;
            }
        } => {
            log::warn!("All TX loops exited");
        }
        _ = async {
            for h in &mut rx_handles {
                let _ = h.await;
            }
        } => {
            log::warn!("All RX loops exited");
        }
    }

    for h in tx_handles { h.abort(); }
    for h in rx_handles { h.abort(); }

    shutdown_flag.store(true, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
    Ok(())
}

