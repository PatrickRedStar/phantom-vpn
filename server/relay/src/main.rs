//! phantom-relay: SNI-based TLS passthrough relay.
//!
//! Peeks the ClientHello on the incoming TCP stream, extracts the SNI, and:
//!   * If SNI matches `expected_sni`  → raw TCP passthrough (no decrypt) to
//!     the upstream exit server. The real TLS handshake (including mTLS)
//!     happens end-to-end between the client and the upstream.
//!   * Otherwise (DPI probes, random scanners, wrong host) → terminate TLS
//!     locally with the Let's Encrypt cert and serve a harmless HTML page.
//!
//! This eliminates the old double-encryption pipeline where relay was
//! re-encrypting every byte with its own rustls sessions.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use clap::Parser;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::io::{self, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsAcceptor;

#[cfg(target_os = "linux")]
use std::os::unix::io::{AsRawFd, RawFd};
#[cfg(target_os = "linux")]
use tokio::io::Interest;

// ─── Config ──────────────────────────────────────────────────────────────────

#[derive(Debug, serde::Deserialize, Default)]
struct RelayConfig {
    /// Address to listen on (e.g. "0.0.0.0:443" or "127.0.0.1:5443" behind nginx)
    listen_addr: Option<String>,

    /// Upstream exit server address (e.g. "tls.nl2.bikini-bottom.com:443")
    upstream_addr: Option<String>,

    /// SNI that a real client will send. If the peeked ClientHello carries
    /// this hostname → passthrough. Anything else → fallback (or drop, if
    /// no fallback cert/key configured).
    expected_sni: Option<String>,

    /// TLS cert for the fallback HTTPS endpoint (Let's Encrypt fullchain).
    /// If both cert_path and key_path are absent, fallback is disabled and
    /// SNI mismatches simply close the connection — useful when running
    /// behind an nginx stream that already routes only the right SNI to us.
    cert_path: Option<String>,

    /// TLS key for the fallback HTTPS endpoint (Let's Encrypt privkey)
    key_path: Option<String>,

    /// Fallback hostname shown to unauthenticated probes (defaults to
    /// `expected_sni` if absent).
    fallback_host: Option<String>,
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(name = "phantom-relay", about = "PhantomVPN SNI passthrough relay")]
struct Args {
    /// Path to TOML config file (optional; CLI flags can supply everything)
    #[arg(short, long)]
    config: Option<String>,

    /// Override listen address, e.g. "0.0.0.0:443" or "127.0.0.1:5443"
    #[arg(long)]
    listen: Option<String>,

    /// Override upstream exit server, e.g. "tls.nl2.bikini-bottom.com:443"
    #[arg(long)]
    upstream: Option<String>,

    /// Override expected SNI of real clients
    #[arg(long)]
    expected_sni: Option<String>,

    /// Override fallback TLS cert path (PEM fullchain)
    #[arg(long)]
    cert: Option<String>,

    /// Override fallback TLS key path (PEM)
    #[arg(long)]
    key: Option<String>,

    /// Override fallback hostname shown in HTML probe response
    #[arg(long)]
    fallback_host: Option<String>,

    /// Verbose logging
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

/// Effective relay configuration after merging TOML + CLI overrides.
struct EffectiveConfig {
    listen_addr: SocketAddr,
    upstream_addr: String,
    expected_sni: String,
    fallback_host: String,
    fallback: Option<(String, String)>, // (cert_path, key_path)
}

impl EffectiveConfig {
    fn from_args(args: &Args) -> anyhow::Result<Self> {
        let mut cfg = RelayConfig::default();
        if let Some(path) = &args.config {
            let raw = std::fs::read_to_string(path)
                .with_context(|| format!("Failed to read config: {}", path))?;
            cfg = toml::from_str(&raw)
                .with_context(|| format!("Failed to parse config: {}", path))?;
        }

        let listen_str = args.listen.clone().or(cfg.listen_addr)
            .ok_or_else(|| anyhow::anyhow!("listen_addr is required (config or --listen)"))?;
        let listen_addr: SocketAddr = listen_str.parse()
            .with_context(|| format!("Invalid listen_addr: {}", listen_str))?;

        let upstream_addr = args.upstream.clone().or(cfg.upstream_addr)
            .ok_or_else(|| anyhow::anyhow!("upstream_addr is required (config or --upstream)"))?;

        let expected_sni = args.expected_sni.clone().or(cfg.expected_sni)
            .ok_or_else(|| anyhow::anyhow!("expected_sni is required (config or --expected-sni)"))?
            .to_ascii_lowercase();

        let fallback_host = args.fallback_host.clone()
            .or(cfg.fallback_host)
            .unwrap_or_else(|| expected_sni.clone());

        let cert_path = args.cert.clone().or(cfg.cert_path);
        let key_path  = args.key.clone().or(cfg.key_path);

        let fallback = match (cert_path, key_path) {
            (Some(c), Some(k)) => Some((c, k)),
            (None, None) => None,
            _ => anyhow::bail!("cert_path and key_path must both be set or both unset"),
        };

        Ok(Self { listen_addr, upstream_addr, expected_sni, fallback_host, fallback })
    }
}

// ─── PEM loading ─────────────────────────────────────────────────────────────

fn load_certs(path: &Path) -> anyhow::Result<Vec<CertificateDer<'static>>> {
    let data = std::fs::read(path)
        .with_context(|| format!("Failed to read cert file: {}", path.display()))?;
    let certs: Vec<_> = rustls_pemfile::certs(&mut &data[..])
        .collect::<Result<Vec<_>, _>>()
        .with_context(|| format!("Failed to parse certs from {}", path.display()))?;
    Ok(certs)
}

fn load_key(path: &Path) -> anyhow::Result<PrivateKeyDer<'static>> {
    let data = std::fs::read(path)
        .with_context(|| format!("Failed to read key file: {}", path.display()))?;
    let key = rustls_pemfile::private_key(&mut &data[..])
        .with_context(|| format!("Failed to parse key from {}", path.display()))?
        .ok_or_else(|| anyhow::anyhow!("No private key found in {}", path.display()))?;
    Ok(key)
}

// ─── Fallback TLS acceptor ───────────────────────────────────────────────────

fn build_fallback_acceptor(cert_path: &str, key_path: &str) -> anyhow::Result<Arc<rustls::ServerConfig>> {
    let certs = load_certs(Path::new(cert_path))?;
    let key = load_key(Path::new(key_path))?;

    let mut tls_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;

    tls_config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    Ok(Arc::new(tls_config))
}

// ─── ClientHello SNI parser ──────────────────────────────────────────────────

/// Manual TLS ClientHello SNI extraction. Returns the first SNI hostname
/// found, or None if the buffer is not a valid ClientHello, the record is
/// truncated, or no SNI extension is present.
///
/// Record layout (RFC 5246 §6.2.1 / RFC 8446 §5.1):
///   [0]    u8  ContentType (0x16 = handshake)
///   [1-2]  u16 legacy_record_version
///   [3-4]  u16 record length
///   [5]    u8  HandshakeType (0x01 = client_hello)
///   [6-8]  u24 handshake length
///   [9-10] u16 legacy_version
///   [11-42]     32B random
///   then:  u8 session_id_len, session_id
///          u16 cipher_suites_len, cipher_suites
///          u8 compression_methods_len, compression_methods
///          u16 extensions_len, extensions
///
/// SNI extension (RFC 6066 §3):
///   ext_type = 0x0000
///   ext_data = u16 server_name_list_len
///                u8  name_type (0x00 = host_name)
///                u16 hostname_len, hostname
fn extract_sni(buf: &[u8]) -> Option<String> {
    let mut p = 0usize;

    // Record header
    if buf.len() < 5 {
        return None;
    }
    if buf[0] != 0x16 {
        return None; // not a handshake record
    }
    let rec_len = u16::from_be_bytes([buf[3], buf[4]]) as usize;
    if buf.len() < 5 + rec_len {
        return None; // truncated; caller should have peeked more
    }
    p += 5;

    // Handshake header
    if p + 4 > buf.len() {
        return None;
    }
    if buf[p] != 0x01 {
        return None; // not ClientHello
    }
    // u24 handshake length
    let hs_len = ((buf[p + 1] as usize) << 16)
        | ((buf[p + 2] as usize) << 8)
        | (buf[p + 3] as usize);
    p += 4;
    if p + hs_len > buf.len() {
        return None;
    }
    let hs_end = p + hs_len;

    // legacy_version (2) + random (32)
    if p + 34 > hs_end {
        return None;
    }
    p += 34;

    // session_id
    if p + 1 > hs_end {
        return None;
    }
    let sid_len = buf[p] as usize;
    p += 1;
    if p + sid_len > hs_end {
        return None;
    }
    p += sid_len;

    // cipher_suites
    if p + 2 > hs_end {
        return None;
    }
    let cs_len = u16::from_be_bytes([buf[p], buf[p + 1]]) as usize;
    p += 2;
    if p + cs_len > hs_end {
        return None;
    }
    p += cs_len;

    // compression_methods
    if p + 1 > hs_end {
        return None;
    }
    let cm_len = buf[p] as usize;
    p += 1;
    if p + cm_len > hs_end {
        return None;
    }
    p += cm_len;

    // extensions
    if p + 2 > hs_end {
        return None;
    }
    let ext_total = u16::from_be_bytes([buf[p], buf[p + 1]]) as usize;
    p += 2;
    if p + ext_total > hs_end {
        return None;
    }
    let ext_end = p + ext_total;

    while p + 4 <= ext_end {
        let ext_type = u16::from_be_bytes([buf[p], buf[p + 1]]);
        let ext_len = u16::from_be_bytes([buf[p + 2], buf[p + 3]]) as usize;
        p += 4;
        if p + ext_len > ext_end {
            return None;
        }

        if ext_type == 0x0000 {
            // server_name extension
            let mut q = p;
            let ext_data_end = p + ext_len;
            if q + 2 > ext_data_end {
                return None;
            }
            let list_len = u16::from_be_bytes([buf[q], buf[q + 1]]) as usize;
            q += 2;
            if q + list_len > ext_data_end {
                return None;
            }
            let list_end = q + list_len;
            while q + 3 <= list_end {
                let name_type = buf[q];
                let name_len = u16::from_be_bytes([buf[q + 1], buf[q + 2]]) as usize;
                q += 3;
                if q + name_len > list_end {
                    return None;
                }
                if name_type == 0x00 {
                    // host_name
                    return std::str::from_utf8(&buf[q..q + name_len])
                        .ok()
                        .map(|s| s.to_ascii_lowercase());
                }
                q += name_len;
            }
            return None;
        }

        p += ext_len;
    }

    None
}

// ─── Main ────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install ring crypto provider");

    let args = Args::parse();

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

    tracing::info!("PhantomVPN Relay (SNI passthrough) starting...");

    let cfg = EffectiveConfig::from_args(&args)?;

    let fallback_acceptor = match &cfg.fallback {
        Some((cert, key)) => {
            let acc = TlsAcceptor::from(build_fallback_acceptor(cert, key)?);
            tracing::info!("Fallback TLS enabled (cert={}, key={})", cert, key);
            Some(acc)
        }
        None => {
            tracing::info!("Fallback disabled — SNI mismatches will close the connection");
            None
        }
    };

    let listener = TcpListener::bind(cfg.listen_addr).await
        .with_context(|| format!("Failed to bind on {}", cfg.listen_addr))?;
    tracing::info!("Relay listening on {}", cfg.listen_addr);
    tracing::info!("Passthrough upstream: {} (expected SNI: {})", cfg.upstream_addr, cfg.expected_sni);
    tracing::info!("Fallback host: {}", cfg.fallback_host);

    // Resolve upstream once at startup
    let upstream_addr: SocketAddr = tokio::net::lookup_host(&cfg.upstream_addr).await
        .with_context(|| format!("DNS lookup failed for {}", cfg.upstream_addr))?
        .next()
        .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", cfg.upstream_addr))?;
    tracing::info!("Upstream resolved to {}", upstream_addr);

    let expected_sni = cfg.expected_sni;
    let fallback_host = cfg.fallback_host;

    loop {
        let (tcp, remote) = listener.accept().await?;
        let _ = tcp.set_nodelay(true);

        let fallback_acceptor = fallback_acceptor.clone();
        let expected_sni = expected_sni.clone();
        let fallback_host = fallback_host.clone();

        tokio::spawn(async move {
            if let Err(e) = handle_connection(
                tcp, remote, fallback_acceptor,
                upstream_addr, expected_sni, fallback_host,
            ).await {
                tracing::debug!("Connection from {} ended: {}", remote, e);
            }
        });
    }
}

async fn handle_connection(
    tcp: TcpStream,
    remote: SocketAddr,
    fallback_acceptor: Option<TlsAcceptor>,
    upstream_addr: SocketAddr,
    expected_sni: String,
    fallback_host: String,
) -> anyhow::Result<()> {
    // Peek the ClientHello. We try up to ~8 KB which easily covers even
    // oversized hellos (GREASE, post-quantum key shares, etc.).
    let mut peek_buf = vec![0u8; 8192];
    let mut have;

    // Peek in a loop until we have enough to parse, or the socket hangs / dies.
    // On Linux, TcpStream::peek returns whatever is currently in the kernel
    // buffer — we may need several polls before the whole ClientHello arrived.
    let sni = loop {
        match tokio::time::timeout(
            Duration::from_secs(5),
            tcp.peek(&mut peek_buf[..]),
        ).await {
            Ok(Ok(0)) => {
                anyhow::bail!("peer closed before ClientHello from {}", remote);
            }
            Ok(Ok(n)) => {
                have = n;
                if let Some(sni) = extract_sni(&peek_buf[..have]) {
                    break Some(sni);
                }
                // If the record header claims a length we don't yet have,
                // spin once more. If we've already hit the buffer cap or the
                // bytes we got clearly aren't a TLS record, bail to fallback.
                if have >= peek_buf.len() {
                    break None;
                }
                if have >= 5 && peek_buf[0] != 0x16 {
                    break None;
                }
                // wait a little and re-peek
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            Ok(Err(e)) => {
                anyhow::bail!("peek error from {}: {}", remote, e);
            }
            Err(_) => {
                anyhow::bail!("peek timeout from {}", remote);
            }
        }
    };

    match sni {
        Some(ref s) if s == &expected_sni => {
            tracing::info!("Passthrough {} (SNI={}) → {}", remote, s, upstream_addr);
            passthrough(tcp, remote, upstream_addr).await
        }
        Some(ref s) => {
            tracing::debug!("SNI mismatch from {} ({})", remote, s);
            match fallback_acceptor {
                Some(acc) => run_fallback(tcp, remote, acc, fallback_host).await,
                None => Ok(()), // drop
            }
        }
        None => {
            tracing::debug!("Unparseable ClientHello from {} ({} bytes)", remote, have);
            match fallback_acceptor {
                Some(acc) => run_fallback(tcp, remote, acc, fallback_host).await,
                None => Ok(()),
            }
        }
    }
}

// ─── Passthrough ─────────────────────────────────────────────────────────────

/// Socket tuning applied to both client and upstream sockets.
///
/// We deliberately do NOT touch SO_SNDBUF / SO_RCVBUF here: explicitly
/// setting them disables the kernel's TCP auto-tuning, which is the thing
/// that grows the window dynamically up to `tcp_{r,w}mem[2]` (16 MiB on this
/// box) based on BDP probes. A hand-rolled 4 MiB clamp is strictly worse —
/// it freezes the window at 4 MiB and on high-BDP paths the window never
/// reaches the size BBR would pick for itself.
///
/// All we do is kill Nagle so small writes don't sit in the kernel queue.
#[cfg(target_os = "linux")]
fn tune_tcp_socket(fd: RawFd) {
    unsafe {
        let one: libc::c_int = 1;
        libc::setsockopt(
            fd,
            libc::IPPROTO_TCP,
            libc::TCP_NODELAY,
            &one as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

/// Raw TCP passthrough: zero-copy via splice(2) on Linux, 256 KiB userspace
/// copy fallback elsewhere. No TLS inspection, no re-encryption, no mTLS.
/// The client and the upstream do a full TLS 1.3 handshake directly through us.
async fn passthrough(
    client: TcpStream,
    remote: SocketAddr,
    upstream_addr: SocketAddr,
) -> anyhow::Result<()> {
    let upstream = TcpStream::connect(upstream_addr).await
        .with_context(|| format!("Upstream connect to {} failed", upstream_addr))?;
    let _ = upstream.set_nodelay(true);

    #[cfg(target_os = "linux")]
    {
        tune_tcp_socket(client.as_raw_fd());
        tune_tcp_socket(upstream.as_raw_fd());
    }

    // NB: despite the Linux splice(2) path living in this file, we prefer
    // tokio's built-in copy_bidirectional here. Under real VPN load the
    // serial splice pipeline (fill pipe → drain pipe → fill pipe → …) was
    // giving < 10 Mbit/s even on a 1.5 Gbit/s link. copy_bidirectional
    // does concurrent read+write on both halves, which for this workload
    // is strictly better than a single-pipe splice loop.
    let (up, down) = copy_bidi(client, upstream).await;

    tracing::info!(
        "Passthrough {} closed: up={}B down={}B",
        remote, up, down
    );

    Ok(())
}

/// Bidirectional copy using tokio's built-in `copy_bidirectional`. This
/// runs read→write pipelines for both directions concurrently under the
/// same tokio task, with internal buffering tuned by tokio. It outperforms
/// the hand-rolled splice pipeline we had earlier because both directions
/// make forward progress in parallel rather than waiting on a single pipe.
async fn copy_bidi(mut client: TcpStream, mut upstream: TcpStream) -> (u64, u64) {
    match io::copy_bidirectional(&mut client, &mut upstream).await {
        Ok((up, down)) => (up, down),
        Err(_) => (0, 0),
    }
}

// ─── splice(2) based zero-copy forwarding (Linux) ───────────────────────────

/// Kernel-space forwarding via splice(2) through an anonymous pipe.
///
/// ```text
///     src ─ splice(src, pipe_w) ─▶ pipe ─ splice(pipe_r, dst) ─▶ dst
/// ```
///
/// The pipe never materializes the data in userspace — it's a kernel
/// ring of page references. This bypasses ALL userspace copies that the
/// old `read()` + `write_all()` path did.
///
/// We expand the pipe to 1 MiB (default is 64 KiB on most kernels), so a
/// full TCP RTO window can ride through without extra context switches.
///
/// Readiness is handled via the built-in `TcpStream::async_io` API, which
/// uses the existing mio registration made by tokio when the socket was
/// accepted. Doing a second registration through `AsyncFd` would fail with
/// EEXIST — that's the footgun we're avoiding here.
#[cfg(target_os = "linux")]
async fn splice_passthrough(
    client: TcpStream,
    upstream: TcpStream,
) -> (u64, u64) {
    let client = Arc::new(client);
    let upstream = Arc::new(upstream);

    let client_c2u = client.clone();
    let upstream_c2u = upstream.clone();
    let client_u2c = client.clone();
    let upstream_u2c = upstream.clone();

    let c2u = async move {
        splice_forward(client_c2u.as_ref(), upstream_c2u.as_ref()).await
    };
    let u2c = async move {
        splice_forward(upstream_u2c.as_ref(), client_u2c.as_ref()).await
    };

    tokio::join!(c2u, u2c)
}

/// One direction of the splice loop. Returns total bytes forwarded.
///
/// State machine:
/// 1. `pipe_pending == 0` → splice src → pipe_w. On EOF, half-close dst and return.
/// 2. `pipe_pending  > 0` → splice pipe_r → dst. Once drained, loop back.
///
/// `TcpStream::async_io(Interest, FnMut)` retries the closure when it
/// returns `WouldBlock` after waiting for readiness — exactly the contract
/// we need for splice's EAGAIN behavior.
#[cfg(target_os = "linux")]
async fn splice_forward(src: &TcpStream, dst: &TcpStream) -> u64 {
    // Create an anonymous pipe in non-blocking mode.
    let mut pipe_fds = [0i32; 2];
    let rc = unsafe { libc::pipe2(pipe_fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) };
    if rc < 0 {
        tracing::warn!("pipe2 failed: {}", std::io::Error::last_os_error());
        return 0;
    }
    let pipe_r = pipe_fds[0];
    let pipe_w = pipe_fds[1];

    // Request 1 MiB pipe capacity. Subject to /proc/sys/fs/pipe-max-size
    // (default 1 MiB on modern kernels).
    const PIPE_SIZE: libc::c_int = 1 << 20;
    unsafe {
        libc::fcntl(pipe_w, libc::F_SETPIPE_SZ, PIPE_SIZE);
    }

    let src_fd = src.as_raw_fd();
    let dst_fd = dst.as_raw_fd();
    let mut total: u64 = 0;
    let mut pipe_pending: usize = 0;

    loop {
        if pipe_pending == 0 {
            // ── fill pipe from src ──
            let res = src
                .async_io(Interest::READABLE, || {
                    let n = unsafe {
                        libc::splice(
                            src_fd,
                            std::ptr::null_mut(),
                            pipe_w,
                            std::ptr::null_mut(),
                            PIPE_SIZE as usize,
                            libc::SPLICE_F_MOVE | libc::SPLICE_F_NONBLOCK,
                        )
                    };
                    if n < 0 {
                        Err(std::io::Error::last_os_error())
                    } else {
                        Ok(n as usize)
                    }
                })
                .await;

            match res {
                Ok(0) => {
                    // EOF on src — half-close the write side of dst
                    unsafe { libc::shutdown(dst_fd, libc::SHUT_WR) };
                    break;
                }
                Ok(n) => {
                    pipe_pending += n;
                }
                Err(e) => {
                    tracing::debug!("splice(src→pipe) err: {}", e);
                    unsafe { libc::shutdown(dst_fd, libc::SHUT_WR) };
                    break;
                }
            }
        } else {
            // ── drain pipe into dst ──
            let res = dst
                .async_io(Interest::WRITABLE, || {
                    let n = unsafe {
                        libc::splice(
                            pipe_r,
                            std::ptr::null_mut(),
                            dst_fd,
                            std::ptr::null_mut(),
                            pipe_pending,
                            libc::SPLICE_F_MOVE | libc::SPLICE_F_NONBLOCK,
                        )
                    };
                    if n <= 0 {
                        // n == 0 here means the pipe briefly appeared empty;
                        // translate to WouldBlock so async_io re-polls.
                        if n == 0 {
                            return Err(std::io::Error::from(std::io::ErrorKind::WouldBlock));
                        }
                        Err(std::io::Error::last_os_error())
                    } else {
                        Ok(n as usize)
                    }
                })
                .await;

            match res {
                Ok(n) => {
                    pipe_pending -= n;
                    total += n as u64;
                }
                Err(e) => {
                    tracing::debug!("splice(pipe→dst) err: {}", e);
                    break;
                }
            }
        }
    }

    // Close pipe ends
    unsafe {
        libc::close(pipe_r);
        libc::close(pipe_w);
    }

    total
}

// ─── Fallback ────────────────────────────────────────────────────────────────

async fn run_fallback(
    tcp: TcpStream,
    remote: SocketAddr,
    acceptor: TlsAcceptor,
    fallback_host: String,
) -> anyhow::Result<()> {
    let tls_stream = match acceptor.accept(tcp).await {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!("Fallback TLS handshake from {} failed: {}", remote, e);
            return Ok(());
        }
    };
    serve_fallback(tls_stream, &fallback_host).await;
    Ok(())
}

/// Serve a simple HTML page to unauthenticated TLS probes.
async fn serve_fallback<S: io::AsyncRead + io::AsyncWrite + Unpin>(mut stream: S, host: &str) {
    // Read (and discard) whatever HTTP request the probe sends
    let mut buf = [0u8; 4096];
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        stream.read(&mut buf),
    ).await;

    let body = format!(
        "<html><body><h1>{}</h1><p>Service is running.</p></body></html>",
        host
    );
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(), body
    );

    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Hand-crafted minimal TLS 1.2 ClientHello with SNI "example.com".
    #[test]
    fn parse_sni_basic() {
        // Build: record(handshake) → client_hello(legacy ver 0x0303, 32B rand,
        // empty sid, 1 cipher suite 0x1301, 1 compression method 0x00,
        // 1 extension = SNI "example.com")
        let host = b"example.com";
        // SNI ext data
        let mut sni_ext = Vec::new();
        sni_ext.extend_from_slice(&((3 + host.len()) as u16).to_be_bytes()); // list_len
        sni_ext.push(0x00); // name_type host
        sni_ext.extend_from_slice(&(host.len() as u16).to_be_bytes());
        sni_ext.extend_from_slice(host);

        let mut ext_block = Vec::new();
        ext_block.extend_from_slice(&0x0000u16.to_be_bytes()); // type SNI
        ext_block.extend_from_slice(&(sni_ext.len() as u16).to_be_bytes());
        ext_block.extend_from_slice(&sni_ext);

        let mut ch = Vec::new();
        ch.extend_from_slice(&0x0303u16.to_be_bytes()); // legacy_version
        ch.extend_from_slice(&[0u8; 32]); // random
        ch.push(0); // sid len
        ch.extend_from_slice(&0x0002u16.to_be_bytes()); // cs len
        ch.extend_from_slice(&0x1301u16.to_be_bytes()); // TLS_AES_128_GCM_SHA256
        ch.push(1); // cm len
        ch.push(0); // null compression
        ch.extend_from_slice(&(ext_block.len() as u16).to_be_bytes());
        ch.extend_from_slice(&ext_block);

        let mut hs = Vec::new();
        hs.push(0x01); // client_hello
        let hs_len = ch.len();
        hs.push(((hs_len >> 16) & 0xff) as u8);
        hs.push(((hs_len >> 8) & 0xff) as u8);
        hs.push((hs_len & 0xff) as u8);
        hs.extend_from_slice(&ch);

        let mut rec = Vec::new();
        rec.push(0x16); // handshake
        rec.extend_from_slice(&0x0301u16.to_be_bytes()); // TLS 1.0 legacy
        rec.extend_from_slice(&(hs.len() as u16).to_be_bytes());
        rec.extend_from_slice(&hs);

        assert_eq!(extract_sni(&rec).as_deref(), Some("example.com"));
    }

    #[test]
    fn parse_sni_not_handshake() {
        assert_eq!(extract_sni(&[0x17, 0x03, 0x03, 0, 0]), None);
    }

    #[test]
    fn parse_sni_truncated() {
        assert_eq!(extract_sni(&[0x16, 0x03, 0x01]), None);
    }
}
