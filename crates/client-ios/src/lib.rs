//! phantom-client-ios: iOS VPN client via C FFI.
//!
//! Exported API:
//! - phantom_start(tun_fd, config_json)
//! - phantom_stop()
//! - phantom_get_stats()
//! - phantom_get_logs(since_seq)
//! - phantom_set_log_level(level)
//! - phantom_compute_vpn_routes(direct_cidrs)
//! - phantom_free_string(ptr)
//! - phantom_set_protect_callback(cb)

use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::io;
use std::os::raw::{c_char, c_int};
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::Context;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct StartConfig {
    server_addr: String,
    server_name: String,
    insecure: bool,
    cert_path: String,
    key_path: String,
    ca_cert_path: String,
}

type ProtectCallback = extern "C" fn(fd: c_int) -> c_int;
static PROTECT_CB: Mutex<Option<ProtectCallback>> = Mutex::new(None);

struct LogEntryData {
    seq: u64,
    ts_secs: u64,
    level: &'static str,
    msg: String,
}

static LOG_SEQ: AtomicU64 = AtomicU64::new(0);
static LOG_BUFFER: Mutex<VecDeque<LogEntryData>> = Mutex::new(VecDeque::new());
static LOG_BUFFER_BYTES: AtomicU64 = AtomicU64::new(0);
static LOG_LEVEL: AtomicU8 = AtomicU8::new(3);

struct IosLogger;
static LOGGER: IosLogger = IosLogger;

impl log::Log for IosLogger {
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

        let msg = format!("{}", record.args());
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
            msg,
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

struct TunnelHandle {
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
}

static TUNNEL: Mutex<Option<TunnelHandle>> = Mutex::new(None);

fn to_c_string_ptr(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn from_c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().to_string())
}

#[no_mangle]
pub extern "C" fn phantom_set_protect_callback(cb: Option<ProtectCallback>) {
    if let Ok(mut guard) = PROTECT_CB.lock() {
        *guard = cb;
    }
}

#[no_mangle]
pub extern "C" fn phantom_set_log_level(level: *const c_char) {
    let _ = log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Trace));
    let level_str = from_c_str(level).unwrap_or_else(|| "info".to_string());
    match level_str.to_lowercase().as_str() {
        "debug" => {
            LOG_LEVEL.store(4, Ordering::Relaxed);
            log::set_max_level(log::LevelFilter::Debug);
        }
        "trace" => {
            LOG_LEVEL.store(5, Ordering::Relaxed);
            log::set_max_level(log::LevelFilter::Trace);
        }
        _ => {
            LOG_LEVEL.store(3, Ordering::Relaxed);
            log::set_max_level(log::LevelFilter::Info);
        }
    }
    log::info!("Log level -> {}", level_str);
}

#[no_mangle]
pub extern "C" fn phantom_start(tun_fd: c_int, config_json: *const c_char) -> c_int {
    let _ = log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Trace));

    let cfg_raw = match from_c_str(config_json) {
        Some(s) => s,
        None => return -1,
    };
    let cfg: StartConfig = match serde_json::from_str(&cfg_raw) {
        Ok(v) => v,
        Err(e) => {
            log::error!("phantom_start: invalid config json: {}", e);
            return -1;
        }
    };

    reset_stats();

    let fd = unsafe { libc::dup(tun_fd as RawFd) };
    if fd < 0 {
        log::error!("phantom_start: dup() failed: {}", io::Error::last_os_error());
        return -1;
    }
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let std_socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(e) => {
            log::error!("phantom_start: bind UDP failed: {}", e);
            unsafe { libc::close(fd) };
            return -1;
        }
    };
    let socket_fd = std_socket.as_raw_fd();
    let cb = PROTECT_CB.lock().ok().and_then(|guard| *guard);
    if let Some(protect_cb) = cb {
        let ok = protect_cb(socket_fd);
        if ok == 0 {
            log::error!("phantom_start: protect callback returned false");
            unsafe { libc::close(fd) };
            return -1;
        }
    }
    std_socket.set_nonblocking(true).unwrap_or(());

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    std::thread::Builder::new()
        .name("phantom-ios-tunnel".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(4)
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("Failed to create tokio runtime: {}", e);
                    unsafe { libc::close(fd) };
                    return;
                }
            };
            rt.block_on(async move {
                if let Err(e) = run_tunnel(fd, std_socket, &cfg, shutdown_rx).await {
                    log::error!("Tunnel error: {:#}", e);
                }
                IS_CONNECTED.store(false, Ordering::Relaxed);
                unsafe { libc::close(fd) };
                log::info!("Tunnel stopped");
            });
        })
        .map_err(|e| {
            log::error!("phantom_start: thread spawn error: {}", e);
            e
        })
        .ok();

    *TUNNEL.lock().unwrap() = Some(TunnelHandle { shutdown_tx });
    0
}

#[no_mangle]
pub extern "C" fn phantom_stop() {
    IS_CONNECTED.store(false, Ordering::Relaxed);
    if let Some(handle) = TUNNEL.lock().unwrap().take() {
        let _ = handle.shutdown_tx.send(());
    }
}

#[no_mangle]
pub extern "C" fn phantom_get_stats() -> *mut c_char {
    let json = format!(
        r#"{{"bytes_rx":{},"bytes_tx":{},"pkts_rx":{},"pkts_tx":{},"connected":{}}}"#,
        BYTES_RX.load(Ordering::Relaxed),
        BYTES_TX.load(Ordering::Relaxed),
        PKTS_RX.load(Ordering::Relaxed),
        PKTS_TX.load(Ordering::Relaxed),
        IS_CONNECTED.load(Ordering::Relaxed),
    );
    to_c_string_ptr(json)
}

#[no_mangle]
pub extern "C" fn phantom_get_logs(since_seq: i64) -> *mut c_char {
    let entries: Vec<String> = if let Ok(buf) = LOG_BUFFER.lock() {
        buf.iter()
            .filter(|e| (e.seq as i64) > since_seq)
            .map(|e| {
                let secs = e.ts_secs % 86400;
                format!(
                    r#"{{"seq":{},"ts":"{:02}:{:02}:{:02}","level":"{}","msg":"{}"}}"#,
                    e.seq,
                    secs / 3600,
                    (secs % 3600) / 60,
                    secs % 60,
                    e.level,
                    e.msg.replace('\\', "\\\\").replace('"', "\\\""),
                )
            })
            .collect()
    } else {
        vec![]
    };
    to_c_string_ptr(format!("[{}]", entries.join(",")))
}

#[no_mangle]
pub extern "C" fn phantom_compute_vpn_routes(direct_cidrs: *const c_char) -> *mut c_char {
    let text = match from_c_str(direct_cidrs) {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };
    let table = phantom_core::routing::RoutingTable::from_cidrs(&text);
    let routes = table.compute_vpn_routes();
    let json = phantom_core::routing::routes_to_json(&routes);
    to_c_string_ptr(json)
}

#[no_mangle]
pub extern "C" fn phantom_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

async fn run_tunnel(
    fd: RawFd,
    udp_socket: std::net::UdpSocket,
    cfg: &StartConfig,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use tokio::sync::mpsc;

    let _ = rustls::crypto::ring::default_provider().install_default();

    let client_identity = if !cfg.cert_path.is_empty() && !cfg.key_path.is_empty() {
        Some(
            phantom_core::quic::load_pem_certs(Path::new(&cfg.cert_path), Path::new(&cfg.key_path))
                .context("Failed to load client cert/key")?,
        )
    } else {
        None
    };

    let server_ca = if !cfg.ca_cert_path.is_empty() {
        match std::fs::read(&cfg.ca_cert_path) {
            Ok(bytes) => phantom_core::quic::parse_pem_cert_chain(&bytes).ok(),
            Err(_) => None,
        }
    } else {
        None
    };

    let client_config = phantom_core::quic::make_client_config(cfg.insecure, server_ca, client_identity)
        .context("Failed to build QUIC client config")?;
    let runtime = quinn::default_runtime().ok_or_else(|| anyhow::anyhow!("No async runtime"))?;
    let mut endpoint =
        quinn::Endpoint::new(quinn::EndpointConfig::default(), None, udp_socket, runtime)
            .context("Failed to create QUIC endpoint")?;
    endpoint.set_default_client_config(client_config);

    let server_addr: std::net::SocketAddr = if let Ok(addr) = cfg.server_addr.parse() {
        addr
    } else {
        tokio::net::lookup_host(&cfg.server_addr)
            .await
            .context("DNS lookup failed")?
            .next()
            .ok_or_else(|| anyhow::anyhow!("No DNS results"))?
    };

    let (connection, streams) =
        client_common::connect_and_handshake(&endpoint, server_addr, &cfg.server_name)
            .await
            .context("QUIC connect failed")?;
    IS_CONNECTED.store(true, Ordering::Relaxed);

    let fd_read = fd;
    let fd_write = unsafe { libc::dup(fd) };
    if fd_write < 0 {
        return Err(anyhow::anyhow!("dup fd for writer failed"));
    }

    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);
    let (quic_pkt_tx, mut quic_pkt_rx) = mpsc::channel::<Vec<u8>>(8192);
    let shutdown_flag = Arc::new(AtomicBool::new(false));

    let sf = shutdown_flag.clone();
    std::thread::Builder::new()
        .name("phantom-ios-tun-reader".into())
        .spawn(move || {
            let mut buf = [0u8; 2048];
            let mut pfd = libc::pollfd {
                fd: fd_read,
                events: libc::POLLIN,
                revents: 0,
            };
            while !sf.load(Ordering::Relaxed) {
                if unsafe { libc::poll(&mut pfd, 1, 100) } <= 0 {
                    continue;
                }
                loop {
                    let n =
                        unsafe { libc::read(fd_read, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                    if n <= 0 {
                        break;
                    }
                    BYTES_TX.fetch_add(n as u64, Ordering::Relaxed);
                    PKTS_TX.fetch_add(1, Ordering::Relaxed);
                    if tun_pkt_tx.blocking_send(buf[..n as usize].to_vec()).is_err() {
                        return;
                    }
                }
            }
        })
        .context("spawn tun-reader")?;

    std::thread::Builder::new()
        .name("phantom-ios-tun-writer".into())
        .spawn(move || {
            while let Some(pkt) = quic_pkt_rx.blocking_recv() {
                BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                PKTS_RX.fetch_add(1, Ordering::Relaxed);
                unsafe { libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len()) };
                for _ in 0..255 {
                    match quic_pkt_rx.try_recv() {
                        Ok(pkt) => {
                            BYTES_RX.fetch_add(pkt.len() as u64, Ordering::Relaxed);
                            PKTS_RX.fetch_add(1, Ordering::Relaxed);
                            unsafe {
                                libc::write(fd_write, pkt.as_ptr() as *const libc::c_void, pkt.len())
                            };
                        }
                        Err(_) => break,
                    }
                }
            }
            unsafe { libc::close(fd_write) };
        })
        .context("spawn tun-writer")?;

    let (sends, recvs): (Vec<_>, Vec<_>) = streams.into_iter().unzip();
    let mut set = tokio::task::JoinSet::new();
    for recv in recvs {
        let tx = quic_pkt_tx.clone();
        set.spawn(async move { client_common::quic_stream_rx_loop(recv, tx).await });
    }
    set.spawn(async move { client_common::quic_stream_tx_loop(tun_pkt_rx, sends).await });

    tokio::select! {
        _ = shutdown_rx => {}
        Some(res) = set.join_next() => {
            if let Ok(Err(e)) = res {
                log::error!("Tunnel task failed: {}", e);
            }
        }
    }

    shutdown_flag.store(true, Ordering::Relaxed);
    IS_CONNECTED.store(false, Ordering::Relaxed);
    connection.close(0u32.into(), b"client shutdown");
    Ok(())
}
