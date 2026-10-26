//! Static fake HTTPS application served to TSPU active probes.
//!
//! When a TCP connection reaches us WITHOUT a valid client certificate
//! (empty `peer_certificates`), we assume the peer is either an unauthorized
//! client or — more importantly — TSPU running active probing against our IP.
//! Serving a 404 or a blank 200 is suspicious; serving a realistic-looking
//! JSON/HTML API response is not.
//!
//! This module performs an HTTP/2 handshake over the already-accepted TLS
//! stream and answers a handful of "look like real mobile backend" endpoints:
//!
//! | Path                  | Response                                            |
//! |-----------------------|-----------------------------------------------------|
//! | `/`                   | minimal HTML SPA shell                              |
//! | `/favicon.ico`        | 16x16 transparent PNG                               |
//! | `/robots.txt`         | disallow all                                        |
//! | `/manifest.json`      | PWA manifest                                        |
//! | `/api/v1/health`      | `{"status":"ok","version":"1.24.0"}`                |
//! | `/api/v1/status`      | `{"uptime":...,"region":"nl2"}`                     |
//! | `/.well-known/*`      | 404 (legitimate for non-issuing hosts)              |
//! | other                 | 404 with plain text                                 |
//!
//! Server header is set to `nginx/1.24.0` to match the most common fronting
//! stack. Cache-Control and ETag headers make the response look like a real
//! CDN-backed API.

use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use futures_util::future::poll_fn;
use tokio::io::{AsyncRead, AsyncWrite};

/// Minimal HTML returned for `GET /`.
const INDEX_HTML: &str = r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Service</title>
<link rel="icon" href="/favicon.ico">
<link rel="manifest" href="/manifest.json">
</head>
<body>
<div id="app"></div>
<script>window.__APP_CONFIG__={region:"nl2",build:"1.24.0"};</script>
</body>
</html>
"#;

/// 16×16 transparent PNG (1-bit alpha).
const FAVICON_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0xF3, 0xFF,
    0x61, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x38, 0xCB, 0x63, 0x60, 0x18, 0x05, 0xA3,
    0x60, 0x14, 0x8C, 0x02, 0x08, 0x00, 0x00, 0x04,
    0x10, 0x00, 0x01, 0x85, 0x3F, 0xAA, 0x72, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

const ROBOTS_TXT: &str = "User-agent: *\nDisallow: /\n";

const MANIFEST_JSON: &str = r##"{"name":"Service","short_name":"svc","start_url":"/","display":"standalone","background_color":"#ffffff","theme_color":"#0066cc","icons":[{"src":"/favicon.ico","sizes":"16x16","type":"image/png"}]}"##;

/// Hard cap on one unauthenticated connection, handshake included.
const CONN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(45);

/// Handle an unauthenticated TLS stream by running a tiny HTTP/2 server that
/// answers a few realistic endpoints. Times out after 30s idle and 45 s total
/// so probers don't tie up resources.
pub async fn handle<S>(stream: S, remote: SocketAddr)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    if tokio::time::timeout(CONN_TIMEOUT, serve(stream, remote)).await.is_err() {
        tracing::debug!("fakeapp connection from {} timed out", remote);
    }
}

async fn serve<S>(stream: S, remote: SocketAddr)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut h2_conn = match h2::server::Builder::default().handshake(stream).await {
        Ok(c) => c,
        Err(e) => {
            tracing::debug!("fakeapp H2 handshake failed from {}: {}", remote, e);
            return;
        }
    };

    loop {
        let accept_result = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            poll_fn(|cx: &mut std::task::Context<'_>| h2_conn.poll_accept(cx)),
        ).await;

        match accept_result {
            Ok(poll_outcome) => match poll_outcome {
                Some(Ok((req, mut send))) => {
                    // Answer right away; the request body is never read (a
                    // POST that never ends must not hang this loop).
                    let (parts, payload) = response(req.uri().path()).into_parts();
                    drop(req);

                    let mut send = match send.send_response(http::Response::from_parts(parts, ()), false) {
                        Ok(s) => s,
                        Err(_) => break,
                    };
                    let _ = send.send_data(payload, true);
                }
                Some(Err(_)) | None => break,
            },
            Err(_) => break,
        }
    }

    tracing::debug!("fakeapp connection from {} ended", remote);
}

/// The same site for a prober that did not negotiate h2 (HTTP/1.1 or no ALPN
/// at all): a real nginx serves both protocols. hyper adds `Date` and drops
/// the body of a HEAD response, as nginx does.
pub async fn handle_http1<S>(stream: S, remote: SocketAddr)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let svc = hyper::service::service_fn(|req: hyper::Request<hyper::body::Incoming>| async move {
        Ok::<_, std::convert::Infallible>(response(req.uri().path()).map(axum::body::Body::from))
    });
    let conn = hyper::server::conn::http1::Builder::new()
        .title_case_headers(true)
        .serve_connection(hyper_util::rt::TokioIo::new(stream), svc);
    if tokio::time::timeout(CONN_TIMEOUT, conn).await.is_err() {
        tracing::debug!("fakeapp HTTP/1.1 connection from {} timed out", remote);
    }
}

fn response(path: &str) -> http::Response<Bytes> {
    let (status, content_type, payload): (u16, &str, Bytes) = match path {
        "/" => (
            200,
            "text/html; charset=utf-8",
            Bytes::from_static(INDEX_HTML.as_bytes()),
        ),
        "/favicon.ico" => (
            200,
            "image/png",
            Bytes::from_static(FAVICON_PNG),
        ),
        "/robots.txt" => (
            200,
            "text/plain; charset=utf-8",
            Bytes::from_static(ROBOTS_TXT.as_bytes()),
        ),
        "/manifest.json" => (
            200,
            "application/manifest+json",
            Bytes::from_static(MANIFEST_JSON.as_bytes()),
        ),
        "/api/v1/health" => (
            200,
            "application/json",
            Bytes::from_static(br#"{"status":"ok","version":"1.24.0"}"#),
        ),
        "/api/v1/status" => {
            let uptime = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let body = format!(
                r#"{{"uptime":{},"region":"nl2","build":"1.24.0"}}"#,
                uptime
            );
            (200, "application/json", Bytes::from(body))
        }
        p if p.starts_with("/.well-known/") => (
            404,
            "text/plain; charset=utf-8",
            Bytes::from_static(b"Not Found\n"),
        ),
        _ => (
            404,
            "text/plain; charset=utf-8",
            Bytes::from_static(b"Not Found\n"),
        ),
    };

    http::Response::builder()
        .status(status)
        .header("server", "nginx/1.24.0")
        .header("content-type", content_type)
        .header("content-length", payload.len().to_string())
        .header("cache-control", "public, max-age=3600")
        .header("x-request-id", format!("{:016x}", rand_u64()))
        .body(payload)
        .unwrap()
}

/// Random u64 for x-request-id header. Uses thread-local CSPRNG so the
/// output is not predictable by DPI / active probers.
fn rand_u64() -> u64 {
    use rand::Rng;
    rand::thread_rng().gen::<u64>()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// An HTTP/1.1 prober gets the same site as over h2, with nginx's headers.
    #[tokio::test]
    async fn http1_probe_looks_like_nginx() {
        let (mut probe, server) = tokio::io::duplex(64 * 1024);
        tokio::spawn(handle_http1(server, "127.0.0.1:1".parse().unwrap()));
        probe.write_all(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").await.unwrap();
        let mut resp = String::new();
        probe.read_to_string(&mut resp).await.unwrap();
        assert!(resp.starts_with("HTTP/1.1 200 OK\r\n"), "{resp}");
        assert!(resp.contains("Server: nginx/1.24.0\r\n"), "{resp}");
        assert!(resp.contains("Date: "), "{resp}");
        assert!(resp.ends_with(INDEX_HTML), "{resp}");
    }
}
