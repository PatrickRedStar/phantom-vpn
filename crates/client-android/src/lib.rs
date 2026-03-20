//! phantom-client-android: Android VPN client via JNI.
//!
//! Java VpnService calls nativeStart(tunFd, serverAddr, serverName, insecure)
//! and receives a TUN fd. Rust runs the QUIC tunnel in a background thread.
//!
//! Build:
//!   cargo ndk -t arm64-v8a -o android/app/src/main/jniLibs \
//!     build --release -p phantom-client-android

use std::io;
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::pin::Pin;
use std::sync::Mutex;
use std::task::Poll;

use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jint};
use jni::JNIEnv;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::io::unix::AsyncFd;

// ─── Global tunnel state ─────────────────────────────────────────────────────

struct TunnelHandle {
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
}

static TUNNEL: Mutex<Option<TunnelHandle>> = Mutex::new(None);

// ─── JNI entry points ────────────────────────────────────────────────────────

/// Called by Java: PhantomVpnService.nativeStart(tunFd, serverAddr, serverName, insecure)
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "system" fn Java_com_phantom_vpn_PhantomVpnService_nativeStart(
    mut env: JNIEnv,
    _class: JClass,
    tun_fd: jint,
    server_addr: JString,
    server_name: JString,
    insecure: jboolean,
) -> jint {
    // Initialize logcat output (safe to call multiple times)
    let _ = android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("PhantomVPN"),
    );

    let server_addr_str: String = match env.get_string(&server_addr) {
        Ok(s) => s.into(),
        Err(_) => {
            log::error!("nativeStart: bad serverAddr");
            return -1;
        }
    };
    let server_name_str: String = match env.get_string(&server_name) {
        Ok(s) => s.into(),
        Err(_) => {
            log::error!("nativeStart: bad serverName");
            return -1;
        }
    };
    let insecure = insecure != 0;

    // Dup the fd so Java's ParcelFileDescriptor can be closed independently
    let fd = unsafe { libc::dup(tun_fd as RawFd) };
    if fd < 0 {
        log::error!("nativeStart: dup() failed: {}", io::Error::last_os_error());
        return -1;
    }

    // Make non-blocking
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

    std::thread::Builder::new()
        .name("phantom-tunnel".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(2)
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
                log::info!("Tunnel starting: server={} sni={} insecure={}", server_addr_str, server_name_str, insecure);
                if let Err(e) = run_tunnel(fd, &server_addr_str, &server_name_str, insecure, shutdown_rx).await {
                    log::error!("Tunnel error: {}", e);
                }
                unsafe { libc::close(fd); }
                log::info!("Tunnel stopped");
            });
        })
        .unwrap();

    *TUNNEL.lock().unwrap() = Some(TunnelHandle { shutdown_tx });
    0
}

/// Called by Java: PhantomVpnService.nativeStop()
#[no_mangle]
pub extern "system" fn Java_com_phantom_vpn_PhantomVpnService_nativeStop(
    _env: JNIEnv,
    _class: JClass,
) {
    if let Some(handle) = TUNNEL.lock().unwrap().take() {
        let _ = handle.shutdown_tx.send(());
        log::info!("Tunnel stop signal sent");
    }
}

// ─── Tunnel runner ───────────────────────────────────────────────────────────

async fn run_tunnel(
    fd: RawFd,
    server_addr: &str,
    server_name: &str,
    insecure: bool,
    shutdown_rx: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<()> {
    use anyhow::Context;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::sync::mpsc;

    // Ring crypto provider (safe to call multiple times — install_default returns Err on dup)
    let _ = rustls::crypto::ring::default_provider().install_default();

    // QUIC client config
    let client_config = phantom_core::quic::make_client_config(insecure, None, None)
        .context("Failed to build QUIC client config")?;

    // QUIC endpoint (no SO_MARK needed — Android routes VPN traffic through system)
    let std_socket = std::net::UdpSocket::bind("0.0.0.0:0")
        .context("Failed to bind UDP socket")?;
    std_socket.set_nonblocking(true)?;

    let runtime = quinn::default_runtime()
        .ok_or_else(|| anyhow::anyhow!("No async runtime"))?;
    let mut endpoint = quinn::Endpoint::new(
        quinn::EndpointConfig::default(),
        None,
        std_socket,
        runtime,
    ).context("Failed to create QUIC endpoint")?;
    endpoint.set_default_client_config(client_config);

    // Connect + open data streams
    let server_addr: std::net::SocketAddr = server_addr.parse()
        .context("Invalid server address")?;
    let (connection, streams) = client_common::connect_and_handshake(&endpoint, server_addr, server_name)
        .await
        .context("QUIC connect failed")?;

    log::info!("QUIC connected ({} streams)", streams.len());

    // Async TUN wrapper
    let async_tun = AsyncTunFd::new(fd).context("Failed to wrap TUN fd")?;
    let (mut tun_reader, tun_writer) = tokio::io::split(async_tun);

    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(4096);
    let (quic_pkt_tx, mut quic_pkt_rx) = mpsc::channel::<Vec<u8>>(4096);

    // TUN writer: QUIC → TUN
    tokio::spawn(async move {
        let mut writer = tun_writer;
        while let Some(pkt) = quic_pkt_rx.recv().await {
            if let Err(e) = writer.write_all(&pkt).await {
                log::error!("TUN write: {}", e);
                break;
            }
        }
    });

    // TUN reader: TUN → QUIC
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        loop {
            match tun_reader.read(&mut buf).await {
                Ok(0) => continue,
                Ok(n) => {
                    if tun_pkt_tx.send(buf[..n].to_vec()).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    log::error!("TUN read: {}", e);
                    break;
                }
            }
        }
    });

    // QUIC stream loops
    let (sends, recvs): (Vec<_>, Vec<_>) = streams.into_iter().unzip();
    let mut set = tokio::task::JoinSet::new();

    for recv in recvs {
        let tx = quic_pkt_tx.clone();
        set.spawn(async move {
            client_common::quic_stream_rx_loop(recv, tx).await
        });
    }
    set.spawn(async move {
        client_common::quic_stream_tx_loop(tun_pkt_rx, sends).await
    });

    // Wait for shutdown signal or tunnel error
    tokio::select! {
        _ = shutdown_rx => {
            log::info!("Shutdown received");
        }
        Some(res) = set.join_next() => {
            if let Ok(Err(e)) = res {
                log::error!("Tunnel task failed: {}", e);
            }
        }
    }

    connection.close(0u32.into(), b"client shutdown");
    Ok(())
}

// ─── Async TUN fd wrapper (like macOS client, without 4-byte AF prefix) ──────

struct AsyncTunFd {
    inner: AsyncFd<std::fs::File>,
}

impl AsyncTunFd {
    fn new(fd: RawFd) -> io::Result<Self> {
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        Ok(Self { inner: AsyncFd::new(file)? })
    }
}

impl AsyncRead for AsyncTunFd {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            let mut guard = match self.inner.poll_read_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            let unfilled = buf.initialize_unfilled();
            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::read(
                        inner.as_raw_fd(),
                        unfilled.as_mut_ptr() as *mut libc::c_void,
                        unfilled.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
            }) {
                Ok(Ok(n)) => { buf.advance(n); return Poll::Ready(Ok(())); }
                Ok(Err(e))    => return Poll::Ready(Err(e)),
                Err(_blocked) => continue,
            }
        }
    }
}

impl AsyncWrite for AsyncTunFd {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = match self.inner.poll_write_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.as_raw_fd(),
                        data.as_ptr() as *const libc::c_void,
                        data.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
            }) {
                Ok(result)    => return Poll::Ready(result),
                Err(_blocked) => continue,
            }
        }
    }

    fn poll_flush(
        self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>,
    ) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>,
    ) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
