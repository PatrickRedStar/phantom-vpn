//! Admin HTTP API server (embedded in phantom-server).
//! Listens on [admin].listen_addr (default 10.7.0.1:8080, only reachable through VPN tunnel).
//! All endpoints require: Authorization: Bearer <token>

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{Path as AxPath, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Json},
    routing::{delete, get, post},
    Router,
};
use base64::Engine;
use serde::Deserialize;

use crate::quic_server::{ClientAllowList, QuicSessionMap};

#[derive(Clone)]
pub struct AdminState {
    pub sessions: QuicSessionMap,
    pub clients_path: PathBuf,
    pub token: String,
    pub started_at: u64,
    pub allow_list: ClientAllowList,
    pub ca_cert_path: Option<PathBuf>,
    pub ca_key_path: Option<PathBuf>,
    pub server_addr: String,
    pub server_name: String,
}

// ─── Auth middleware ─────────────────────────────────────────────────────────

async fn require_token(
    State(state): State<AdminState>,
    req: Request,
    next: Next,
) -> Result<impl IntoResponse, StatusCode> {
    let token_ok = req
        .headers()
        .get("Authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|t| t == state.token)
        .unwrap_or(false);
    if !token_ok {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(next.run(req).await)
}

// ─── GET /api/status ─────────────────────────────────────────────────────────

async fn get_status(State(state): State<AdminState>) -> Json<serde_json::Value> {
    let now = now_secs();
    Json(serde_json::json!({
        "uptime_secs": now.saturating_sub(state.started_at),
        "sessions_active": state.sessions.len(),
        "server_addr": state.server_addr,
    }))
}

// ─── GET /api/clients ────────────────────────────────────────────────────────

async fn get_clients(
    State(state): State<AdminState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get("clients")
        .and_then(|c| c.as_object())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let now = now_secs();
    let mut result = Vec::new();
    for (name, info) in clients {
        let fp = info.get("fingerprint").and_then(|f| f.as_str()).unwrap_or("");
        let tun_addr = info.get("tun_addr").and_then(|t| t.as_str()).unwrap_or("");
        let enabled = info.get("enabled").and_then(|e| e.as_bool()).unwrap_or(true);
        let created_at = info.get("created_at").and_then(|c| c.as_str()).unwrap_or("");

        let tun_ip: Option<std::net::IpAddr> = tun_addr.split('/').next().and_then(|s| s.parse().ok());
        let (connected, bytes_rx, bytes_tx, last_seen_secs) = tun_ip
            .and_then(|ip| state.sessions.get(&ip))
            .map(|s| {
                (
                    true,
                    s.bytes_rx.load(Ordering::Relaxed),
                    s.bytes_tx.load(Ordering::Relaxed),
                    now.saturating_sub(s.last_seen.load(Ordering::Relaxed)),
                )
            })
            .unwrap_or((false, 0, 0, 0));
        result.push(serde_json::json!({
            "name": name,
            "fingerprint": fp,
            "tun_addr": tun_addr,
            "enabled": enabled,
            "created_at": created_at,
            "connected": connected,
            "bytes_rx": bytes_rx,
            "bytes_tx": bytes_tx,
            "last_seen_secs": last_seen_secs,
        }));
    }
    result.sort_by(|a, b| {
        a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or(""))
    });
    Ok(Json(serde_json::json!(result)))
}

// ─── POST /api/clients  { "name": "alice" } ──────────────────────────────────

#[derive(Deserialize)]
struct CreateClientBody {
    name: String,
}

async fn create_client(
    State(state): State<AdminState>,
    Json(body): Json<CreateClientBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let name = body.name.trim().to_string();
    if name.is_empty() || name.contains('/') || name.contains('.') {
        return Err(StatusCode::BAD_REQUEST);
    }

    let mut keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get_mut("clients")
        .and_then(|c| c.as_object_mut())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    if clients.contains_key(&name) {
        return Err(StatusCode::CONFLICT);
    }

    // Find next free tun IP
    let used_ips: std::collections::HashSet<String> = clients
        .values()
        .filter_map(|v| v.get("tun_addr").and_then(|t| t.as_str()).map(String::from))
        .collect();
    let tun_addr = (2u8..=254)
        .map(|i| format!("10.7.0.{}/24", i))
        .find(|addr| !used_ips.contains(addr))
        .ok_or(StatusCode::INSUFFICIENT_STORAGE)?;

    // Generate client cert/key
    let (cert_pem, key_pem, fingerprint) = match (&state.ca_cert_path, &state.ca_key_path) {
        (Some(ca_cert_path), Some(ca_key_path)) => {
            generate_client_cert(&name, ca_cert_path, ca_key_path)
                .map_err(|e| { tracing::error!("cert gen: {}", e); StatusCode::INTERNAL_SERVER_ERROR })?
        }
        _ => return Err(StatusCode::NOT_IMPLEMENTED),
    };

    // Save cert files
    let client_dir = state.clients_path.parent()
        .unwrap_or(Path::new("/opt/phantom-vpn/config"))
        .join("clients")
        .join(&name);
    std::fs::create_dir_all(&client_dir)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let cert_path = client_dir.join("client.crt");
    let key_path  = client_dir.join("client.key");
    std::fs::write(&cert_path, &cert_pem).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    std::fs::write(&key_path,  &key_pem).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Add to clients.json
    let now = chrono_now_iso();
    clients.insert(name.clone(), serde_json::json!({
        "fingerprint": fingerprint,
        "cert_path": cert_path.to_string_lossy(),
        "key_path":  key_path.to_string_lossy(),
        "tun_addr":  tun_addr,
        "enabled":   true,
        "created_at": now,
    }));
    write_keyring(&state.clients_path, &keyring)?;

    // Reload allow list
    reload_allow_list(&state.clients_path, &state.allow_list).await;

    // Build conn_string
    let conn_str = build_conn_string(&state.server_addr, &state.server_name, &tun_addr, &cert_pem, &key_pem);

    Ok(Json(serde_json::json!({
        "name": name,
        "tun_addr": tun_addr,
        "fingerprint": fingerprint,
        "conn_string": conn_str,
    })))
}

// ─── DELETE /api/clients/:name ───────────────────────────────────────────────

async fn delete_client(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let mut keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get_mut("clients")
        .and_then(|c| c.as_object_mut())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    let info = clients.remove(&name).ok_or(StatusCode::NOT_FOUND)?;

    // Remove cert files
    for key in ["cert_path", "key_path"] {
        if let Some(p) = info.get(key).and_then(|v| v.as_str()) {
            let _ = std::fs::remove_file(p);
        }
    }
    // Try to remove empty dir
    if let Some(p) = info.get("cert_path").and_then(|v| v.as_str()) {
        let _ = std::fs::remove_dir(Path::new(p).parent().unwrap_or(Path::new("/")));
    }

    write_keyring(&state.clients_path, &keyring)?;
    reload_allow_list(&state.clients_path, &state.allow_list).await;
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ─── POST /api/clients/:name/disable ─────────────────────────────────────────

async fn disable_client(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    set_client_enabled(&state, &name, false).await
}

async fn enable_client(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    set_client_enabled(&state, &name, true).await
}

async fn set_client_enabled(
    state: &AdminState,
    name: &str,
    enabled: bool,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let mut keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get_mut("clients")
        .and_then(|c| c.as_object_mut())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    let client = clients.get_mut(name).ok_or(StatusCode::NOT_FOUND)?;
    if let Some(obj) = client.as_object_mut() {
        obj.insert("enabled".to_string(), serde_json::Value::Bool(enabled));
    }

    write_keyring(&state.clients_path, &keyring)?;
    reload_allow_list(&state.clients_path, &state.allow_list).await;
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ─── GET /api/clients/:name/conn_string ──────────────────────────────────────

async fn get_conn_string(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let keyring = read_keyring(&state.clients_path)?;
    let clients = keyring.get("clients").and_then(|c| c.as_object())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let info = clients.get(&name).ok_or(StatusCode::NOT_FOUND)?;

    let cert_path = info.get("cert_path").and_then(|v| v.as_str()).ok_or(StatusCode::NOT_FOUND)?;
    let key_path  = info.get("key_path").and_then(|v| v.as_str()).ok_or(StatusCode::NOT_FOUND)?;
    let tun_addr  = info.get("tun_addr").and_then(|v| v.as_str()).unwrap_or("10.7.0.2/24");

    let cert_pem = std::fs::read_to_string(cert_path).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let key_pem  = std::fs::read_to_string(key_path).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let conn_str = build_conn_string(&state.server_addr, &state.server_name, tun_addr, &cert_pem, &key_pem);

    Ok(Json(serde_json::json!({ "conn_string": conn_str })))
}

// ─── Router ──────────────────────────────────────────────────────────────────

pub fn make_router(state: AdminState) -> Router {
    let protected = Router::new()
        .route("/api/status",  get(get_status))
        .route("/api/clients", get(get_clients))
        .route("/api/clients", post(create_client))
        .route("/api/clients/:name", delete(delete_client))
        .route("/api/clients/:name/disable", post(disable_client))
        .route("/api/clients/:name/enable",  post(enable_client))
        .route("/api/clients/:name/conn_string", get(get_conn_string))
        .layer(middleware::from_fn_with_state(state.clone(), require_token));
    Router::new().merge(protected).with_state(state)
}

pub async fn run(listen_addr: SocketAddr, state: AdminState) -> anyhow::Result<()> {
    let app = make_router(state);
    tracing::info!("Admin HTTP API listening on {}", listen_addr);
    let listener = tokio::net::TcpListener::bind(listen_addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

fn chrono_now_iso() -> String {
    let secs = now_secs();
    let s = time::OffsetDateTime::from_unix_timestamp(secs as i64)
        .unwrap_or(time::OffsetDateTime::UNIX_EPOCH);
    s.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| secs.to_string())
}

fn read_keyring(path: &Path) -> Result<serde_json::Value, StatusCode> {
    let content = std::fs::read_to_string(path).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    serde_json::from_str(&content).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

fn write_keyring(path: &Path, keyring: &serde_json::Value) -> Result<(), StatusCode> {
    let content = serde_json::to_string_pretty(keyring).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    std::fs::write(path, content).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

async fn reload_allow_list(clients_path: &Path, allow_list: &ClientAllowList) {
    match crate::quic_server::load_allow_list(clients_path) {
        Ok(fps) => {
            let mut list = allow_list.write().await;
            *list = fps;
            tracing::info!("Allow list reloaded: {} entries", list.len());
        }
        Err(e) => tracing::error!("Failed to reload allow list: {}", e),
    }
}

fn build_conn_string(server_addr: &str, server_name: &str, tun_addr: &str, cert_pem: &str, key_pem: &str) -> String {
    let payload = serde_json::json!({
        "v": 1,
        "addr": server_addr,
        "sni": server_name,
        "tun": tun_addr,
        "cert": cert_pem,
        "key": key_pem,
    });
    let json_bytes = serde_json::to_vec(&payload).unwrap_or_default();
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&json_bytes)
}

fn generate_client_cert(
    name: &str,
    ca_cert_path: &Path,
    ca_key_path: &Path,
) -> anyhow::Result<(String, String, String)> {
    use sha2::{Digest, Sha256};

    let ca_cert_pem = std::fs::read_to_string(ca_cert_path)?;
    let ca_key_pem  = std::fs::read_to_string(ca_key_path)?;

    let ca_key    = rcgen::KeyPair::from_pem(&ca_key_pem)?;
    let ca_params = rcgen::CertificateParams::from_ca_cert_pem(&ca_cert_pem)?;
    // Build a CA Certificate object (needed as issuer for signed_by)
    let ca_cert   = ca_params.self_signed(&ca_key)?;

    let client_key = rcgen::KeyPair::generate()?;
    let mut params = rcgen::CertificateParams::new(vec![])?;
    params.distinguished_name.push(rcgen::DnType::CommonName, name);
    params.is_ca = rcgen::IsCa::NoCa;
    params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ClientAuth];

    let client_cert = params.signed_by(&client_key, &ca_cert, &ca_key)?;

    // Get DER bytes and PEM
    let cert_pem = client_cert.pem();
    let key_pem  = client_key.serialize_pem();

    // Fingerprint from DER
    let der = client_cert.der();
    let hash = Sha256::digest(der.as_ref());
    let fingerprint: String = hash.iter().map(|b| format!("{:02x}", b)).collect();

    Ok((cert_pem, key_pem, fingerprint))
}

