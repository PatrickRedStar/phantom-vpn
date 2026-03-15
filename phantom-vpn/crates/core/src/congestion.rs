//! "Unlimited" congestion controller for QUIC.
//!
//! Always reports a huge congestion window, never reduces on loss.
//! Designed for VPN tunnels where inner TCP handles its own congestion control.
//! WARNING: Do not use on shared/public networks — will not back off on congestion.

use std::any::Any;
use std::sync::Arc;
use std::time::Instant;

use quinn::congestion::{Controller, ControllerFactory};
use quinn_proto::RttEstimator;

/// Congestion window: 128 MB. Effectively unlimited for any realistic link.
const WINDOW: u64 = 128 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Unlimited {
    window: u64,
}

impl Controller for Unlimited {
    fn on_sent(&mut self, _now: Instant, _bytes: u64, _last_packet_number: u64) {}

    fn on_ack(
        &mut self,
        _now: Instant,
        _sent: Instant,
        _bytes: u64,
        _app_limited: bool,
        _rtt: &RttEstimator,
    ) {}

    fn on_congestion_event(
        &mut self,
        _now: Instant,
        _sent: Instant,
        _is_persistent_congestion: bool,
        _lost_bytes: u64,
    ) {
        // Intentionally do nothing. Inner TCP manages congestion.
    }

    fn on_mtu_update(&mut self, _new_mtu: u16) {}

    fn window(&self) -> u64 {
        self.window
    }

    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }

    fn initial_window(&self) -> u64 {
        self.window
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}

#[derive(Debug, Clone)]
pub struct UnlimitedConfig;

impl ControllerFactory for UnlimitedConfig {
    fn build(self: Arc<Self>, _now: Instant, _current_mtu: u16) -> Box<dyn Controller> {
        Box::new(Unlimited { window: WINDOW })
    }
}
