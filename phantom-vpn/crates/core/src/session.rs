//! Управление сессиями: sliding window, replay protection, session lifecycle.

use crate::error::PacketError;
use crate::crypto::NoiseSession;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Скользящее окно для защиты от Replay-атак (64 пакета)
pub struct ReplayWindow {
    last_seq: u16,
    window:   u64, // битовая маска: бит i = пакет (last_seq - i) уже получен
    initialized: bool,
}

impl ReplayWindow {
    pub fn new() -> Self {
        Self { last_seq: 0, window: 0, initialized: false }
    }

    /// Возвращает Ok(()) если пакет допустим, и регистрирует его.
    /// Возвращает Err при дубликате или слишком старом пакете.
    pub fn check_and_update(&mut self, seq: u16) -> Result<(), PacketError> {
        if !self.initialized {
            self.last_seq = seq;
            self.window = 1;
            self.initialized = true;
            return Ok(());
        }

        let diff = seq.wrapping_sub(self.last_seq);

        if diff == 0 {
            return Err(PacketError::Replay(seq));
        }

        if diff < 32768 {
            // Пакет новее last_seq
            if diff >= 64 {
                // Очень новый — сдвигаем окно полностью
                self.window = 1;
            } else {
                self.window = self.window.wrapping_shl(diff as u32) | 1;
            }
            self.last_seq = seq;
        } else {
            // Пакет старше last_seq
            let back = (self.last_seq.wrapping_sub(seq)) as u64;
            if back >= 64 {
                return Err(PacketError::Replay(seq)); // слишком старый
            }
            let bit = 1u64 << back;
            if self.window & bit != 0 {
                return Err(PacketError::Replay(seq)); // дубликат
            }
            self.window |= bit;
        }
        Ok(())
    }
}

// ─── Проверка timestamp ──────────────────────────────────────────────────────

/// Timestamp в RTP — 90000 Hz, т.е. 1 секунда = 90000 единиц.
/// Проверяем, что пакет не устарел более чем на 5 секунд.
pub fn check_rtp_timestamp(pkt_ts: u32, local_ts: u32, max_diff_secs: u32) -> Result<(), PacketError> {
    let max_diff = max_diff_secs * 90000;
    let diff = pkt_ts.wrapping_sub(local_ts);
    // Wrapping diff > max_diff в обе стороны считается устаревшим
    if diff > max_diff && (!diff).wrapping_add(1) > max_diff {
        return Err(PacketError::StaleTimestamp(diff / 90000));
    }
    Ok(())
}

/// Возвращает текущий RTP timestamp (90000 Hz)
pub fn current_rtp_timestamp() -> u32 {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    (secs * 90000) as u32
}

// ─── Сессия клиента ─────────────────────────────────────────────────────────

pub struct ClientSession {
    pub ssrc:         u32,
    pub client_addr:  SocketAddr,
    pub noise:        NoiseSession,
    pub replay_win:   ReplayWindow,
    pub bytes_sent:   AtomicU64,
    pub bytes_recv:   AtomicU64,
    pub last_seen_ts: AtomicU64, // Unix secs
    pub rekeying:     AtomicBool,
    pub tx_seq:       u16,
}

impl ClientSession {
    pub fn new(ssrc: u32, client_addr: SocketAddr, noise: NoiseSession) -> Self {
        Self {
            ssrc,
            client_addr,
            noise,
            replay_win:    ReplayWindow::new(),
            bytes_sent:    AtomicU64::new(0),
            bytes_recv:    AtomicU64::new(0),
            last_seen_ts:  AtomicU64::new(unix_now()),
            rekeying:      AtomicBool::new(false),
            tx_seq:        rand::random(),
        }
    }

    pub fn touch(&self) {
        self.last_seen_ts.store(unix_now(), Ordering::Relaxed);
    }

    pub fn is_idle(&self, idle_secs: u64) -> bool {
        unix_now().saturating_sub(self.last_seen_ts.load(Ordering::Relaxed)) > idle_secs
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replay_window_basic() {
        let mut win = ReplayWindow::new();
        // Первый пакет всегда принимается
        assert!(win.check_and_update(100).is_ok());
        // Дубликат
        assert!(win.check_and_update(100).is_err());
        // Последовательные новые
        assert!(win.check_and_update(101).is_ok());
        assert!(win.check_and_update(102).is_ok());
        // Старый в пределах окна — принимается
        assert!(win.check_and_update(99).is_ok());
        // Уже принятый
        assert!(win.check_and_update(99).is_err());
    }

    #[test]
    fn test_replay_window_too_old() {
        let mut win = ReplayWindow::new();
        win.check_and_update(200).unwrap();
        win.check_and_update(264).unwrap(); // last = 264
        // 200 — слишком старый (264-200=64 >= 64)
        assert!(win.check_and_update(200).is_err());
    }

    #[test]
    fn test_replay_window_wrap() {
        let mut win = ReplayWindow::new();
        win.check_and_update(65534).unwrap();
        win.check_and_update(65535).unwrap();
        win.check_and_update(0).unwrap();    // wrap
        win.check_and_update(1).unwrap();
        assert!(win.check_and_update(65534).is_err()); // слишком старый
    }
}
