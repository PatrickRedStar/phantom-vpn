//! mTLS admin listener + ClientIdentity extractor.
//!
//! Admin API listens on `10.7.0.1:8080` with TLS + mutual auth: client presents
//! a certificate signed by our CA; fingerprint is injected into the request via
//! request extensions for downstream middleware to check `is_admin`.
//!
//! The loopback bot listener (127.0.0.1:8081) runs the same router in plain
//! HTTP with only shared-token auth. Both paths share `AdminState`.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Context as _;
use axum::Router;
use rustls::server::WebPkiClientVerifier;
use rustls::{RootCertStore, ServerConfig};

use crate::admin::AdminState;

/// Authenticated client identity (extracted from peer cert during mTLS handshake).
/// Injected into request extensions when present; absent means loopback / plain HTTP.
#[derive(Clone, Debug)]
pub struct ClientIdentity {
    pub fingerprint: String,
}

/// Run the admin API over plain HTTP (loopback, bot break-glass channel).
pub async fn run_plain(
    listen_addr: SocketAddr,
    state: AdminState,
) -> anyhow::Result<()> {
    let app: Router = crate::admin::make_router(state);
    tracing::info!("Admin bot HTTP listener bound on {} (loopback, Bearer only)", listen_addr);
    let listener = tokio::net::TcpListener::bind(listen_addr).await
        .with_context(|| format!("bind plain admin listener {}", listen_addr))?;
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    ).await?;
    Ok(())
}

/// Run the admin API over HTTPS + mTLS (primary path for mobile clients).
pub async fn run_mtls(
    listen_addr: SocketAddr,
    state: AdminState,
    ca_cert_path: &Path,
    config_dir: &Path,
) -> anyhow::Result<()> {
    let (server_cert_path, server_key_path) =
        ensure_admin_server_cert(config_dir).context("ensure admin-server cert")?;

    // Build client-cert verifier from our CA
    let ca_pem = std::fs::read_to_string(ca_cert_path)
        .with_context(|| format!("read CA cert {}", ca_cert_path.display()))?;
    let mut ca_store = RootCertStore::empty();
    for cert in phantom_core::tls::parse_pem_cert_chain(ca_pem.as_bytes())
        .context("parse CA cert chain")?
    {
        ca_store.add(cert).context("add CA cert to root store")?;
    }
    let verifier = WebPkiClientVerifier::builder(Arc::new(ca_store))
        .allow_unauthenticated() // keep handshake permissive; middleware enforces identity
        .build()
        .context("build client cert verifier")?;

    // Server identity
    let server_certs_pem = std::fs::read(&server_cert_path)?;
    let server_key_pem   = std::fs::read(&server_key_path)?;
    let (server_certs, server_key) =
        phantom_core::tls::parse_pem_identity(&server_certs_pem, &server_key_pem)
            .context("parse admin-server identity")?;

    let mut tls_cfg = ServerConfig::builder()
        .with_client_cert_verifier(verifier)
        .with_single_cert(server_certs, server_key)
        .context("build TLS ServerConfig for admin listener")?;
    tls_cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
    let tls_cfg = Arc::new(tls_cfg);

    let app: Router = crate::admin::make_router(state);

    let tcp = tokio::net::TcpListener::bind(listen_addr).await
        .with_context(|| format!("bind mTLS admin listener {}", listen_addr))?;
    tracing::info!("Admin mTLS HTTPS listener bound on {}", listen_addr);

    loop {
        let (stream, peer) = match tcp.accept().await {
            Ok(x) => x,
            Err(e) => { tracing::warn!("admin accept failed: {}", e); continue; }
        };
        let acceptor = tokio_rustls::TlsAcceptor::from(tls_cfg.clone());
        let app = app.clone();
        tokio::spawn(async move {
            let tls_stream = match acceptor.accept(stream).await {
                Ok(s) => s,
                Err(e) => {
                    tracing::debug!("admin TLS handshake with {} failed: {}", peer, e);
                    return;
                }
            };
            let (_, server_conn) = tls_stream.get_ref();
            let identity = server_conn
                .peer_certificates()
                .and_then(|certs| certs.first())
                .map(|der| ClientIdentity {
                    fingerprint: crate::vpn_session::cert_fingerprint(der.as_ref()),
                });

            use tower::ServiceExt;
            let io = hyper_util::rt::TokioIo::new(tls_stream);
            let svc_app = app.clone();
            let ident = identity.clone();
            let svc = hyper::service::service_fn(move |mut req: hyper::Request<hyper::body::Incoming>| {
                if let Some(ref id) = ident {
                    req.extensions_mut().insert(id.clone());
                }
                let app = svc_app.clone();
                async move { app.oneshot(req).await }
            });
            if let Err(e) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, svc)
                .await
            {
                tracing::debug!("admin HTTP serve error from {}: {}", peer, e);
            }
        });
    }
}

fn ensure_admin_server_cert(config_dir: &Path) -> anyhow::Result<(PathBuf, PathBuf)> {
    let cert_path = config_dir.join("admin-server.crt");
    let key_path  = config_dir.join("admin-server.key");
    if cert_path.exists() && key_path.exists() {
        return Ok((cert_path, key_path));
    }
    std::fs::create_dir_all(config_dir).ok();
    tracing::info!("Generating admin-server self-signed cert at {}", cert_path.display());
    let ck = rcgen::generate_simple_self_signed(vec!["10.7.0.1".to_string()])
        .context("generate admin-server self-signed cert")?;
    std::fs::write(&cert_path, ck.cert.pem())?;
    std::fs::write(&key_path,  ck.key_pair.serialize_pem())?;
    Ok((cert_path, key_path))
}
