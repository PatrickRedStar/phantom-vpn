//! phantom-relay: SNI-based TLS passthrough relay.
//!
//! Reads the ClientHello on the incoming TCP stream, extracts the SNI, and:
//!   * If SNI matches `expected_sni`  → raw TCP passthrough (no decrypt) to
//!     the upstream exit server. The ClientHello bytes are replayed to the
//!     upstream verbatim; the real TLS handshake (including mTLS) happens
//!     end-to-end between the client and the upstream.
//!   * Otherwise (DPI probes, random scanners, wrong host) → terminate TLS
//!     locally with the Let's Encrypt cert and answer like a stock nginx.
//!
//! This eliminates the old double-encryption pipeline where relay was
//! re-encrypting every byte with its own rustls sessions.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use clap::Parser;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::io::{self, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::{timeout, timeout_at, Instant};
use tokio_rustls::TlsAcceptor;

/// Upper bound on connections handled at once. A passthrough holds two fds,
/// so this stays well below LimitNOFILE=65536 (systemd unit / docker ulimits).
const MAX_CONNECTIONS: usize = 8192;

/// Budget for everything before passthrough starts: reading the ClientHello
/// and, for the fallback, the TLS handshake plus the HTTP exchange.
const PRELUDE_TIMEOUT: Duration = Duration::from_secs(10);

/// DNS lookup of the upstream and each TCP connect attempt to it.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Largest ClientHello we buffer (one full TLS record). Real hellos are
/// 0.3–2 KB even with post-quantum key shares.
const MAX_HELLO: usize = 16 * 1024;

// ─── Config ──────────────────────────────────────────────────────────────────

#[derive(Debug, serde::Deserialize, Default)]
struct RelayConfig {
    /// Address to listen on (e.g. "0.0.0.0:443" or "127.0.0.1:5443" behind nginx)
    listen_addr: Option<String>,

    /// Upstream exit server address (e.g. "89.110.109.128:8443"). A hostname
    /// is resolved on every connection, all returned addresses are tried.
    upstream_addr: Option<String>,

    /// SNI that a real client will send. If the ClientHello carries this
    /// hostname → passthrough. Anything else → fallback (or drop, if no
    /// fallback cert/key configured).
    expected_sni: Option<String>,

    /// TLS cert for the fallback HTTPS endpoint (Let's Encrypt fullchain).
    /// If both cert_path and key_path are absent, fallback is disabled and
    /// SNI mismatches simply close the connection — only for running behind
    /// an nginx stream that already routes only the right SNI to us.
    /// Re-read on every fallback connection, so renewals need no restart.
    cert_path: Option<String>,

    /// TLS key for the fallback HTTPS endpoint (Let's Encrypt privkey)
    key_path: Option<String>,
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

    /// Override upstream exit server, e.g. "89.110.109.128:8443"
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

    /// Verbose logging
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

/// Effective relay configuration after merging TOML + CLI overrides.
struct EffectiveConfig {
    listen_addr: SocketAddr,
    upstream_addr: String,
    expected_sni: String,
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

        let cert_path = args.cert.clone().or(cfg.cert_path);
        let key_path  = args.key.clone().or(cfg.key_path);

        let fallback = match (cert_path, key_path) {
            (Some(c), Some(k)) => Some((c, k)),
            (None, None) => None,
            _ => anyhow::bail!("cert_path and key_path must both be set or both unset"),
        };

        Ok(Self { listen_addr, upstream_addr, expected_sni, fallback })
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

/// Built from disk on every fallback connection (they are rare), so a cert
/// renewed by certbot is served right away without restarting the relay
/// and dropping live passthrough streams.
fn build_fallback_acceptor(cert_path: &str, key_path: &str) -> anyhow::Result<TlsAcceptor> {
    let certs = load_certs(Path::new(cert_path))?;
    let key = load_key(Path::new(key_path))?;

    let mut tls_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;

    // The fallback speaks HTTP/1.1 only — advertising h2 would be a lie.
    tls_config.alpn_protocols = vec![b"http/1.1".to_vec()];

    Ok(TlsAcceptor::from(Arc::new(tls_config)))
}

// ─── ClientHello SNI parser ──────────────────────────────────────────────────

/// Reassembles the ClientHello handshake message from one or more TLS
/// records — a client may fragment it (RFC 8446 §5.1).
///
///   Ok(Some(msg)) — complete message, starting at the HandshakeType byte
///   Ok(None)      — need more bytes
///   Err(())       — not a TLS ClientHello
///
/// Record layout (RFC 5246 §6.2.1 / RFC 8446 §5.1):
///   [0]    u8  ContentType (0x16 = handshake)
///   [1-2]  u16 legacy_record_version
///   [3-4]  u16 record length
///   then   record payload — a slice of the handshake message
fn client_hello(buf: &[u8]) -> Result<Option<Vec<u8>>, ()> {
    let mut msg = Vec::new();
    let mut rest = buf;
    while rest.len() >= 5 {
        if rest[0] != 0x16 {
            return Err(()); // not a handshake record
        }
        let rec_len = u16::from_be_bytes([rest[3], rest[4]]) as usize;
        let Some(payload) = rest.get(5..5 + rec_len) else {
            break; // record not fully arrived yet
        };
        msg.extend_from_slice(payload);
        rest = &rest[5 + rec_len..];

        if msg.len() >= 4 {
            if msg[0] != 0x01 {
                return Err(()); // not ClientHello
            }
            // u24 handshake length
            let need = 4 + (((msg[1] as usize) << 16)
                | ((msg[2] as usize) << 8)
                | (msg[3] as usize));
            if msg.len() >= need {
                msg.truncate(need);
                return Ok(Some(msg));
            }
        }
    }
    if rest.first().is_some_and(|&b| b != 0x16) {
        return Err(());
    }
    Ok(None)
}

/// Manual TLS ClientHello SNI extraction from a complete handshake message
/// (see [`client_hello`]). Returns the first SNI hostname found, or None if
/// the message is malformed or carries no SNI extension.
///
/// Handshake layout:
///   [0]    u8  HandshakeType (0x01 = client_hello)
///   [1-3]  u24 handshake length
///   [4-5]  u16 legacy_version
///   [6-37]     32B random
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
    let hs_end = buf.len();

    // handshake header (4) + legacy_version (2) + random (32)
    let mut p = 4 + 34;
    if p > hs_end {
        return None;
    }

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

    match &cfg.fallback {
        Some((cert, key)) => {
            // Fail fast on bad paths; the files are re-read per connection.
            build_fallback_acceptor(cert, key)?;
            tracing::info!("Fallback TLS enabled (cert={}, key={})", cert, key);
        }
        None if cfg.listen_addr.ip().is_loopback() => {
            tracing::info!("Fallback disabled — SNI mismatches will close the connection");
        }
        None => {
            tracing::warn!(
                "Fallback disabled on public {} — a wrong SNI gets an instant close, \
                 which looks like a censor block. Only run like this behind nginx stream.",
                cfg.listen_addr
            );
        }
    }

    let listener = TcpListener::bind(cfg.listen_addr).await
        .with_context(|| format!("Failed to bind on {}", cfg.listen_addr))?;
    tracing::info!("Relay listening on {}", cfg.listen_addr);
    tracing::info!("Passthrough upstream: {} (expected SNI: {})", cfg.upstream_addr, cfg.expected_sni);

    let cfg = Arc::new(cfg);
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));

    loop {
        // At the limit we simply stop accepting; the kernel backlog holds
        // the rest until a slot frees up.
        let permit = slots.clone().acquire_owned().await.expect("semaphore is never closed");
        let (tcp, remote) = match listener.accept().await {
            Ok(conn) => conn,
            Err(e) => {
                // EMFILE / ENOBUFS / ECONNABORTED: keep the live streams up,
                // back off a little so a full fd table doesn't spin the loop.
                tracing::warn!("accept failed: {}", e);
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let _ = tcp.set_nodelay(true);

        let cfg = cfg.clone();
        tokio::spawn(async move {
            let _permit = permit;
            if let Err(e) = handle_connection(tcp, remote, &cfg).await {
                tracing::debug!("Connection from {} ended: {:#}", remote, e);
            }
        });
    }
}

async fn handle_connection(
    mut tcp: TcpStream,
    remote: SocketAddr,
    cfg: &EffectiveConfig,
) -> anyhow::Result<()> {
    let deadline = Instant::now() + PRELUDE_TIMEOUT;

    // Read (not peek) the ClientHello: every wait is then a real readiness
    // wait on the socket, and the bytes are replayed to whoever handles it.
    let mut buf = vec![0u8; MAX_HELLO];
    let mut have = 0;
    let hello = loop {
        let n = timeout_at(deadline, tcp.read(&mut buf[have..])).await
            .map_err(|_| anyhow::anyhow!("ClientHello timeout ({} bytes)", have))??;
        if n == 0 {
            anyhow::bail!("peer closed before ClientHello ({} bytes)", have);
        }
        have += n;
        match client_hello(&buf[..have]) {
            Ok(Some(msg)) => break Some(msg),
            Ok(None) if have < buf.len() => continue,
            _ => break None, // not TLS, or a hello too big to be real
        }
    };
    buf.truncate(have);
    let sni = hello.as_deref().and_then(extract_sni);

    if sni.as_deref() == Some(cfg.expected_sni.as_str()) {
        tracing::debug!("Passthrough {} → {}", remote, cfg.upstream_addr);
        return passthrough(tcp, remote, &buf, &cfg.upstream_addr).await;
    }

    tracing::debug!("No passthrough for {} (SNI={:?}, {} bytes)", remote, sni, have);
    let Some((cert, key)) = &cfg.fallback else {
        return Ok(()); // drop
    };
    match timeout_at(deadline, run_fallback(tcp, buf, cert, key)).await {
        Ok(res) => res,
        Err(_) => Ok(()), // probe stalled — close silently, like nginx does
    }
}

// ─── Passthrough ─────────────────────────────────────────────────────────────

/// Raw TCP passthrough: the already-read ClientHello goes first, then a plain
/// bidirectional copy. No TLS inspection, no re-encryption, no mTLS — the
/// client and the upstream do a full TLS 1.3 handshake directly through us.
async fn passthrough(
    mut client: TcpStream,
    remote: SocketAddr,
    hello: &[u8],
    upstream_addr: &str,
) -> anyhow::Result<()> {
    let mut upstream = match connect_upstream(upstream_addr).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("Upstream {} unreachable: {:#}", upstream_addr, e);
            return Ok(());
        }
    };
    let _ = upstream.set_nodelay(true);

    upstream.write_all(hello).await.context("replaying ClientHello upstream")?;
    let (up, down) = io::copy_bidirectional(&mut client, &mut upstream).await?;

    tracing::debug!(
        "Passthrough {} closed: up={}B down={}B",
        remote, up + hello.len() as u64, down
    );
    Ok(())
}

/// Resolves the upstream on every call (moving the exit is a DNS change, no
/// relay restart) and tries each address with its own connect timeout.
async fn connect_upstream(addr: &str) -> anyhow::Result<TcpStream> {
    let addrs = timeout(CONNECT_TIMEOUT, tokio::net::lookup_host(addr)).await
        .map_err(|_| anyhow::anyhow!("DNS lookup timed out"))?
        .context("DNS lookup failed")?;

    let mut last_err = anyhow::anyhow!("no DNS results");
    for a in addrs {
        match timeout(CONNECT_TIMEOUT, TcpStream::connect(a)).await {
            Ok(Ok(s)) => return Ok(s),
            Ok(Err(e)) => last_err = anyhow::anyhow!("{}: {}", a, e),
            Err(_) => last_err = anyhow::anyhow!("{}: connect timed out", a),
        }
    }
    Err(last_err)
}

// ─── Fallback ────────────────────────────────────────────────────────────────

async fn run_fallback(
    tcp: TcpStream,
    hello: Vec<u8>,
    cert_path: &str,
    key_path: &str,
) -> anyhow::Result<()> {
    let acceptor = match build_fallback_acceptor(cert_path, key_path) {
        Ok(a) => a,
        Err(e) => {
            tracing::warn!("Fallback cert unusable: {:#}", e);
            return Ok(());
        }
    };
    // Put the already-read ClientHello back in front of the socket.
    let (rd, wr) = tcp.into_split();
    let stream = io::join(std::io::Cursor::new(hello).chain(rd), wr);
    let tls_stream = acceptor.accept(stream).await.context("fallback TLS handshake")?;
    serve_fallback(tls_stream).await
}

/// Answer like a stock nginx with no site configured: 404 for anything that
/// looks like an HTTP request, 400 for garbage.
async fn serve_fallback<S: io::AsyncRead + io::AsyncWrite + Unpin>(mut stream: S) -> anyhow::Result<()> {
    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).await?;
    if n == 0 {
        return Ok(());
    }
    let status = if looks_like_http(&buf[..n]) { "404 Not Found" } else { "400 Bad Request" };
    stream.write_all(nginx_error(status, SystemTime::now()).as_bytes()).await?;
    stream.shutdown().await?;
    Ok(())
}

/// `METHOD SP target SP HTTP/1.x` on the first line.
fn looks_like_http(req: &[u8]) -> bool {
    let line = req.split(|&b| b == b'\n').next().unwrap_or_default();
    let mut parts = line.split(|&b| b == b' ');
    let method = parts.next().unwrap_or_default();
    !method.is_empty()
        && method.iter().all(u8::is_ascii_uppercase)
        && parts.next().is_some_and(|target| !target.is_empty())
        && parts.next().is_some_and(|version| version.starts_with(b"HTTP/1."))
}

/// Byte-for-byte nginx error page with `server_tokens off`.
fn nginx_error(status: &str, now: SystemTime) -> String {
    let body = format!(
        "<html>\r\n<head><title>{status}</title></head>\r\n<body>\r\n\
         <center><h1>{status}</h1></center>\r\n<hr><center>nginx</center>\r\n\
         </body>\r\n</html>\r\n"
    );
    format!(
        "HTTP/1.1 {status}\r\nServer: nginx\r\nDate: {}\r\nContent-Type: text/html\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        http_date(now),
        body.len(),
    )
}

/// IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT".
fn http_date(t: SystemTime) -> String {
    const WEEKDAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let secs = t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let days = secs / 86_400;

    // civil_from_days (H. Hinnant), days since 1970-01-01 → (y, m, d).
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + u64::from(month <= 2);

    format!(
        "{}, {:02} {} {} {:02}:{:02}:{:02} GMT",
        WEEKDAYS[(days % 7) as usize],
        day,
        MONTHS[(month - 1) as usize],
        year,
        secs % 86_400 / 3600,
        secs % 3600 / 60,
        secs % 60,
    )
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Hand-crafted minimal TLS ClientHello handshake message (no record
    /// header): legacy ver 0x0303, 32B rand, empty sid, 1 cipher suite
    /// 0x1301, 1 compression method 0x00, 1 extension = SNI `host`.
    fn hello_msg(host: &[u8]) -> Vec<u8> {
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
        hs
    }

    /// Wraps `msg` into handshake records, splitting it at `cuts`.
    fn records(msg: &[u8], cuts: &[usize]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut start = 0;
        for &end in cuts.iter().chain(std::iter::once(&msg.len())) {
            out.push(0x16); // handshake
            out.extend_from_slice(&0x0301u16.to_be_bytes()); // TLS 1.0 legacy
            out.extend_from_slice(&((end - start) as u16).to_be_bytes());
            out.extend_from_slice(&msg[start..end]);
            start = end;
        }
        out
    }

    fn sni_of(buf: &[u8]) -> Option<String> {
        client_hello(buf).ok().flatten().and_then(|m| extract_sni(&m))
    }

    #[test]
    fn parse_sni_basic() {
        let rec = records(&hello_msg(b"example.com"), &[]);
        assert_eq!(sni_of(&rec).as_deref(), Some("example.com"));
    }

    #[test]
    fn parse_sni_fragmented_records() {
        let msg = hello_msg(b"Tls.Nl2.Example.com");
        // Split inside the handshake header and inside the SNI extension.
        let rec = records(&msg, &[2, 3, 50]);
        assert_eq!(sni_of(&rec).as_deref(), Some("tls.nl2.example.com"));
        // Any prefix is "need more", never a verdict.
        for n in 0..rec.len() {
            assert_eq!(client_hello(&rec[..n]), Ok(None), "prefix {}", n);
        }
    }

    #[test]
    fn parse_sni_not_handshake() {
        assert_eq!(client_hello(&[0x17, 0x03, 0x03, 0, 0]), Err(()));
        assert_eq!(client_hello(b"GET / HTTP/1.1\r\n"), Err(()));
        assert_eq!(client_hello(b"GE"), Err(()));
        // Handshake record, but not a ClientHello.
        assert_eq!(client_hello(&records(&[0x02, 0, 0, 0], &[])), Err(()));
    }

    #[test]
    fn parse_sni_truncated() {
        assert_eq!(client_hello(&[0x16, 0x03, 0x01]), Ok(None));
        let rec = records(&hello_msg(b"example.com"), &[]);
        assert_eq!(client_hello(&rec[..rec.len() - 1]), Ok(None));
        // Inner lengths that overrun the message must not panic.
        let msg = hello_msg(b"example.com");
        for n in 0..msg.len() {
            assert_eq!(extract_sni(&msg[..n]), None, "prefix {}", n);
        }
    }

    #[test]
    fn http_date_format() {
        let at = |s| UNIX_EPOCH + Duration::from_secs(s);
        assert_eq!(http_date(at(0)), "Thu, 01 Jan 1970 00:00:00 GMT");
        assert_eq!(http_date(at(784_111_777)), "Sun, 06 Nov 1994 08:49:37 GMT");
        assert_eq!(http_date(at(951_782_400)), "Tue, 29 Feb 2000 00:00:00 GMT");
        assert_eq!(http_date(at(1_792_972_800)), "Mon, 26 Oct 2026 00:00:00 GMT");
    }

    #[test]
    fn fallback_answers_like_nginx() {
        assert!(looks_like_http(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
        assert!(looks_like_http(b"HEAD /robots.txt HTTP/1.0\r\n"));
        assert!(!looks_like_http(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"));
        assert!(!looks_like_http(b"\x00\x01garbage"));
        assert!(!looks_like_http(b"get / HTTP/1.1\r\n"));

        let resp = nginx_error("404 Not Found", UNIX_EPOCH);
        let (head, body) = resp.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("HTTP/1.1 404 Not Found\r\nServer: nginx\r\nDate: Thu, 01 Jan 1970"));
        assert!(head.contains(&format!("Content-Length: {}\r\n", body.len())));
        assert!(body.contains("<center><h1>404 Not Found</h1></center>"));
    }

    fn test_cfg(upstream: SocketAddr) -> EffectiveConfig {
        EffectiveConfig {
            listen_addr: "127.0.0.1:0".parse().unwrap(),
            upstream_addr: upstream.to_string(),
            expected_sni: "tls.nl2.example.com".into(),
            fallback: None,
        }
    }

    /// The right SNI must reach the upstream byte-for-byte — even when the
    /// ClientHello trickles in over several TCP segments and TLS records —
    /// and the pipe must then work both ways.
    #[tokio::test]
    async fn passthrough_replays_hello_verbatim() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let cfg = test_cfg(upstream.local_addr().unwrap());
        let relay_addr = relay.local_addr().unwrap();
        tokio::spawn(async move {
            let (tcp, remote) = relay.accept().await.unwrap();
            let _ = handle_connection(tcp, remote, &cfg).await;
        });

        let hello = records(&hello_msg(b"tls.nl2.example.com"), &[20]);
        let mut client = TcpStream::connect(relay_addr).await.unwrap();
        client.set_nodelay(true).unwrap();
        for chunk in [&hello[..3], &hello[3..30], &hello[30..]] {
            client.write_all(chunk).await.unwrap();
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
        client.write_all(b"after-hello").await.unwrap();

        let (mut up, _) = upstream.accept().await.unwrap();
        let mut got = vec![0u8; hello.len() + b"after-hello".len()];
        up.read_exact(&mut got).await.unwrap();
        assert_eq!(&got[..hello.len()], &hello[..]);
        assert_eq!(&got[hello.len()..], b"after-hello");

        up.write_all(b"server-reply").await.unwrap();
        let mut reply = [0u8; 12];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply, b"server-reply");
    }

    /// A wrong SNI without a fallback cert is closed and never reaches the exit.
    #[tokio::test]
    async fn wrong_sni_without_fallback_is_dropped() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let cfg = test_cfg(upstream.local_addr().unwrap());
        let relay_addr = relay.local_addr().unwrap();
        tokio::spawn(async move {
            let (tcp, remote) = relay.accept().await.unwrap();
            let _ = handle_connection(tcp, remote, &cfg).await;
        });

        let mut client = TcpStream::connect(relay_addr).await.unwrap();
        client.write_all(&records(&hello_msg(b"probe.example.org"), &[])).await.unwrap();
        let mut b = [0u8; 1];
        assert_eq!(client.read(&mut b).await.unwrap(), 0);
        assert!(timeout(Duration::from_millis(200), upstream.accept()).await.is_err());
    }
}
