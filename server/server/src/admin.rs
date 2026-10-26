//! Admin HTTP API server (embedded in phantom-server).
//! Listens on [admin].listen_addr (default 10.7.0.1:8080, only reachable through VPN tunnel)
//! with mTLS (admin = `is_admin` client cert), plus a loopback listener where
//! `Authorization: Bearer <token>` is accepted (only from 127.0.0.1 / ::1).

use std::net::{Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{ConnectInfo, Path as AxPath, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Json},
    routing::{delete, get, post},
    Router,
};
use base64::Engine;
use serde::Deserialize;

use crate::vpn_session::{self, ClientAllowList, SessionByFp, VpnSessionMap};

/// Mutex guarding all read-modify-write operations on the keyring file (clients.json).
/// Prevents TOCTOU race between admin API handlers and the subscription checker.
pub type KeyringLock = Arc<tokio::sync::Mutex<()>>;

#[derive(Clone)]
pub struct AdminState {
    pub sessions: VpnSessionMap,
    pub sessions_by_fp: SessionByFp,
    pub clients_path: PathBuf,
    /// Server tunnel address with prefix ([network].tun_addr, e.g. "10.7.0.1/24");
    /// new clients get the next free address of this subnet.
    pub tun_addr: String,
    pub token: String,
    pub admin_url: String,
    pub started_at: u64,
    pub allow_list: ClientAllowList,
    pub ca_cert_path: Option<PathBuf>,
    pub ca_key_path: Option<PathBuf>,
    pub server_addr: String,
    pub server_name: String,
    pub exit_ip: Option<String>,
    pub keyring_lock: KeyringLock,
}

// ─── Auth middleware ─────────────────────────────────────────────────────────

/// Shared token, accepted only from a loopback peer (the bot listener).
/// The mTLS listener inside the tunnel carries no ConnectInfo, so a leaked
/// token is useless to a VPN client.
fn bearer_token_matches(req: &Request, state: &AdminState) -> bool {
    let loopback = req.extensions().get::<ConnectInfo<SocketAddr>>()
        .map(|ci| ci.0.ip().is_loopback())
        .unwrap_or(false);
    loopback && req.headers()
        .get("Authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .map(|t| t == state.token)
        .unwrap_or(false)
}

/// Accept admin-privileged requests:
/// * loopback Bearer (bot / break-glass channel) — if `ClientIdentity` is absent
///   AND the shared token matches.
/// * mTLS with a client cert whose fingerprint is marked `is_admin` in keyring.
async fn require_admin(
    State(state): State<AdminState>,
    req: Request,
    next: Next,
) -> Result<impl IntoResponse, StatusCode> {
    let ident = req.extensions().get::<crate::admin_tls::ClientIdentity>().cloned();
    match ident {
        None => {
            // Loopback/plain path — require shared token
            if bearer_token_matches(&req, &state) {
                Ok(next.run(req).await)
            } else {
                Err(StatusCode::UNAUTHORIZED)
            }
        }
        Some(id) => {
            let keyring = read_keyring(&state.clients_path)?;
            let clients = keyring.get("clients").and_then(|c| c.as_object())
                .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
            let now = now_secs();
            // A disabled or expired admin is not an admin.
            let is_admin = clients.values().any(|info| {
                let fp_match = info.get("fingerprint").and_then(|v| v.as_str())
                    .map(|fp| fp.eq_ignore_ascii_case(&id.fingerprint)).unwrap_or(false);
                let admin = info.get("is_admin").and_then(|v| v.as_bool()).unwrap_or(false);
                let enabled = info.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
                let expired = info.get("expires_at").and_then(|v| v.as_u64())
                    .is_some_and(|e| e <= now);
                fp_match && admin && enabled && !expired
            });
            if is_admin {
                Ok(next.run(req).await)
            } else {
                Err(StatusCode::FORBIDDEN)
            }
        }
    }
}

/// Accept any valid client cert (mTLS) OR loopback+Bearer.
/// Used for /api/me where caller just needs to know "who am I".
async fn require_valid_client(
    State(state): State<AdminState>,
    req: Request,
    next: Next,
) -> Result<impl IntoResponse, StatusCode> {
    if req.extensions().get::<crate::admin_tls::ClientIdentity>().is_some() {
        return Ok(next.run(req).await);
    }
    if bearer_token_matches(&req, &state) {
        return Ok(next.run(req).await);
    }
    Err(StatusCode::UNAUTHORIZED)
}

// ─── GET /api/status ─────────────────────────────────────────────────────────

async fn get_status(State(state): State<AdminState>) -> Json<serde_json::Value> {
    let now = now_secs();
    Json(serde_json::json!({
        "uptime_secs": now.saturating_sub(state.started_at),
        "sessions_active": state.sessions.len(),
        "server_addr": state.server_addr,
        "exit_ip": state.exit_ip,
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
                    s.idle_secs(),
                )
            })
            .unwrap_or((false, 0, 0, 0));
        let expires_at = info.get("expires_at").and_then(|v| v.as_u64());
        let is_admin = info.get("is_admin").and_then(|v| v.as_bool()).unwrap_or(false);
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
            "expires_at": expires_at,
            "is_admin": is_admin,
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
    expires_days: Option<u32>,
    #[serde(default)]
    is_admin: bool,
}

async fn create_client(
    State(state): State<AdminState>,
    Json(body): Json<CreateClientBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    // The name ends up in file paths, URLs and the cert CN: [A-Za-z0-9_-]{1,32}.
    let name = body.name.trim().to_string();
    if name.is_empty() || name.len() > 32
        || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err(StatusCode::BAD_REQUEST);
    }

    // Generate client cert/key (CPU-intensive, do outside lock)
    let (cert_pem, key_pem, fingerprint) = match (&state.ca_cert_path, &state.ca_key_path) {
        (Some(ca_cert_path), Some(ca_key_path)) => {
            generate_client_cert(&name, ca_cert_path, ca_key_path)
                .map_err(|e| { tracing::error!("cert gen: {}", e); StatusCode::INTERNAL_SERVER_ERROR })?
        }
        _ => return Err(StatusCode::NOT_IMPLEMENTED),
    };

    let _guard = state.keyring_lock.lock().await;

    let mut keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get_mut("clients")
        .and_then(|c| c.as_object_mut())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    if clients.contains_key(&name) {
        return Err(StatusCode::CONFLICT);
    }

    // Find next free tun IP in the server's tunnel subnet (skipping network,
    // broadcast and the server's own address).
    let (server_ip, prefix) = state.tun_addr.split_once('/')
        .and_then(|(ip, p)| Some((ip.parse::<Ipv4Addr>().ok()?, p.parse::<u32>().ok()?)))
        .filter(|&(_, p)| p <= 30)
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let mask = if prefix == 0 { 0 } else { !0u32 << (32 - prefix) };
    let network = u32::from(server_ip) & mask;
    let used_ips: std::collections::HashSet<&str> = clients
        .values()
        .filter_map(|v| v.get("tun_addr").and_then(|t| t.as_str()))
        .filter_map(|t| t.split('/').next())
        .collect();
    let tun_addr = (1..!mask)
        .map(|i| Ipv4Addr::from(network + i))
        .find(|ip| *ip != server_ip && !used_ips.contains(ip.to_string().as_str()))
        .map(|ip| format!("{}/{}", ip, prefix))
        .ok_or(StatusCode::INSUFFICIENT_STORAGE)?;

    // Save cert files (key 0600, dirs 0700)
    let client_dir = state.clients_path.parent()
        .unwrap_or(Path::new("/opt/phantom-vpn/config"))
        .join("clients")
        .join(&name);
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&client_dir)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    }
    let cert_path = client_dir.join("client.crt");
    let key_path  = client_dir.join("client.key");
    std::fs::write(&cert_path, &cert_pem).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    write_private(&key_path, &key_pem).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    // Add to clients.json. expires_days = 0 (Apple clients' "∞") = no expiry.
    let now = chrono_now_iso();
    let expires_at: Option<u64> = body.expires_days.filter(|&d| d > 0)
        .map(|d| now_secs() + d as u64 * 86400);
    clients.insert(name.clone(), serde_json::json!({
        "fingerprint": fingerprint,
        "cert_path": cert_path.to_string_lossy(),
        "key_path":  key_path.to_string_lossy(),
        "tun_addr":  tun_addr,
        "enabled":   true,
        "created_at": now,
        "expires_at": expires_at,
        "is_admin":   body.is_admin,
    }));
    write_keyring(&state.clients_path, &keyring)?;

    // Reload allow list
    reload_allow_list(&state.clients_path, &state.allow_list).await;

    drop(_guard);

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
    let _guard = state.keyring_lock.lock().await;

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
        if let Some(parent) = Path::new(p).parent() {
            let _ = std::fs::remove_dir(parent);
        }
    }

    write_keyring(&state.clients_path, &keyring)?;
    reload_allow_list(&state.clients_path, &state.allow_list).await;

    // Kick the live session too, like disable does.
    if let Some(fp) = info.get("fingerprint").and_then(|v| v.as_str()) {
        if vpn_session::evict_fp(&state.sessions, &state.sessions_by_fp, fp) {
            tracing::info!("Admin: deleted client '{}', session evicted", name);
        }
    }
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
) -> Result<Json<serde_json::Value>, (StatusCode, &'static str)> {
    set_client_enabled(&state, &name, true).await.map_err(|s| match s {
        // Otherwise the subscription checker silently disables it again within a minute.
        StatusCode::CONFLICT => (s, "subscription expired: extend it or make it unlimited first"),
        _ => (s, ""),
    })
}

// ─── POST /api/clients/:name/subscription ────────────────────────────────────
// body: {"action": "extend"|"set"|"cancel"|"revoke", "days": N}
// extend: adds days to current expiry (or from now if expired/no expiry)
// set:    sets expiry to now + N days
// cancel: removes expiry (access never expires); leaves `enabled` as is
// revoke: disables immediately + sets expires_at to now

#[derive(Deserialize)]
struct SubscriptionBody {
    action: String,
    days: Option<u32>,
}

async fn manage_subscription(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
    Json(body): Json<SubscriptionBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let _guard = state.keyring_lock.lock().await;

    let mut keyring = read_keyring(&state.clients_path)?;
    let now = now_secs();

    // Collect fingerprint and current expires_at from immutable borrow first
    let (fingerprint, current_expires): (Option<String>, Option<u64>) = {
        let clients = keyring.get("clients").and_then(|c| c.as_object())
            .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
        let info = clients.get(&name).ok_or(StatusCode::NOT_FOUND)?;
        let fp = info.get("fingerprint").and_then(|v| v.as_str()).map(String::from);
        let exp = info.get("expires_at").and_then(|v| v.as_u64());
        (fp, exp)
    };

    let new_expires: Option<u64> = match body.action.as_str() {
        "cancel" => None,
        "set" => {
            let days = body.days.ok_or(StatusCode::BAD_REQUEST)?;
            Some(now + days as u64 * 86400)
        }
        "extend" => {
            let days = body.days.ok_or(StatusCode::BAD_REQUEST)?;
            let base = current_expires.map(|e| e.max(now)).unwrap_or(now);
            Some(base + days as u64 * 86400)
        }
        "revoke" => Some(now), // expires right now → cleanup will disable
        _ => return Err(StatusCode::BAD_REQUEST),
    };

    let immediately_disable = body.action == "revoke"
        || new_expires.map(|e| e <= now).unwrap_or(false);

    // Mutate keyring
    {
        let clients = keyring.get_mut("clients").and_then(|c| c.as_object_mut())
            .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
        let client = clients.get_mut(&name).ok_or(StatusCode::NOT_FOUND)?;
        if let Some(obj) = client.as_object_mut() {
            match new_expires {
                Some(ts) => { obj.insert("expires_at".to_string(), serde_json::Value::Number(ts.into())); }
                None     => { obj.remove("expires_at"); }
            }
            if immediately_disable {
                obj.insert("enabled".to_string(), serde_json::Value::Bool(false));
            } else if new_expires.is_some_and(|e| e > now) {
                // Re-enable if extending/setting a future expiry. `cancel` keeps
                // a manual block in place.
                obj.insert("enabled".to_string(), serde_json::Value::Bool(true));
            }
        }
    }

    write_keyring(&state.clients_path, &keyring)?;
    reload_allow_list(&state.clients_path, &state.allow_list).await;

    if immediately_disable {
        if let Some(fp) = fingerprint {
            if vpn_session::evict_fp(&state.sessions, &state.sessions_by_fp, &fp) {
                tracing::info!("Subscription revoked for '{}', evicting session", name);
            }
        }
    }

    Ok(Json(serde_json::json!({ "ok": true, "expires_at": new_expires })))
}

// ─── POST /api/clients/:name/admin { "is_admin": true } ─────────────────────

#[derive(Deserialize)]
struct SetAdminBody {
    is_admin: bool,
}

async fn set_client_admin(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
    Json(body): Json<SetAdminBody>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let _guard = state.keyring_lock.lock().await;
    let mut keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get_mut("clients")
        .and_then(|c| c.as_object_mut())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let client = clients.get_mut(&name).ok_or(StatusCode::NOT_FOUND)?;
    if let Some(obj) = client.as_object_mut() {
        obj.insert("is_admin".to_string(), serde_json::Value::Bool(body.is_admin));
    }
    write_keyring(&state.clients_path, &keyring)?;
    Ok(Json(serde_json::json!({ "ok": true, "is_admin": body.is_admin })))
}

// ─── GET /api/me — requires valid client cert (via mTLS) ─────────────────────

async fn get_me(
    State(state): State<AdminState>,
    req: Request,
) -> Result<Json<serde_json::Value>, StatusCode> {
    // Try to get ClientIdentity from extensions (mTLS path)
    if let Some(ident) = req.extensions().get::<crate::admin_tls::ClientIdentity>() {
        let keyring = read_keyring(&state.clients_path)?;
        let clients = keyring.get("clients").and_then(|c| c.as_object())
            .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
        for (name, info) in clients {
            let fp = info.get("fingerprint").and_then(|v| v.as_str()).unwrap_or("");
            if fp.eq_ignore_ascii_case(&ident.fingerprint) {
                // Same fields/types as the entry in /api/clients: this is where
                // a non-admin client learns its own subscription.
                let is_admin = info.get("is_admin").and_then(|v| v.as_bool()).unwrap_or(false);
                let enabled = info.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
                let expires_at = info.get("expires_at").and_then(|v| v.as_u64());
                return Ok(Json(serde_json::json!({
                    "name": name,
                    "is_admin": is_admin,
                    "enabled": enabled,
                    "expires_at": expires_at,
                })));
            }
        }
        return Err(StatusCode::NOT_FOUND);
    }
    // Loopback/bot path — has no client identity
    Err(StatusCode::BAD_REQUEST)
}

async fn set_client_enabled(
    state: &AdminState,
    name: &str,
    enabled: bool,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let _guard = state.keyring_lock.lock().await;

    let mut keyring = read_keyring(&state.clients_path)?;
    let clients = keyring
        .get_mut("clients")
        .and_then(|c| c.as_object_mut())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;

    let client = clients.get_mut(name).ok_or(StatusCode::NOT_FOUND)?;

    // Enabling an expired client would be undone by the subscription checker.
    if enabled && client.get("expires_at").and_then(|v| v.as_u64()).is_some_and(|e| e <= now_secs()) {
        return Err(StatusCode::CONFLICT);
    }

    // Extract fingerprint before mutating (needed to find active session)
    let fingerprint = client.get("fingerprint").and_then(|v| v.as_str()).map(String::from);

    if let Some(obj) = client.as_object_mut() {
        obj.insert("enabled".to_string(), serde_json::Value::Bool(enabled));
    }

    write_keyring(&state.clients_path, &keyring)?;
    reload_allow_list(&state.clients_path, &state.allow_list).await;

    // If disabling, evict the session immediately: out of both routing maps,
    // closed (RX loops stop forwarding uplink, writers send FIN). Reconnects
    // are refused in the TLS handshake.
    if !enabled {
        if let Some(fp) = fingerprint {
            if vpn_session::evict_fp(&state.sessions, &state.sessions_by_fp, &fp) {
                tracing::info!("Admin: evicting session and closing connection for disabled client '{}'", name);
            }
        }
    }

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

// ─── GET /api/clients/:name/logs ─────────────────────────────────────────────

async fn get_client_logs(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let keyring = read_keyring(&state.clients_path)?;
    let clients = keyring.get("clients").and_then(|c| c.as_object())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let info = clients.get(&name).ok_or(StatusCode::NOT_FOUND)?;
    let tun_ip: Option<std::net::IpAddr> = info
        .get("tun_addr").and_then(|v| v.as_str())
        .and_then(|s| s.split('/').next())
        .and_then(|s| s.parse().ok());

    let entries = tun_ip
        .and_then(|ip| state.sessions.get(&ip))
        .map(|s| {
            s.dest_log.lock().ok()
                .map(|log| log.iter().rev().take(200).map(|e| serde_json::json!({
                    "ts":    e.ts,
                    "dst":   e.dst_host.as_deref().unwrap_or(&e.dst_ip.to_string()),
                    "port":  e.dst_port,
                    "proto": match e.proto { 6 => "tcp", 17 => "udp", 1 => "icmp", _ => "raw" },
                    "bytes": e.bytes,
                })).collect::<Vec<_>>())
                .unwrap_or_default()
        })
        .unwrap_or_default();

    Ok(Json(serde_json::json!(entries)))
}

// ─── GET /api/clients/:name/stats ────────────────────────────────────────────

async fn get_client_stats(
    State(state): State<AdminState>,
    AxPath(name): AxPath<String>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let keyring = read_keyring(&state.clients_path)?;
    let clients = keyring.get("clients").and_then(|c| c.as_object())
        .ok_or(StatusCode::INTERNAL_SERVER_ERROR)?;
    let info = clients.get(&name).ok_or(StatusCode::NOT_FOUND)?;
    let tun_ip: Option<std::net::IpAddr> = info
        .get("tun_addr").and_then(|v| v.as_str())
        .and_then(|s| s.split('/').next())
        .and_then(|s| s.parse().ok());

    let samples = tun_ip
        .and_then(|ip| state.sessions.get(&ip))
        .map(|s| {
            s.stats_samples.lock().ok()
                .map(|samps| samps.iter().map(|s| serde_json::json!({
                    "ts":       s.ts,
                    "bytes_rx": s.bytes_rx,
                    "bytes_tx": s.bytes_tx,
                })).collect::<Vec<_>>())
                .unwrap_or_default()
        })
        .unwrap_or_default();

    Ok(Json(serde_json::json!(samples)))
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
        .route("/api/clients/:name/logs",         get(get_client_logs))
        .route("/api/clients/:name/stats",        get(get_client_stats))
        .route("/api/clients/:name/subscription", post(manage_subscription))
        .route("/api/clients/:name/admin", post(set_client_admin))
        .layer(middleware::from_fn_with_state(state.clone(), require_admin));

    // /api/me — requires only a valid client cert (handled inside handler)
    let me = Router::new()
        .route("/api/me", get(get_me))
        .layer(middleware::from_fn_with_state(state.clone(), require_valid_client));

    Router::new().merge(protected).merge(me).with_state(state)
}

// (admin listeners live in admin_tls::{run_mtls, run_plain})

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
    use std::io::Write;

    let content = serde_json::to_string_pretty(keyring)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let tmp = path.with_extension("json.tmp");
    let mut f = std::fs::File::create(&tmp)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    f.write_all(content.as_bytes())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    f.sync_all()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    std::fs::rename(&tmp, path)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(())
}

/// Write a private key readable by the owner only (0600).
pub(crate) fn write_private(path: &Path, data: &str) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut f = std::fs::OpenOptions::new()
        .write(true).create(true).truncate(true).mode(0o600)
        .open(path)?;
    // mode() only applies to a new file; tighten a pre-existing one too.
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    f.write_all(data.as_bytes())
}

async fn reload_allow_list(clients_path: &Path, allow_list: &ClientAllowList) {
    match vpn_session::load_allow_list(clients_path) {
        Ok(fps) => {
            tracing::info!("Allow list reloaded: {} entries", fps.len());
            vpn_session::set_allow_list(allow_list, fps);
        }
        Err(e) => tracing::error!("Failed to reload allow list: {}", e),
    }
}

fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.as_bytes() {
        let c = *b;
        let safe = matches!(c,
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' |
            b'-' | b'_' | b'.' | b'~'
        );
        if safe {
            out.push(c as char);
        } else {
            out.push_str(&format!("%{:02X}", c));
        }
    }
    out
}

fn build_conn_string(server_addr: &str, server_name: &str, tun_addr: &str, cert_pem: &str, key_pem: &str) -> String {
    // Userinfo = base64url(cert_pem + "\n" + key_pem)
    let mut pem = String::with_capacity(cert_pem.len() + key_pem.len() + 1);
    pem.push_str(cert_pem.trim_end());
    pem.push('\n');
    pem.push_str(key_pem.trim());
    let userinfo = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(pem.as_bytes());
    format!(
        "ghs://{}@{}?sni={}&tun={}&v=1",
        userinfo,
        server_addr,
        url_encode(server_name),
        url_encode(tun_addr),
    )
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

// ─── Subscription expiry checker (spawned from main) ─────────────────────────

pub async fn run_subscription_checker(
    clients_path: std::path::PathBuf,
    sessions: VpnSessionMap,
    sessions_by_fp: SessionByFp,
    allow_list: ClientAllowList,
    keyring_lock: KeyringLock,
) {
    let mut last_wall = now_secs();
    let mut last_mono = std::time::Instant::now();
    loop {
        tokio::time::sleep(tokio::time::Duration::from_secs(60)).await;

        let now = now_secs();

        // Expiry is wall-clock by nature. If the wall clock jumped by more than
        // an hour against the monotonic one (bad NTP step, manual date), skip
        // this tick instead of mass-disabling clients; the next tick runs
        // against the new baseline.
        let mono_elapsed = last_mono.elapsed().as_secs() as i64;
        let wall_elapsed = now as i64 - last_wall as i64;
        last_wall = now;
        last_mono = std::time::Instant::now();
        if (wall_elapsed - mono_elapsed).abs() > 3600 {
            tracing::warn!(
                "Subscription checker: wall clock jumped by {} s, skipping this tick",
                wall_elapsed - mono_elapsed
            );
            continue;
        }

        let _guard = keyring_lock.lock().await;

        let content = match std::fs::read_to_string(&clients_path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let mut keyring: serde_json::Value = match serde_json::from_str(&content) {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Collect expired clients (immutable pass)
        let (expired_names, to_evict): (Vec<String>, Vec<String>) = {
            let clients = match keyring.get("clients").and_then(|c| c.as_object()) {
                Some(c) => c,
                None => continue,
            };
            let mut names = Vec::new();
            let mut fps = Vec::new();
            for (name, info) in clients.iter() {
                let expires_at = info.get("expires_at").and_then(|v| v.as_u64());
                let enabled = info.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
                if expires_at.map(|e| e <= now).unwrap_or(false) && enabled {
                    names.push(name.clone());
                    if let Some(fp) = info.get("fingerprint").and_then(|v| v.as_str()) {
                        fps.push(fp.to_string());
                    }
                }
            }
            (names, fps)
        };

        if expired_names.is_empty() {
            continue;
        }

        // Disable expired clients (mutable pass)
        {
            let clients = match keyring.get_mut("clients").and_then(|c| c.as_object_mut()) {
                Some(c) => c,
                None => continue,
            };
            for name in &expired_names {
                if let Some(info) = clients.get_mut(name.as_str()) {
                    if let Some(obj) = info.as_object_mut() {
                        obj.insert("enabled".to_string(), serde_json::Value::Bool(false));
                        tracing::info!("Subscription expired for '{}', disabling", name);
                    }
                }
            }
        }

        let _ = write_keyring(&clients_path, &keyring);

        match vpn_session::load_allow_list(&clients_path) {
            Ok(fps) => vpn_session::set_allow_list(&allow_list, fps),
            Err(e) => tracing::error!("Subscription checker: reload allow list failed: {}", e),
        }

        drop(_guard);

        for fp in to_evict {
            vpn_session::evict_fp(&sessions, &sessions_by_fp, &fp);
        }
    }
}
