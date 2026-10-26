//! Transport policy — единый набор anti-DPI рычагов, пушится сервером клиенту.
//!
//! См. ADR 0014. Философия:
//! - `TransportPolicy` — сериализуемый wire-тип (все поля `Option` + `#[serde(default)]`),
//!   именно он едет в `ClientConfigResponse.transport_policy` и лежит в `server.toml [policy]`.
//! - `ResolvedTransportPolicy` — конкретные значения, которыми пользуется рантайм; строится
//!   мержем policy поверх `Default` (= текущие компайл-тайм `const`).
//! - Глобал `install()/current()` даёт рантайму доступ без прокидывания через все слои.
//!
//! BACKWARD-COMPAT: без установленной policy `current()` возвращает дефолты — встроенные
//! константы (wire.rs / h2_transport.rs). Старые клиенты игнорируют незнакомые поля
//! (serde), новые клиенты на старом сервере получают `None` → дефолты.
//!
//! Статус доставки (см. ADR 0014): сервер policy клиентам не шлёт; в проде всегда
//! действуют дефолты, `install()` вызывается только лабораторным харнессом.

use serde::{Deserialize, Serialize};
use std::sync::{Arc, RwLock};

use crate::wire::{
    HEARTBEAT_INTERVAL_MAX_SECS, HEARTBEAT_INTERVAL_MIN_SECS, HEARTBEAT_PKT_MAX,
    HEARTBEAT_PKT_MIN, HEARTBEAT_START_JITTER_MAX_SECS, HEARTBEAT_START_JITTER_MIN_SECS,
    QUIC_TUNNEL_MSS, QUIC_TUNNEL_MTU,
};

/// Текущая версия схемы policy. Клиент применяет поля, которые понимает; при major-
/// несовпадении откатывается на дефолты.
pub const POLICY_SCHEMA_VERSION: u32 = 1;

// ─── Wire-тип (сериализуется, пушится, лежит в toml) ──────────────────────────

/// Anti-DPI рычаги, доставляемые с сервера. Все поля опциональны — отсутствие любого
/// означает «использовать встроенный дефолт» (текущее поведение).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TransportPolicy {
    /// Версия схемы (для gating несовместимых изменений).
    #[serde(default)]
    pub schema_version: Option<u32>,
    #[serde(default)]
    pub fingerprint: Option<FingerprintPolicy>,
    /// ALPN список (напр. ["h2","http/1.1"]).
    #[serde(default)]
    pub alpn: Option<Vec<String>>,
    /// Минимальная версия TLS ("1.2" | "1.3").
    #[serde(default)]
    pub tls_min: Option<String>,
    /// Максимальная версия TLS ("1.2" | "1.3").
    #[serde(default)]
    pub tls_max: Option<String>,
    #[serde(default)]
    pub streams: Option<StreamPolicy>,
    #[serde(default)]
    pub mtu: Option<usize>,
    #[serde(default)]
    pub mss: Option<u16>,
    #[serde(default)]
    pub padding: Option<PaddingPolicy>,
    #[serde(default)]
    pub heartbeat: Option<HeartbeatPolicy>,
    #[serde(default)]
    pub mimicry: Option<MimicryPolicy>,
    #[serde(default)]
    pub recycle: Option<RecyclePolicy>,
    /// Серверная/relay сторона (см. Phase 4).
    #[serde(default)]
    pub relay: Option<RelayPolicy>,
    /// Presentировать ли клиентский сертификат в TLS-хендшейке (mTLS). `false` =
    /// не слать серт (auth должен уходить внутрь потока, как VLESS). Гипотеза: mTLS
    /// client-cert flight — детект-признак proxy. Дефолт = true (текущее поведение).
    #[serde(default)]
    pub mtls: Option<bool>,
}

/// Fingerprint ClientHello. Вариант b: `raw` несёт шаблон, вводимый без релиза клиента.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FingerprintPolicy {
    /// Стоковый rustls hello (текущее поведение).
    Default,
    /// Именованный профиль, вкомпилированный в клиент (`firefox`, `okhttp`, ...).
    Named { profile: String },
    /// Сырой шаблон ClientHello (base64) — динамический путь, uTLS-подобный движок.
    Raw { client_hello_b64: String },
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StreamPolicy {
    /// Топология: N параллельных TCP+TLS (как сейчас) или N логических стримов в одном mux-коннекте.
    #[serde(default)]
    pub topology: Option<Topology>,
    /// Явное число стримов; `None` = авто (по числу ядер).
    #[serde(default)]
    pub count: Option<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Topology {
    /// N отдельных TCP+TLS-коннектов к одному хосту (v0.27.x).
    ParallelPerStream,
    /// N логических стримов внутри ОДНОГО TLS-коннекта (Phase 3).
    SingleConnMux,
}

impl Default for Topology {
    fn default() -> Self {
        Topology::ParallelPerStream
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PaddingPolicy {
    /// Включить data-path padding (#3 shaping). По умолчанию выкл.
    #[serde(default)]
    pub enabled: Option<bool>,
    /// Целевой размер кадра в байтах (`target_size` в `build_batch_plaintext`).
    #[serde(default)]
    pub target: Option<usize>,
    /// Минимальный размер кадра (padding до него, если данных меньше).
    #[serde(default)]
    pub min_frame: Option<usize>,
    /// Пейсинг между кадрами в мс (0 = без пейсинга).
    #[serde(default)]
    pub pace_ms: Option<u32>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HeartbeatPolicy {
    #[serde(default)]
    pub interval_min_secs: Option<u64>,
    #[serde(default)]
    pub interval_max_secs: Option<u64>,
    #[serde(default)]
    pub start_jitter_min_secs: Option<u64>,
    #[serde(default)]
    pub start_jitter_max_secs: Option<u64>,
    #[serde(default)]
    pub pkt_min: Option<usize>,
    #[serde(default)]
    pub pkt_max: Option<usize>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MimicryPolicy {
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub warmup_bytes: Option<usize>,
    #[serde(default)]
    pub warmup_secs: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RecyclePolicy {
    /// Пересоздать сессию, когда суммарный трафик перейдёт порог (обход freeze-по-объёму).
    #[serde(default)]
    pub bytes: Option<u64>,
    /// Пересоздать сессию по времени (fallback; обычно не нужно, см. TunnelSettings).
    #[serde(default)]
    pub secs: Option<u32>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RelayPolicy {
    #[serde(default)]
    pub mode: Option<RelayMode>,
    /// SNI, который relay ожидает/предъявляет (для terminate-режима — собственный RU-домен).
    #[serde(default)]
    pub sni: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelayMode {
    /// raw copy_bidirectional, TLS end-to-end client↔exit (v0.27.x).
    Passthrough,
    /// relay терминирует TLS на своём домене и реоригинирует relay→exit (Phase 4).
    TerminateReoriginate,
}

impl Default for RelayMode {
    fn default() -> Self {
        RelayMode::Passthrough
    }
}

// ─── Resolved (конкретные значения для рантайма) ──────────────────────────────

/// Fingerprint, готовый к применению движком (Phase 2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedFingerprint {
    /// Стоковый rustls hello (текущее).
    Default,
    Named(String),
    Raw(Vec<u8>),
}

#[derive(Debug, Clone)]
pub struct ResolvedHeartbeat {
    pub interval_min_secs: u64,
    pub interval_max_secs: u64,
    pub start_jitter_min_secs: u64,
    pub start_jitter_max_secs: u64,
    pub pkt_min: usize,
    pub pkt_max: usize,
}

#[derive(Debug, Clone)]
pub struct ResolvedPadding {
    pub enabled: bool,
    pub target: usize,
    pub min_frame: usize,
    pub pace_ms: u32,
}

/// Полностью разрешённая policy — то, чем пользуется рантайм. Все поля конкретны.
#[derive(Debug, Clone)]
pub struct ResolvedTransportPolicy {
    pub fingerprint: ResolvedFingerprint,
    pub alpn: Vec<String>,
    pub tls_min: Option<String>,
    pub tls_max: Option<String>,
    pub topology: Topology,
    /// Явный override числа стримов; `None` = авто (по ядрам).
    pub streams: Option<usize>,
    pub mtu: usize,
    pub mss: u16,
    pub padding: ResolvedPadding,
    pub heartbeat: ResolvedHeartbeat,
    pub relay_mode: RelayMode,
    pub relay_sni: Option<String>,
    /// Present client cert in TLS handshake (mTLS). Default true.
    pub mtls: bool,
}

impl Default for ResolvedTransportPolicy {
    /// Дефолты = встроенные константы (см. wire.rs / h2_transport.rs).
    fn default() -> Self {
        Self {
            fingerprint: ResolvedFingerprint::Default,
            alpn: vec!["h2".to_string(), "http/1.1".to_string()],
            tls_min: None,
            tls_max: None,
            topology: Topology::ParallelPerStream,
            streams: None,
            mtu: QUIC_TUNNEL_MTU,
            mss: QUIC_TUNNEL_MSS,
            padding: ResolvedPadding {
                enabled: false,
                target: 0,
                min_frame: 0,
                pace_ms: 0,
            },
            heartbeat: ResolvedHeartbeat {
                interval_min_secs: HEARTBEAT_INTERVAL_MIN_SECS,
                interval_max_secs: HEARTBEAT_INTERVAL_MAX_SECS,
                start_jitter_min_secs: HEARTBEAT_START_JITTER_MIN_SECS,
                start_jitter_max_secs: HEARTBEAT_START_JITTER_MAX_SECS,
                pkt_min: HEARTBEAT_PKT_MIN,
                pkt_max: HEARTBEAT_PKT_MAX,
            },
            relay_mode: RelayMode::Passthrough,
            relay_sni: None,
            mtls: true,
        }
    }
}

impl ResolvedTransportPolicy {
    /// Мерж wire-policy поверх дефолтов. Неизвестные/`None` поля оставляют дефолт.
    pub fn from_policy(p: &TransportPolicy) -> Self {
        let mut r = Self::default();

        if let Some(fp) = &p.fingerprint {
            r.fingerprint = match fp {
                FingerprintPolicy::Default => ResolvedFingerprint::Default,
                FingerprintPolicy::Named { profile } => ResolvedFingerprint::Named(profile.clone()),
                FingerprintPolicy::Raw { client_hello_b64 } => {
                    use base64::Engine;
                    match base64::engine::general_purpose::STANDARD.decode(client_hello_b64) {
                        Ok(bytes) => ResolvedFingerprint::Raw(bytes),
                        // Битый шаблон не должен ронять коннект — откат на дефолт.
                        Err(_) => ResolvedFingerprint::Default,
                    }
                }
            };
        }
        if let Some(alpn) = &p.alpn {
            if !alpn.is_empty() {
                r.alpn = alpn.clone();
            }
        }
        if p.tls_min.is_some() {
            r.tls_min = p.tls_min.clone();
        }
        if p.tls_max.is_some() {
            r.tls_max = p.tls_max.clone();
        }
        if let Some(s) = &p.streams {
            if let Some(t) = s.topology {
                r.topology = t;
            }
            if s.count.is_some() {
                r.streams = s.count;
            }
        }
        if let Some(mtu) = p.mtu {
            r.mtu = mtu;
        }
        if let Some(mss) = p.mss {
            r.mss = mss;
        }
        if let Some(pad) = &p.padding {
            if let Some(e) = pad.enabled {
                r.padding.enabled = e;
            }
            if let Some(t) = pad.target {
                r.padding.target = t;
            }
            if let Some(m) = pad.min_frame {
                r.padding.min_frame = m;
            }
            if let Some(p) = pad.pace_ms {
                r.padding.pace_ms = p;
            }
        }
        if let Some(hb) = &p.heartbeat {
            if let Some(v) = hb.interval_min_secs {
                r.heartbeat.interval_min_secs = v;
            }
            if let Some(v) = hb.interval_max_secs {
                r.heartbeat.interval_max_secs = v;
            }
            if let Some(v) = hb.start_jitter_min_secs {
                r.heartbeat.start_jitter_min_secs = v;
            }
            if let Some(v) = hb.start_jitter_max_secs {
                r.heartbeat.start_jitter_max_secs = v;
            }
            if let Some(v) = hb.pkt_min {
                r.heartbeat.pkt_min = v;
            }
            if let Some(v) = hb.pkt_max {
                r.heartbeat.pkt_max = v;
            }
        }
        if let Some(rel) = &p.relay {
            if let Some(m) = rel.mode {
                r.relay_mode = m;
            }
            if rel.sni.is_some() {
                r.relay_sni = rel.sni.clone();
            }
        }
        if let Some(m) = p.mtls {
            r.mtls = m;
        }
        // Санитизация инвариантов (защита от кривого server-конфига): heartbeat
        // не реже HEARTBEAT_INTERVAL_MAX_SECS — иначе живой стрим упрётся в
        // детектор мёртвого (90 с); заглушка — от 20 байт (нужен байт-сентинел)
        // и до 1200, чтобы кадр не выглядел аномально и не ломал u16-длину.
        let hb = &mut r.heartbeat;
        hb.interval_min_secs = hb.interval_min_secs.clamp(1, HEARTBEAT_INTERVAL_MAX_SECS);
        hb.interval_max_secs = hb
            .interval_max_secs
            .clamp(hb.interval_min_secs, HEARTBEAT_INTERVAL_MAX_SECS);
        hb.start_jitter_min_secs = hb.start_jitter_min_secs.min(HEARTBEAT_INTERVAL_MAX_SECS);
        hb.start_jitter_max_secs = hb
            .start_jitter_max_secs
            .clamp(hb.start_jitter_min_secs, HEARTBEAT_INTERVAL_MAX_SECS);
        hb.pkt_min = hb.pkt_min.clamp(20, 1200);
        hb.pkt_max = hb.pkt_max.clamp(hb.pkt_min, 1200);
        r
    }
}

// ─── Глобал ───────────────────────────────────────────────────────────────────

fn slot() -> &'static RwLock<Arc<ResolvedTransportPolicy>> {
    use std::sync::OnceLock;
    static SLOT: OnceLock<RwLock<Arc<ResolvedTransportPolicy>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(Arc::new(ResolvedTransportPolicy::default())))
}

/// Установить активную policy (обычно на (ре)коннекте, из client-config или server.toml).
pub fn install(resolved: ResolvedTransportPolicy) {
    if let Ok(mut w) = slot().write() {
        *w = Arc::new(resolved);
    }
}

/// Установить из wire-policy (удобный шорткат).
pub fn install_policy(p: &TransportPolicy) {
    install(ResolvedTransportPolicy::from_policy(p));
}

/// Сбросить на дефолты (= текущее поведение).
pub fn reset() {
    install(ResolvedTransportPolicy::default());
}

/// Текущая активная resolved-policy. Без `install()` — дефолты.
pub fn current() -> Arc<ResolvedTransportPolicy> {
    slot()
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| Arc::new(ResolvedTransportPolicy::default()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_matches_legacy_consts() {
        let d = ResolvedTransportPolicy::default();
        assert_eq!(d.mtu, QUIC_TUNNEL_MTU);
        assert_eq!(d.mss, QUIC_TUNNEL_MSS);
        assert_eq!(d.alpn, vec!["h2".to_string(), "http/1.1".to_string()]);
        assert!(d.streams.is_none());
        assert_eq!(d.topology, Topology::ParallelPerStream);
        assert!(!d.padding.enabled);
        assert_eq!(d.heartbeat.interval_min_secs, HEARTBEAT_INTERVAL_MIN_SECS);
        assert!(matches!(d.fingerprint, ResolvedFingerprint::Default));
        assert_eq!(d.relay_mode, RelayMode::Passthrough);
    }

    #[test]
    fn empty_policy_resolves_to_default() {
        let p = TransportPolicy::default();
        let r = ResolvedTransportPolicy::from_policy(&p);
        assert_eq!(r.mtu, QUIC_TUNNEL_MTU);
        assert!(r.streams.is_none());
        assert!(matches!(r.fingerprint, ResolvedFingerprint::Default));
    }

    #[test]
    fn partial_policy_overrides_only_given_fields() {
        let p = TransportPolicy {
            streams: Some(StreamPolicy {
                topology: Some(Topology::SingleConnMux),
                count: Some(4),
            }),
            padding: Some(PaddingPolicy {
                enabled: Some(true),
                target: Some(1200),
                ..Default::default()
            }),
            fingerprint: Some(FingerprintPolicy::Named {
                profile: "firefox".into(),
            }),
            ..Default::default()
        };
        let r = ResolvedTransportPolicy::from_policy(&p);
        assert_eq!(r.topology, Topology::SingleConnMux);
        assert_eq!(r.streams, Some(4));
        assert!(r.padding.enabled);
        assert_eq!(r.padding.target, 1200);
        assert_eq!(r.fingerprint, ResolvedFingerprint::Named("firefox".into()));
        // Незаданное осталось дефолтом.
        assert_eq!(r.mtu, QUIC_TUNNEL_MTU);
        assert_eq!(r.heartbeat.interval_max_secs, HEARTBEAT_INTERVAL_MAX_SECS);
    }

    #[test]
    fn heartbeat_bounds_are_sanitized() {
        let p = TransportPolicy {
            heartbeat: Some(HeartbeatPolicy {
                interval_min_secs: Some(60),
                interval_max_secs: Some(10), // max < min — должно поправиться
                ..Default::default()
            }),
            ..Default::default()
        };
        let r = ResolvedTransportPolicy::from_policy(&p);
        assert!(r.heartbeat.interval_max_secs >= r.heartbeat.interval_min_secs);

        // Values that used to panic the TX task (empty/oversized dummy packet,
        // zero interval) or outlive the dead-stream detector are clamped.
        let p = TransportPolicy {
            heartbeat: Some(HeartbeatPolicy {
                interval_min_secs: Some(0),
                interval_max_secs: Some(600),
                start_jitter_min_secs: Some(500),
                start_jitter_max_secs: Some(1),
                pkt_min: Some(0),
                pkt_max: Some(100_000),
            }),
            ..Default::default()
        };
        let hb = ResolvedTransportPolicy::from_policy(&p).heartbeat;
        assert_eq!(hb.interval_min_secs, 1);
        assert_eq!(hb.interval_max_secs, HEARTBEAT_INTERVAL_MAX_SECS);
        assert!(hb.start_jitter_min_secs <= hb.start_jitter_max_secs);
        assert!(hb.start_jitter_max_secs <= HEARTBEAT_INTERVAL_MAX_SECS);
        assert_eq!((hb.pkt_min, hb.pkt_max), (20, 1200));
    }

    #[test]
    fn bad_raw_fingerprint_falls_back_to_default() {
        let p = TransportPolicy {
            fingerprint: Some(FingerprintPolicy::Raw {
                client_hello_b64: "!!!not-base64!!!".into(),
            }),
            ..Default::default()
        };
        let r = ResolvedTransportPolicy::from_policy(&p);
        assert!(matches!(r.fingerprint, ResolvedFingerprint::Default));
    }

    #[test]
    fn install_and_current_roundtrip() {
        reset();
        assert!(current().streams.is_none());
        install_policy(&TransportPolicy {
            streams: Some(StreamPolicy {
                topology: None,
                count: Some(6),
            }),
            ..Default::default()
        });
        assert_eq!(current().streams, Some(6));
        reset();
        assert!(current().streams.is_none());
    }
}
