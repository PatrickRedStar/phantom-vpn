//! Tunnel lifecycle manager: thin adapter over `client_core_runtime::run()`.
//!
//! This module owns:
//!   * TUN device creation (via `super::tun`)
//!   * Linux-specific guards: `RouteGuard`, `Ipv6Guard`, `DnsGuard`
//!   * `Manager` public API (connect / disconnect / status) for the socket server
//!
//! The TLS pipeline, reconnect supervisor, telemetry, and log capture are
//! all handled by `client_core_runtime::run()`.

use std::os::unix::io::AsRawFd;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use anyhow::Context;
use tokio::sync::{watch, Mutex};

use client_common::helpers;
use client_core_runtime::{ConnectProfile, TunIo};
use ghoststream_gui_ipc::{ConnState, StatusFrame};

use super::dns::DnsGuard;
use super::ipv6::Ipv6Guard;
use super::tun;

pub struct Manager {
    inner: Mutex<Inner>,
    status_tx: watch::Sender<StatusFrame>,
    client_count: AtomicUsize,
}

struct Inner {
    /// JoinHandle for the runtime supervisor task.
    supervisor: Option<tokio::task::JoinHandle<anyhow::Result<()>>>,
    /// `RuntimeHandles.cancel` Notify — wired up on connect, used by disconnect.
    cancel: Option<Arc<tokio::sync::Notify>>,
    /// Live Linux guards for the current session. Dropped on disconnect.
    _tun_device: Option<tun::TunDevice>,
    _route_guard: Option<tun::RouteGuard>,
    _ipv6_guard: Option<Ipv6Guard>,
    _dns_guard: Option<DnsGuard>,
}

impl Manager {
    pub fn new(status_tx: watch::Sender<StatusFrame>) -> Self {
        Self {
            inner: Mutex::new(Inner {
                supervisor: None,
                cancel: None,
                _tun_device: None,
                _route_guard: None,
                _ipv6_guard: None,
                _dns_guard: None,
            }),
            status_tx,
            client_count: AtomicUsize::new(0),
        }
    }

    pub fn inc_clients(&self) { self.client_count.fetch_add(1, Ordering::Relaxed); }
    pub fn dec_clients(&self) { self.client_count.fetch_sub(1, Ordering::Relaxed); }
    pub fn client_count(&self) -> usize { self.client_count.load(Ordering::Relaxed) }
    pub fn is_connected(&self) -> bool { self.status_tx.borrow().state == ConnState::Connected }

    pub fn current_status(&self) -> StatusFrame {
        self.status_tx.borrow().clone()
    }

    pub async fn connect(&self, profile: ConnectProfile) -> anyhow::Result<()> {
        // Tear down any existing tunnel first.
        self.disconnect().await;

        self.publish(|f| {
            f.state = ConnState::Connecting;
            f.last_error = None;
            f.session_secs = 0;
            f.bytes_rx = 0;
            f.bytes_tx = 0;
            f.rate_rx_bps = 0.0;
            f.rate_tx_bps = 0.0;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
        });

        // Validate conn string early — fail fast before touching kernel state.
        let cfg = helpers::parse_conn_string(&profile.conn_string)
            .context("parse conn_string")?;

        let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
        let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
        let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

        // Create TUN device. Lives for the entire session (reused across reconnects).
        let tun_device = tun::create_tun(tun_name, tun_addr, tun_mtu)
            .context("create TUN device")?;
        let tun_fd = tun_device.file.as_raw_fd();

        // Resolve server address for route setup.
        let raw_addr = client_common::with_default_port(&cfg.network.server_addr, 443);
        let server_addr: std::net::SocketAddr = if let Ok(a) = raw_addr.parse() {
            a
        } else {
            tokio::net::lookup_host(&raw_addr).await
                .context("DNS lookup")?
                .next()
                .ok_or_else(|| anyhow::anyhow!("no DNS results for {}", raw_addr))?
        };

        let settings = profile.settings.clone();

        // Policy routing — reverted on drop.
        let route_guard = if cfg.network.default_gw.is_some() {
            match tun::add_default_route(tun_name, &server_addr) {
                Ok(g) => Some(g),
                Err(e) => { tracing::warn!(target: "helper", "route setup: {}", e); None }
            }
        } else { None };

        // IPv6 kill switch.
        let ipv6_guard = if settings.ipv6_killswitch {
            match Ipv6Guard::activate() {
                Ok(g) => Some(g),
                Err(e) => { tracing::warn!(target: "helper", "ipv6 guard: {:#}", e); None }
            }
        } else { None };

        // DNS leak protection.
        let dns_guard = if settings.dns_leak_protection {
            let dns_ip = cfg.network.default_gw.as_deref()
                .and_then(|s| s.parse::<std::net::IpAddr>().ok())
                .or_else(|| {
                    cfg.network.tun_addr.as_deref()
                        .and_then(|s| s.split('/').next())
                        .and_then(|ip| ip.parse::<std::net::Ipv4Addr>().ok())
                        .map(|v4| {
                            let o = v4.octets();
                            std::net::IpAddr::V4(std::net::Ipv4Addr::new(o[0], o[1], o[2], 1))
                        })
                });
            match dns_ip {
                Some(ip) => match DnsGuard::activate(tun_name, &[ip], &[]) {
                    Ok(g) => Some(g),
                    Err(e) => { tracing::warn!(target: "helper", "dns guard: {:#}", e); None }
                },
                None => {
                    tracing::warn!(target: "helper",
                        "could not infer DNS server — leak protection skipped");
                    None
                }
            }
        } else { None };

        // Delegate the entire TLS pipeline + reconnect supervisor to
        // client_core_runtime. The TUN fd is reused across reconnect attempts.
        let (log_tx, _log_rx) = tokio::sync::mpsc::channel(1);
        let (handles, join_handle) = client_core_runtime::run(
            profile,
            TunIo::Uring(tun_fd),
            self.status_tx.clone(),
            log_tx,
        ).await.context("client_core_runtime::run")?;

        let mut g = self.inner.lock().await;
        g.supervisor = Some(join_handle);
        g.cancel = Some(handles.cancel);
        g._tun_device = Some(tun_device);
        g._route_guard = route_guard;
        g._ipv6_guard = ipv6_guard;
        g._dns_guard = dns_guard;
        Ok(())
    }

    pub async fn disconnect(&self) {
        let (handle, cancel) = {
            let mut g = self.inner.lock().await;
            let handle = g.supervisor.take();
            let cancel = g.cancel.take();
            // Drop guards in teardown order: dns → ipv6 → route → tun.
            drop(g._dns_guard.take());
            drop(g._ipv6_guard.take());
            drop(g._route_guard.take());
            drop(g._tun_device.take());
            (handle, cancel)
        };

        // Wake any pending backoff sleep in the supervisor.
        if let Some(c) = cancel {
            c.notify_waiters();
        }

        if let Some(h) = handle {
            let grace = tokio::time::timeout(
                std::time::Duration::from_secs(3),
                h,
            ).await;
            if grace.is_err() {
                tracing::warn!(target: "helper", "teardown timeout — task still running, leaking");
            }
        }

        self.publish(|f| {
            f.state = ConnState::Disconnected;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.session_secs = 0;
            f.rate_rx_bps = 0.0;
            f.rate_tx_bps = 0.0;
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
        });
    }

    fn publish(&self, mut f: impl FnMut(&mut StatusFrame)) {
        let mut cur = self.status_tx.borrow().clone();
        f(&mut cur);
        let _ = self.status_tx.send(cur);
    }
}
