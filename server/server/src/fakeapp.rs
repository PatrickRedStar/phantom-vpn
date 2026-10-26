//! Static fake HTTPS application served to TSPU active probes.
//!
//! When a TCP connection reaches us WITHOUT a valid client certificate
//! (empty `peer_certificates`), we assume the peer is either an unauthorized
//! client or — more importantly — TSPU running active probing against our IP.
//! Serving a 404 or a blank 200 is suspicious; serving a realistic-looking
//! JSON/HTML API response is not.
//!
//! This module performs an HTTP/2 handshake over the already-accepted TLS
//! stream (or, without ALPN h2, reads one HTTP/1.1 request) and answers a
//! handful of "look like real mobile backend" endpoints:
//!
//! | Path                  | Response                                            |
//! |-----------------------|-----------------------------------------------------|
//! | `/`                   | minimal HTML SPA shell                              |
//! | `/favicon.ico`        | 16x16 transparent PNG                               |
//! | `/robots.txt`         | disallow all                                        |
//! | `/manifest.json`      | PWA manifest                                        |
//! | `/api/v1/health`      | `{"status":"ok","version":"1.24.0"}`                |
//! | `/api/v1/status`      | `{"uptime":...,"region":"nl2"}`                     |
//! | other                 | nginx's own 404 page                                |
//!
//! Headers start with `Server: nginx` and `Date`, like nginx with
//! `server_tokens off` (the relay's fallback answers the same way).
//! Cache-Control and X-Request-Id make the response look like a real
//! CDN-backed API.

use std::net::SocketAddr;
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use futures_util::future::poll_fn;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

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

/// HTTP/1.1 request head larger than this gets 400, as in nginx (8 KB buffers).
const MAX_HEAD: usize = 8 * 1024;

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
/// at all): a real nginx serves both protocols. One request per connection,
/// answered with `Connection: close`; garbage gets nginx's 400 page.
pub async fn handle_http1<S>(mut stream: S, remote: SocketAddr)
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    match tokio::time::timeout(CONN_TIMEOUT, serve_http1(&mut stream)).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => tracing::debug!("fakeapp HTTP/1.1 from {}: {}", remote, e),
        Err(_) => tracing::debug!("fakeapp HTTP/1.1 connection from {} timed out", remote),
    }
}

async fn serve_http1<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> std::io::Result<()> {
    // Only the head is read; a request body is never needed.
    let mut head = Vec::new();
    let mut buf = [0u8; 2048];
    let complete = loop {
        if head.windows(4).any(|w| w == b"\r\n\r\n") {
            break true;
        }
        if head.len() >= MAX_HEAD {
            break false;
        }
        let n = stream.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
    };

    // `METHOD SP target SP HTTP/1.x` on the first line.
    let line = String::from_utf8_lossy(head.split(|&b| b == b'\n').next().unwrap_or_default());
    let mut parts = line.trim_end().split(' ');
    let (method, target, version) =
        (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    let valid = complete
        && !method.is_empty()
        && method.bytes().all(|b| b.is_ascii_uppercase())
        && !target.is_empty()
        && version.starts_with("HTTP/1.")
        && parts.next().is_none();
    let resp = if valid {
        response(target.split('?').next().unwrap_or_default())
    } else {
        nginx_error(http::StatusCode::BAD_REQUEST)
    };

    let (parts, body) = resp.into_parts();
    let reason = parts.status.canonical_reason().unwrap_or("");
    let mut out = format!("HTTP/1.1 {} {}\r\n", parts.status.as_str(), reason);
    for (name, value) in &parts.headers {
        let value = value.to_str().unwrap_or_default();
        out.push_str(&format!("{}: {}\r\n", title_case(name.as_str()), value));
        if name == http::header::CONTENT_LENGTH {
            out.push_str("Connection: close\r\n"); // where nginx puts it
        }
    }
    out.push_str("\r\n");
    let mut out = out.into_bytes();
    if !(valid && method == "HEAD") {
        out.extend_from_slice(&body);
    }
    stream.write_all(&out).await?;
    stream.shutdown().await
}

/// `x-request-id` → `X-Request-Id`, as header names go out over HTTP/1.1.
fn title_case(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut up = true;
    for c in name.chars() {
        out.push(if up { c.to_ascii_uppercase() } else { c });
        up = c == '-';
    }
    out
}

fn response(path: &str) -> http::Response<Bytes> {
    let (content_type, payload): (&str, Bytes) = match path {
        "/" => (
            "text/html; charset=utf-8",
            Bytes::from_static(INDEX_HTML.as_bytes()),
        ),
        "/favicon.ico" => (
            "image/png",
            Bytes::from_static(FAVICON_PNG),
        ),
        "/robots.txt" => (
            "text/plain; charset=utf-8",
            Bytes::from_static(ROBOTS_TXT.as_bytes()),
        ),
        "/manifest.json" => (
            "application/manifest+json",
            Bytes::from_static(MANIFEST_JSON.as_bytes()),
        ),
        "/api/v1/health" => (
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
            ("application/json", Bytes::from(body))
        }
        _ => return nginx_error(http::StatusCode::NOT_FOUND),
    };

    http::Response::builder()
        .status(200)
        .header("server", "nginx")
        .header("date", http_date())
        .header("content-type", content_type)
        .header("content-length", payload.len().to_string())
        .header("cache-control", "public, max-age=3600")
        .header("x-request-id", format!("{:016x}", rand_u64()))
        .body(payload)
        .unwrap()
}

/// nginx's own error page with `server_tokens off` — byte-for-byte what the
/// relay's fallback sends.
fn nginx_error(status: http::StatusCode) -> http::Response<Bytes> {
    let status_line = format!("{} {}", status.as_str(), status.canonical_reason().unwrap_or(""));
    let body = format!(
        "<html>\r\n<head><title>{status_line}</title></head>\r\n<body>\r\n\
         <center><h1>{status_line}</h1></center>\r\n<hr><center>nginx</center>\r\n\
         </body>\r\n</html>\r\n"
    );
    http::Response::builder()
        .status(status)
        .header("server", "nginx")
        .header("date", http_date())
        .header("content-type", "text/html")
        .header("content-length", body.len().to_string())
        .body(Bytes::from(body))
        .unwrap()
}

/// IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT".
fn http_date() -> String {
    let t = time::OffsetDateTime::now_utc();
    format!(
        "{}, {:02} {} {} {:02}:{:02}:{:02} GMT",
        &t.weekday().to_string()[..3],
        t.day(),
        &t.month().to_string()[..3],
        t.year(),
        t.hour(),
        t.minute(),
        t.second()
    )
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

    async fn probe(req: &[u8]) -> String {
        let (mut probe, server) = tokio::io::duplex(64 * 1024);
        tokio::spawn(handle_http1(server, "127.0.0.1:1".parse().unwrap()));
        probe.write_all(req).await.unwrap();
        let mut resp = String::new();
        probe.read_to_string(&mut resp).await.unwrap();
        resp
    }

    /// An HTTP/1.1 prober gets the same site as over h2, with nginx's headers.
    #[tokio::test]
    async fn http1_probe_looks_like_nginx() {
        let resp = probe(b"GET /?x=1 HTTP/1.1\r\nHost: x\r\n\r\n").await;
        assert!(resp.starts_with("HTTP/1.1 200 OK\r\nServer: nginx\r\nDate: "), "{resp}");
        let len = format!("Content-Length: {}\r\nConnection: close\r\n", INDEX_HTML.len());
        assert!(resp.contains(&len), "{resp}");
        assert!(resp.ends_with(INDEX_HTML), "{resp}");

        let resp = probe(b"HEAD /nope HTTP/1.1\r\nHost: x\r\n\r\n").await;
        assert!(resp.starts_with("HTTP/1.1 404 Not Found\r\nServer: nginx\r\nDate: "), "{resp}");
        assert!(resp.ends_with("Connection: close\r\n\r\n"), "{resp}");

        let resp = probe(b"\x16\x03\x01garbage\r\n\r\n").await;
        assert!(resp.starts_with("HTTP/1.1 400 Bad Request\r\nServer: nginx\r\n"), "{resp}");
        assert!(resp.ends_with("<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n"), "{resp}");
    }
}
