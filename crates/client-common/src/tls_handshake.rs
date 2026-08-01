//! Raw TLS connection: TCP → TLS handshake (mTLS), returns split stream.
//! No HTTP/2 framing — just a bidirectional TLS byte stream.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use anyhow::{anyhow, Context};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

/// Boxed so the rustls and boring (uTLS) handshake paths return the SAME type.
/// The concrete stream type is never named outside this module, so this change
/// is transparent to callers that use the alias.
pub type TlsReadHalf = Box<dyn tokio::io::AsyncRead + Send + Unpin>;
pub type TlsWriteHalf = Box<dyn tokio::io::AsyncWrite + Send + Unpin>;

/// Maximum wall time a single TCP+TLS handshake may consume.
///
/// CONC-C1 / bug‑bash 2026-05-17 #7: without an explicit cap the host kernel's
/// `TCP_SYN_RETRIES` default (≈75 s) holds the supervisor inside one
/// `tls_connect()` call, so a Disconnect issued mid-handshake had no chance to
/// be observed until the doomed attempt finally errored. 15 s is generous
/// enough that healthy networks finish well inside (typical p99 < 2 s on LTE)
/// while clearly bounding the "hung handshake" tail.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

/// Connect via TCP/TLS, return split read/write halves.
///
/// Bounded by [`HANDSHAKE_TIMEOUT`]; if exceeded, returns a `handshake timeout`
/// error so the supervisor can surface a clean retry instead of waiting for
/// SYN_RETRIES.
pub async fn connect(
    server_addr: SocketAddr,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tokio::time::timeout(
        HANDSHAKE_TIMEOUT,
        connect_inner(server_addr, server_name, tls_config),
    )
    .await
    .map_err(|_| anyhow!("handshake timeout after {:?}", HANDSHAKE_TIMEOUT))?
}

async fn connect_inner(
    server_addr: SocketAddr,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tracing::debug!(
        category = "handshake",
        peer = %server_addr,
        local = "",
        "tcp.connect"
    );

    let tcp = tokio::net::TcpStream::connect(server_addr)
        .await
        .context("TCP connect failed")?;

    let local = tcp
        .local_addr()
        .map(|a| a.to_string())
        .unwrap_or_default();
    tracing::debug!(
        category = "handshake",
        peer = %server_addr,
        local = %local,
        "tcp.connected"
    );

    do_connect(tcp, server_name, tls_config).await
}

/// Perform TLS handshake on an already-connected TCP stream.
/// Used by Android where VpnService.protect() must be called on the raw socket
/// before any I/O (including TLS handshake).
///
/// Bounded by [`HANDSHAKE_TIMEOUT`] so a server that accepts the TCP connection
/// but never finishes the TLS ClientHello can't pin the supervisor.
pub async fn connect_with_tcp(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tokio::time::timeout(
        HANDSHAKE_TIMEOUT,
        do_connect(tcp, server_name, tls_config),
    )
    .await
    .map_err(|_| anyhow!("handshake timeout after {:?}", HANDSHAKE_TIMEOUT))?
}

async fn do_connect(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    // TCP_NODELAY: disable Nagle (critical for upload latency).
    // Do NOT set SO_RCVBUF/SO_SNDBUF — disables TCP auto-tuning.
    let _ = tcp.set_nodelay(true);

    // v0.27.1 (DPI fix): SO_KEEPALIVE REMOVED (restores v0.22.4). It was added in
    // v0.25.0 against mobile-NAT eviction, but it emits deterministic empty TCP
    // keepalive segments every 30 s in lock-step across all 8 sockets — a periodic
    // on-wire signal that carrier-DPI uses to fingerprint a long-lived tunnel
    // (v0.22.4 had none). NAT is kept alive instead by the application-layer
    // heartbeat (random 15-45 s per stream, see `wire::build_heartbeat_frame`),
    // which is < typical NAT idle timeouts and is already de-correlated per stream
    // — exactly the mechanism v0.22.4 relied on.

    let sni_str = server_name.clone();
    tracing::debug!(
        category = "handshake",
        sni = %sni_str,
        alpn = "",
        "tls.client_hello"
    );
    let server_name = rustls::pki_types::ServerName::try_from(server_name)
        .context("Invalid server name")?;
    let tls_connector = tokio_rustls::TlsConnector::from(tls_config);
    let tls_stream = tls_connector
        .connect(server_name, tcp)
        .await
        .context("TLS handshake failed")?;

    tracing::debug!(
        category = "handshake",
        proto = "tls1.3",
        sni = %sni_str,
        "tls.alpn_negotiated"
    );
    let (r, w) = tokio::io::split(tls_stream);
    Ok((Box::new(r), Box::new(w)))
}

// ─── Boring (uTLS / browser-fingerprint) path — ADR 0014 Phase 2 ──────────────
//
// rustls emits a stable, catalogable ClientHello (no GREASE, fixed ordering,
// h2-only ALPN) that RU DPP throttles as "proxy". BoringSSL (what Chrome/okhttp
// use) emits a GREASE'd, browser-family ClientHello. This path is selected at
// runtime via `TransportPolicy.fingerprint`; the rustls path above stays the
// default so nothing changes unless a policy opts in.

/// Which TLS engine + config to use for the client handshake.
#[derive(Clone)]
pub enum ClientTls {
    /// Default: rustls (legacy fingerprint).
    Rustls(Arc<rustls::ClientConfig>),
    /// uTLS: BoringSSL connector (browser-family ClientHello).
    Boring(Arc<BoringClientTls>),
}

/// A prebuilt BoringSSL client connector (mTLS identity baked in) + the profile
/// name it was built for. Reused across all N streams.
pub struct BoringClientTls {
    connector: boring::ssl::SslConnector,
    pub fingerprint: String,
    /// TEST-ONLY: when true, server certificate verification is disabled. This
    /// exists ONLY to measure whether the boring fingerprint lifts the DPI
    /// throttle without first solving root-store loading on Android (BoringSSL
    /// has no system trust store there). Production MUST load roots and verify.
    pub insecure_skip_verify: bool,
}

/// Build a BoringSSL client connector from the same DER materials rustls uses.
pub fn make_boring_client_tls(
    server_ca: Option<Vec<CertificateDer<'static>>>,
    client_identity: Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>,
    fingerprint: String,
    insecure_skip_verify: bool,
) -> anyhow::Result<Arc<BoringClientTls>> {
    use boring::ssl::{SslConnector, SslMethod, SslVerifyMode};
    use boring::x509::X509;

    let mut b = SslConnector::builder(SslMethod::tls_client())
        .context("boring: SslConnector::builder")?;

    if insecure_skip_verify {
        b.set_verify(SslVerifyMode::NONE);
    } else {
        b.set_verify(SslVerifyMode::PEER);
        b.set_default_verify_paths().ok();
        // Android: system CA certs live in a hashed dir, not a bundle file.
        let _ = b.set_ca_file("/system/etc/security/cacerts");
        if let Some(cas) = &server_ca {
            for ca in cas {
                if let Ok(x) = X509::from_der(ca.as_ref()) {
                    let _ = b.cert_store_mut().add_cert(x);
                }
            }
        }
    }

    // mTLS client identity.
    if let Some((certs, key)) = client_identity {
        if let Some(leaf) = certs.first() {
            let x = X509::from_der(leaf.as_ref()).context("boring: parse client leaf")?;
            b.set_certificate(&x).context("boring: set_certificate")?;
        }
        for extra in certs.iter().skip(1) {
            if let Ok(x) = X509::from_der(extra.as_ref()) {
                let _ = b.add_extra_chain_cert(x);
            }
        }
        let key_der = key.secret_der();
        let pkey = boring::pkey::PKey::private_key_from_der(key_der)
            .or_else(|_| {
                boring::ec::EcKey::private_key_from_der(key_der)
                    .and_then(boring::pkey::PKey::from_ec_key)
            })
            .context("boring: parse client private key")?;
        b.set_private_key(&pkey).context("boring: set_private_key")?;
    }

    // ALPN h2 (length-prefixed wire form).
    b.set_alpn_protos(b"\x02h2").context("boring: set_alpn_protos")?;

    apply_fingerprint(&mut b, &fingerprint);

    Ok(Arc::new(BoringClientTls {
        connector: b.build(),
        fingerprint,
        insecure_skip_verify,
    }))
}

/// Per-profile ClientHello tuning. v1: stock BoringSSL (Chrome/okhttp-family with
/// GREASE) for every profile — already a large step off the rustls fingerprint.
/// Cipher/group/sigalg lists per named profile (firefox/okhttp/…) can be added
/// here without touching callers.
fn apply_fingerprint(b: &mut boring::ssl::SslConnectorBuilder, profile: &str) {
    // Firefox uses NSS (tolerated by RU DPI per net4people #4035); Chrome/okhttp
    // use BoringSSL (suspicious). BoringSSL can't perfectly mimic NSS, but we can
    // at least present Firefox's cipher/group SET so JA3-style classifiers don't
    // see the default BoringSSL/Chrome ordering. Best-effort; errors ignored.
    if profile == "firefox" {
        let _ = b.set_cipher_list(
            "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
             ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
             ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
             ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA:\
             ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:\
             AES256-GCM-SHA384:AES128-SHA:AES256-SHA",
        );
        // BoringSSL dropped FFDHE groups; use the EC set Firefox also offers.
        let _ = b.set_curves_list("X25519:P-256:P-384:P-521");
    }
}

async fn do_connect_boring(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls: Arc<BoringClientTls>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    let _ = tcp.set_nodelay(true);
    let mut config = tls
        .connector
        .configure()
        .context("boring: configure")?;
    if tls.insecure_skip_verify {
        config.set_verify_hostname(false);
        config.set_use_server_name_indication(true);
    }
    tracing::debug!(category = "handshake", sni = %server_name, engine = "boring",
        fp = %tls.fingerprint, "tls.client_hello");
    let stream = tokio_boring::connect(config, &server_name, tcp)
        .await
        .map_err(|e| anyhow!("boring TLS handshake failed: {}", e))?;
    tracing::debug!(category = "handshake", proto = "boring", sni = %server_name,
        "tls.alpn_negotiated");
    let (r, w) = tokio::io::split(stream);
    Ok((Box::new(r), Box::new(w)))
}

/// Boring variant of [`connect_with_tcp`] (pre-connected socket, e.g. Android).
pub async fn connect_with_tcp_boring(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls: Arc<BoringClientTls>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tokio::time::timeout(HANDSHAKE_TIMEOUT, do_connect_boring(tcp, server_name, tls))
        .await
        .map_err(|_| anyhow!("handshake timeout after {:?}", HANDSHAKE_TIMEOUT))?
}

/// Boring variant of [`connect`] (dials TCP itself, e.g. desktop).
pub async fn connect_boring(
    server_addr: SocketAddr,
    server_name: String,
    tls: Arc<BoringClientTls>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    let tcp = tokio::net::TcpStream::connect(server_addr)
        .await
        .context("TCP connect failed")?;
    connect_with_tcp_boring(tcp, server_name, tls).await
}
