//! H.264 Traffic Shaper: имитирует паттерн видеопотока для обхода DPI.
//! State Machine: 30 FPS, GoP=60 кадров (2 секунды), LogNormal для P-фреймов.

use crate::error::ShaperError;
use rand_distr::{LogNormal, Distribution};
use rand::Rng;
use std::time::{Duration, Instant};

// ─── Константы ──────────────────────────────────────────────────────────────

pub const FPS: u32 = 30;
pub const GOP_SIZE: u32 = 60;          // 2 секунды
pub const TICK_MICROS: u64 = 33_333;   // 33.3 мс
pub const STRICT_PHASE_SECS: u64 = 5; // Строгая WebRTC имитация первые 5 сек

/// Параметры LogNormal для P-фреймов
/// μ=7.0, σ=0.8 → медиана ~1096 байт, 95-й перцентиль ~3600 байт
pub const LOGNORMAL_MU: f64 = 7.0;
pub const LOGNORMAL_SIGMA: f64 = 0.8;

/// Диапазон I-frame в байтах
pub const IFRAME_MIN: usize = 15_000;
pub const IFRAME_MAX: usize = 50_000;

/// Минимальный/максимальный P-frame
pub const PFRAME_MIN: usize = 60;
pub const PFRAME_MAX: usize = 8_000;

// ─── Тип кадра ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FrameType {
    IFrame, // Ключевой кадр (большой burst)
    PFrame, // Промежуточный (маленький, часто)
}

#[derive(Debug, Clone)]
pub struct FrameTarget {
    pub frame_type:   FrameType,
    pub target_bytes: usize,
    pub timestamp:    u32, // RTP timestamp для этого кадра
    pub frame_index:  u32, // Индекс в GoP (0..59)
}

// ─── Главный шейпер ─────────────────────────────────────────────────────────

/// Number of consecutive oversize frames before turbo mode activates
const TURBO_THRESHOLD: u32 = 8;

pub struct H264Shaper {
    frame_counter: u32,
    lognormal:     LogNormal<f64>,
    rtp_timestamp: u32,
    started_at:    Instant,

    // Адаптивный режим
    idle_fps:      u32, // FPS в фазе покоя (после strict phase)

    // Turbo mode: skip padding when sustained high throughput
    turbo_streak:  u32, // consecutive frames where data > target
}

impl H264Shaper {
    pub fn new() -> Result<Self, ShaperError> {
        let lognormal = LogNormal::new(LOGNORMAL_MU, LOGNORMAL_SIGMA)
            .map_err(|e| ShaperError::Distribution(e.to_string()))?;

        // Случайный старт timestamp (как в реальном WebRTC)
        let rtp_timestamp = rand::thread_rng().gen::<u32>();

        Ok(Self {
            frame_counter: 0,
            lognormal,
            rtp_timestamp,
            started_at: Instant::now(),
            idle_fps: 5,
            turbo_streak: 0,
        })
    }

    /// Report actual data size after batch build. Tracks turbo mode activation.
    pub fn report_data_size(&mut self, data_size: usize, target: usize) {
        if data_size > target {
            self.turbo_streak = self.turbo_streak.saturating_add(1);
        } else {
            self.turbo_streak = 0;
        }
    }

    /// Returns true when sustained high throughput detected — skip padding.
    pub fn is_turbo(&self) -> bool {
        self.turbo_streak >= TURBO_THRESHOLD
    }

    /// Генерирует целевые параметры следующего кадра.
    /// Вызывается каждые TICK_MICROS мкс.
    pub fn next_frame(&mut self) -> FrameTarget {
        let is_strict = self.started_at.elapsed().as_secs() < STRICT_PHASE_SECS;
        let is_i_frame = self.frame_counter == 0;

        let target_bytes = if self.is_turbo() {
            // Turbo mode: no padding, let data_size dominate.
            // build_batch_plaintext uses max(data_size, target), so target=0 means no pad.
            0
        } else if is_i_frame {
            // I-frame: равномерное в диапазоне [15KB, 50KB]
            let range = IFRAME_MAX - IFRAME_MIN;
            IFRAME_MIN + rand::thread_rng().gen::<usize>() % range
        } else if is_strict {
            // Строгий режим: LogNormal P-frame
            let raw = self.lognormal.sample(&mut rand::thread_rng());
            (raw as usize).clamp(PFRAME_MIN, PFRAME_MAX)
        } else {
            // Адаптивный режим: уменьшенный P-frame
            let raw = self.lognormal.sample(&mut rand::thread_rng()) * 0.4;
            (raw as usize).clamp(PFRAME_MIN, 2000)
        };

        let frame_type = if is_i_frame { FrameType::IFrame } else { FrameType::PFrame };
        let ts = self.rtp_timestamp;
        let idx = self.frame_counter;

        // Инкремент: +3000 на кадр (90000 Hz / 30 FPS = 3000)
        self.rtp_timestamp = self.rtp_timestamp.wrapping_add(90000 / FPS);
        self.frame_counter = (self.frame_counter + 1) % GOP_SIZE;

        FrameTarget {
            frame_type,
            target_bytes,
            timestamp: ts,
            frame_index: idx,
        }
    }

    /// Должен ли текущий тик пропустить отправку? (адаптивный режим)
    pub fn should_skip_tick(&self, tick: u64) -> bool {
        if self.started_at.elapsed().as_secs() < STRICT_PHASE_SECS {
            return false; // в строгом режиме никогда не пропускаем
        }
        // В покое отправляем 1 из N тиков (idle_fps / FPS)
        let n = FPS / self.idle_fps.max(1);
        tick % n as u64 != 0
    }
}

// ─── Tick duration ───────────────────────────────────────────────────────────

pub fn tick_duration() -> Duration {
    Duration::from_micros(TICK_MICROS)
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_iframe_at_gop_boundary() {
        let mut shaper = H264Shaper::new().unwrap();
        // Первый кадр GoP — всегда I-frame
        let f = shaper.next_frame();
        assert_eq!(f.frame_type, FrameType::IFrame);
        assert!(f.target_bytes >= IFRAME_MIN);
        assert!(f.target_bytes <= IFRAME_MAX);
        // Следующие — P-frames
        for _ in 1..GOP_SIZE {
            let f = shaper.next_frame();
            assert_eq!(f.frame_type, FrameType::PFrame);
        }
        // 61-й — снова I-frame
        let f = shaper.next_frame();
        assert_eq!(f.frame_type, FrameType::IFrame);
    }

    #[test]
    fn test_pframe_within_bounds() {
        let mut shaper = H264Shaper::new().unwrap();
        shaper.next_frame(); // skip I-frame
        for _ in 0..1000 {
            let f = shaper.next_frame();
            if f.frame_type == FrameType::IFrame {
                continue; // GoP boundary — skip I-frames
            }
            assert!(f.target_bytes >= PFRAME_MIN, "too small: {}", f.target_bytes);
            assert!(f.target_bytes <= PFRAME_MAX, "too large: {}", f.target_bytes);
        }
    }

    #[test]
    fn test_timestamp_increments() {
        let mut shaper = H264Shaper::new().unwrap();
        let f1 = shaper.next_frame();
        let f2 = shaper.next_frame();
        assert_eq!(f2.timestamp.wrapping_sub(f1.timestamp), 3000);
    }
}
