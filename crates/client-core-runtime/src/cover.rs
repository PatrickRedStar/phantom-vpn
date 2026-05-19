//! Cover-traffic warmup — fires a small burst of plain HTTPS requests to
//! popular RU whitelisted domains before we open the first TLS connection
//! to our actual server. v0.27.0 (W9).
//!
//! ## Why
//!
//! Russian carrier DPI (Tinkoff Mobile / Tele2 in particular) identifies our
//! traffic by the very distinctive fingerprint of 8 parallel TLS-1.3
//! handshakes to a single SNI in a ~5-second window. Browsers never produce
//! that pattern. The carrier samples the first 5–60 seconds, then injects
//! TCP RST on every stream and applies the canonical TSPU-128 kbps shaping
//! on subsequent reconnects (see incidents/2026-05-19-tinkoff-tspu.md).
//!
//! Cover traffic dilutes this fingerprint:
//!  - The carrier's flow-tracking buffer for our 4-tuples fills with
//!    plain "browsing-to-popular-site" entries first.
//!  - The SNI distribution from our IP looks like a normal phone (Yandex,
//!    VK, Dzen — high-volume RU services that every device hits).
//!  - Total handshake count from us doesn't spike immediately on tunnel
//!    start — it ramps over the cover phase + tunnel handshake.
//!
//! Best-effort: every step is wrapped in a short timeout. Cert verification
//! is disabled because we don't care about the response, only about the
//! handshake bytes flowing through the carrier middlebox. If a cover host
//! fails (DNS, RST, timeout) we just log and move on.
//!
//! Runs once per `client_core_runtime::run` invocation — i.e. when the
//! user/system explicitly starts a tunnel. Internal reconnects inside the
//! supervisor don't fire cover again (they don't help against a carrier
//! that's already memorized our 4-tuple, and they'd push reconnect latency
//! past the user's tolerance threshold).

use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpSocket;
use tokio_rustls::TlsConnector;

use crate::ProtectSocket;

/// Hosts to hit before opening the real tunnel. Chosen for:
///  - massive baseline traffic from RU phones (every Android in the country
///    hits these multiple times per day), so the carrier's flow stats see
///    "normal phone" not "new VPN-shaped device"
///  - distinct IP ranges / CDN providers, so the dilution doesn't all land
///    on the same upstream that a smart DPI could de-prioritize
///  - on every operator whitelist (госуслуги-equivalent — never blocked
///    even during emergency state TSPU clamps)
const COVER_DOMAINS: &[&str] = &["ya.ru", "vk.com", "dzen.ru"];

/// Per-host upper bound. If carrier is jamming the cover hosts too, we
/// don't want to delay the real tunnel by more than this × hosts.
const PER_HOST_TIMEOUT: Duration = Duration::from_secs(3);

/// Jitter between cover requests so the burst doesn't itself become a
/// fingerprint. Browsers space their concurrent loads by 50–200 ms.
const INTER_HOST_DELAY: Duration = Duration::from_millis(120);

/// Best-effort warmup. Failures are logged but never propagated — the
/// caller proceeds to tunnel handshake whether or not cover succeeds.
pub async fn do_cover_traffic(protect: Option<ProtectSocket>) {
    let started = std::time::Instant::now();
    tracing::info!(category = "cover", n_hosts = COVER_DOMAINS.len() as u64, "start");

    let config = Arc::new(
        ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerify))
            .with_no_client_auth(),
    );
    let connector = TlsConnector::from(config);

    let mut successes = 0u32;
    for &domain in COVER_DOMAINS {
        match tokio::time::timeout(
            PER_HOST_TIMEOUT,
            cover_one(domain, &connector, protect.as_ref()),
        )
        .await
        {
            Ok(Ok(())) => {
                successes += 1;
                tracing::debug!(category = "cover", domain, "ok");
            }
            Ok(Err(e)) => {
                tracing::debug!(category = "cover", domain, error = %e, "fail");
            }
            Err(_) => {
                tracing::debug!(category = "cover", domain, "timeout");
            }
        }
        tokio::time::sleep(INTER_HOST_DELAY).await;
    }

    let elapsed_ms = started.elapsed().as_millis() as u64;
    tracing::info!(
        category = "cover",
        successes,
        attempted = COVER_DOMAINS.len() as u64,
        elapsed_ms,
        "complete"
    );
}

async fn cover_one(
    domain: &str,
    connector: &TlsConnector,
    protect: Option<&ProtectSocket>,
) -> anyhow::Result<()> {
    // DNS happens through the underlying network (not VPN) because on
    // Android we haven't established the TUN yet at this point in run().
    // On Linux/Apple there is no VPN attached to this process anyway.
    let host = format!("{}:443", domain);
    let sock_addr = tokio::net::lookup_host(&host)
        .await?
        .next()
        .ok_or_else(|| anyhow::anyhow!("dns: no result"))?;

    let socket = if sock_addr.is_ipv4() {
        TcpSocket::new_v4()?
    } else {
        TcpSocket::new_v6()?
    };

    // Android: route through underlying network. Without protect() the
    // socket would loop through our own TUN once it's up (race with
    // tunnel-startup) — for cover phase that's almost never the case
    // because we run cover before TUN is wired, but it's cheap insurance.
    if let Some(p) = protect {
        let fd = socket.as_raw_fd();
        if !p(fd) {
            anyhow::bail!("protect() returned false");
        }
    }

    let tcp = socket.connect(sock_addr).await?;
    let server_name = ServerName::try_from(domain.to_string())?;
    let mut tls = connector.connect(server_name, tcp).await?;

    // Minimal HEAD request — looks like a browser preconnect / favicon
    // probe. No body, response body irrelevant. User-Agent is a generic
    // Chrome-Mobile string; matters less than the handshake itself for
    // DPI fingerprinting but keeps logs of the visited site uninteresting.
    let req = format!(
        "HEAD / HTTP/1.1\r\nHost: {}\r\nUser-Agent: Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 Chrome/126\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        domain
    );
    tls.write_all(req.as_bytes()).await?;

    // Read a tiny slice of the response so the carrier sees a full
    // request/response cycle, not a half-open TLS connection. Discard
    // everything — we don't care about content.
    let mut buf = [0u8; 512];
    let _ = tls.read(&mut buf).await;

    // Best-effort close. Drop will tear the socket regardless.
    let _ = tls.shutdown().await;
    Ok(())
}

/// Disables every cert verification step. Acceptable because:
///  - we transmit zero secret data over this connection (HEAD only,
///    standard public path, no auth)
///  - we don't read the response payload either
///  - the only thing we care about is that the bytes on the wire look
///    like a TLS-1.3 handshake to the carrier middlebox
///  - this verifier is used ONLY inside `cover.rs` — the real tunnel
///    uses the full mTLS verifier from `client-common`
#[derive(Debug)]
struct NoVerify;

impl ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ED25519,
        ]
    }
}
