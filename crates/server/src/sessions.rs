//! Серверный менеджер сессий: DashMap + cleanup + lookup.

use dashmap::DashMap;
use phantom_core::{
    crypto::NoiseSession,
    session::{ClientSession, ReplayWindow},
    wire::compute_ssrc,
};
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub type SessionMap = Arc<DashMap<u32, Arc<tokio::sync::Mutex<ClientSession>>>>;

pub fn new_session_map() -> SessionMap {
    Arc::new(DashMap::new())
}

/// Регистрирует новую сессию
pub async fn register_session(
    map: &SessionMap,
    ssrc: u32,
    addr: SocketAddr,
    noise: NoiseSession,
) {
    let session = Arc::new(tokio::sync::Mutex::new(
        ClientSession::new(ssrc, addr, noise)
    ));
    map.insert(ssrc, session);
    tracing::info!("Session registered: ssrc={:#010x} from {}", ssrc, addr);
}

/// Фоновая задача очистки устаревших сессий
pub async fn cleanup_task(map: SessionMap, idle_secs: u64) {
    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
    loop {
        interval.tick().await;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        let mut to_remove = Vec::new();
        for entry in map.iter() {
            let session = entry.value().try_lock();
            if let Ok(s) = session {
                if s.is_idle(idle_secs) {
                    to_remove.push(*entry.key());
                }
            }
        }
        for ssrc in &to_remove {
            map.remove(ssrc);
            tracing::info!("Session expired (idle): ssrc={:#010x}", ssrc);
        }
        if !to_remove.is_empty() {
            tracing::info!("Cleanup: removed {} sessions, {} active", to_remove.len(), map.len());
        }
    }
}
