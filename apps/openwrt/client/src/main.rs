//! phantom-client-openwrt: minimal VPN daemon for OpenWrt routers.
//!
//! Key differences from client-linux:
//! - No clap — manual arg parsing (--conn-string, --tun-name, --mtu)
//! - Uses tun_simple instead of tun_uring (no io_uring on OpenWrt kernels)
//! - current_thread tokio runtime (saves RAM on routers)
//! - IP addr/routes managed by netifd; we only bring up the interface
//! - Each stream reconnects by itself with backoff (≤30 s + jitter), forever
//! - Emits JSON to stdout on startup: {"tun_name":"gs0","tun_addr":"...","gateway":"..."}

#[cfg(target_os = "linux")]
mod linux {
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::os::unix::io::AsRawFd;
    use std::process::Command;
    use std::sync::Arc;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use anyhow::Context;
    use bytes::Bytes;
    use client_common::helpers::parse_conn_string;
    use client_common::{tls_connect, tls_rx_loop, tls_tx_loop, with_default_port, write_handshake};
    use phantom_core::wire::{flow_stream_idx, n_data_streams};
    use tokio::signal;
    use tokio::sync::{mpsc, watch};

    // MIPS uses different ioctl encoding: _IOC_WRITE=4, _IOC_DIRSHIFT=29
    // vs generic _IOC_WRITE=1, _IOC_DIRSHIFT=30 (mipsel is target_arch "mips")
    #[cfg(target_arch = "mips")]
    const TUNSETIFF: libc::c_ulong = 0x800454CA;
    #[cfg(not(target_arch = "mips"))]
    const TUNSETIFF: libc::c_ulong = 0x400454CA;

    /// No frame at all (data or heartbeat) for this long → the stream is dead.
    /// Same as client-core-runtime: server heartbeats come at most 60 s apart.
    const RX_IDLE_TIMEOUT: Duration = Duration::from_secs(90);
    /// A stream that stayed up this long starts its backoff from scratch.
    const STABLE_AFTER: Duration = Duration::from_secs(30);
    const IFF_TUN: libc::c_short = 0x0001;
    const IFF_NO_PI: libc::c_short = 0x1000;

    #[repr(C)]
    struct Ifreq {
        ifr_name:  [libc::c_char; libc::IFNAMSIZ],
        ifr_flags: libc::c_short,
        _pad:      [u8; 22],
    }

    // ─── CLI arg parsing ──────────────────────────────────────────────────────

    struct Opts {
        conn_string: String,
        tun_name:    String,
        mtu:         u32,
        verbose:     bool,
    }

    fn parse_args() -> anyhow::Result<Opts> {
        let args: Vec<String> = std::env::args().collect();
        let mut conn_string = None::<String>;
        let mut tun_name    = "gs0".to_string();
        let mut mtu         = 1350u32;
        let mut verbose     = false;

        let mut i = 1usize;
        while i < args.len() {
            match args[i].as_str() {
                "--conn-string" => {
                    i += 1;
                    conn_string = Some(
                        args.get(i)
                            .cloned()
                            .ok_or_else(|| anyhow::anyhow!("--conn-string requires a value"))?,
                    );
                }
                "--conn-string-file" => {
                    i += 1;
                    let path = args
                        .get(i)
                        .ok_or_else(|| anyhow::anyhow!("--conn-string-file requires a value"))?;
                    conn_string = Some(
                        std::fs::read_to_string(path)
                            .with_context(|| format!("Failed to read {}", path))?,
                    );
                }
                "--tun-name" => {
                    i += 1;
                    tun_name = args
                        .get(i)
                        .cloned()
                        .ok_or_else(|| anyhow::anyhow!("--tun-name requires a value"))?;
                }
                "--mtu" => {
                    i += 1;
                    let val = args
                        .get(i)
                        .ok_or_else(|| anyhow::anyhow!("--mtu requires a value"))?;
                    mtu = val.parse().context("--mtu must be a number")?;
                }
                "-v" | "--verbose" => verbose = true,
                "--help" | "-h" => {
                    eprintln!(
                        "Usage: ghoststream --conn-string <base64url> [--tun-name gs0] [--mtu 1350] [-v]"
                    );
                    std::process::exit(0);
                }
                other => {
                    anyhow::bail!("Unknown argument: {}", other);
                }
            }
            i += 1;
        }

        Ok(Opts {
            conn_string: conn_string
                .ok_or_else(|| anyhow::anyhow!("--conn-string is required"))?,
            tun_name,
            mtu,
            verbose,
        })
    }

    // ─── TUN creation ─────────────────────────────────────────────────────────

    /// Create a TUN interface. Only brings it up with the given MTU;
    /// IP address assignment is left to netifd (OpenWrt network daemon).
    fn create_tun(name: &str, mtu: u32) -> anyhow::Result<File> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/net/tun")
            .context("Failed to open /dev/net/tun — is the tun module loaded?")?;

        let mut req = Ifreq {
            ifr_name:  [0; libc::IFNAMSIZ],
            ifr_flags: IFF_TUN | IFF_NO_PI,
            _pad:      [0; 22],
        };
        let name_bytes = name.as_bytes();
        let copy_len = name_bytes.len().min(libc::IFNAMSIZ - 1);
        for (i, &b) in name_bytes[..copy_len].iter().enumerate() {
            req.ifr_name[i] = b as libc::c_char;
        }

        #[allow(clippy::unnecessary_cast)]
        let ret =
            unsafe { libc::ioctl(file.as_raw_fd(), TUNSETIFF as _, &req as *const _) };
        if ret < 0 {
            anyhow::bail!(
                "TUNSETIFF ioctl failed: {} (run as root?)",
                io::Error::last_os_error()
            );
        }

        // Non-blocking — required by tun_simple
        unsafe {
            let flags = libc::fcntl(file.as_raw_fd(), libc::F_GETFL, 0);
            libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        // Only set MTU and bring up — netifd handles the IP address
        run_cmd("ip", &["link", "set", name, "mtu", &mtu.to_string(), "up"])?;
        tracing::info!("TUN {} up: mtu={}", name, mtu);

        Ok(file)
    }

    fn run_cmd(prog: &str, args: &[&str]) -> anyhow::Result<()> {
        let status = Command::new(prog)
            .args(args)
            .status()
            .with_context(|| format!("Failed to exec: {} {}", prog, args.join(" ")))?;
        if !status.success() {
            anyhow::bail!("{} {} exited with {}", prog, args.join(" "), status);
        }
        Ok(())
    }

    async fn wait_for_shutdown(rx: &mut watch::Receiver<bool>) {
        if *rx.borrow() {
            return;
        }
        let _ = rx.changed().await;
    }

    /// Pause before reconnecting a stream: 1, 2, 5, 10, 20, then 30 s forever,
    /// plus up to 25 % jitter so streams (and routers) dropped by one event
    /// don't come back in lockstep. Same table as client-core-runtime.
    fn reconnect_delay(fails: usize) -> Duration {
        const BACKOFF_SECS: [u64; 6] = [1, 2, 5, 10, 20, 30];
        let base_ms = BACKOFF_SECS[fails.min(BACKOFF_SECS.len() - 1)] * 1000;
        let noise = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().subsec_nanos();
        Duration::from_millis(base_ms + u64::from(noise) % (base_ms / 4 + 1))
    }

    /// One TLS stream for the life of the process: connect, run until the
    /// server closes it (FIN), it fails or goes silent, pause, connect again —
    /// never giving up. Only this stream reconnects; the others keep running,
    /// and its uplink queue survives the gap.
    async fn run_stream(
        idx: usize,
        n_streams: usize,
        server: String,
        server_name: String,
        client_config: Arc<rustls::ClientConfig>,
        mut uplink: mpsc::Receiver<Bytes>,
        tun_tx: mpsc::Sender<Bytes>,
    ) {
        // Streams open one after another, not in one burst.
        tokio::time::sleep(Duration::from_millis(idx as u64 * 100)).await;
        let mut fails = 0;
        loop {
            let started = Instant::now();
            let session = async {
                let addr = tokio::net::lookup_host(&server)
                    .await
                    .context("DNS lookup failed")?
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", server))?;
                let (r, mut w) = tls_connect(addr, server_name.clone(), client_config.clone()).await?;
                write_handshake(&mut w, idx as u8, n_streams as u8).await?;
                tracing::info!("Stream {}: connected to {}", idx, addr);
                tokio::select! {
                    res = tls_tx_loop(w, &mut uplink) => res.context("tx"),
                    res = tls_rx_loop(r, tun_tx.clone(), Some(RX_IDLE_TIMEOUT)) => res.context("rx"),
                }
            };
            let err = match session.await {
                Ok(()) => anyhow::anyhow!("closed"),
                Err(e) => e,
            };
            if started.elapsed() >= STABLE_AFTER {
                fails = 0;
            }
            let delay = reconnect_delay(fails);
            fails += 1;
            tracing::warn!("Stream {}: {:#}; reconnecting in {:.1?}", idx, err, delay);
            tokio::time::sleep(delay).await;
        }
    }

    // ─── Main ─────────────────────────────────────────────────────────────────

    /// Handle `ghoststream --print-tun-addr <conn-string>` — emit "10.7.0.x/24" to stdout.
    /// Used by openwrt/proto/ghoststream.sh netifd protocol handler.
    fn maybe_print_tun_addr_and_exit() {
        let args: Vec<String> = std::env::args().collect();
        if args.len() == 3 && args[1] == "--print-tun-addr" {
            match parse_conn_string(&args[2]) {
                Ok(cfg) => {
                    let tun = cfg.network.tun_addr.unwrap_or_else(|| "10.7.0.2/24".into());
                    println!("{}", tun);
                    std::process::exit(0);
                }
                Err(e) => {
                    eprintln!("print-tun-addr: {}", e);
                    std::process::exit(1);
                }
            }
        }
    }

    pub fn async_main() -> anyhow::Result<()> {
        maybe_print_tun_addr_and_exit();

        // Ring crypto provider must be installed before any TLS usage
        rustls::crypto::ring::default_provider()
            .install_default()
            .expect("Failed to install ring crypto provider");

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to build tokio runtime");

        let local = tokio::task::LocalSet::new();
        rt.block_on(local.run_until(inner_main()))
    }

    async fn inner_main() -> anyhow::Result<()> {
        let opts = parse_args()?;

        // Logging
        let level = if opts.verbose {
            tracing::Level::DEBUG
        } else {
            tracing::Level::INFO
        };
        tracing_subscriber::fmt()
            .with_max_level(level)
            .with_target(false)
            .compact()
            .init();

        tracing::info!("GhostStream OpenWrt client starting...");

        // Signal handling
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        tokio::task::spawn_local(async move {
            let mut sigint =
                signal::unix::signal(signal::unix::SignalKind::interrupt()).unwrap();
            let mut sigterm =
                signal::unix::signal(signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = sigint.recv()  => tracing::info!("SIGINT received, shutting down..."),
                _ = sigterm.recv() => tracing::info!("SIGTERM received, shutting down..."),
            }
            let _ = shutdown_tx.send(true);
        });

        // Parse connection string
        let cfg = parse_conn_string(&opts.conn_string)
            .context("Failed to parse --conn-string")?;

        // Resolved on every connect: at boot the WAN may not be up yet.
        let server = with_default_port(&cfg.network.server_addr, 443);
        tracing::info!("Server address: {}", server);

        let tun_addr = cfg.network.tun_addr.clone().unwrap_or_else(|| "10.7.0.2/24".to_string());
        let gateway  = cfg.network.default_gw.clone().unwrap_or_else(|| "10.7.0.1".to_string());

        // Emit startup JSON for netifd / init scripts
        println!(
            "{}",
            serde_json::json!({
                "tun_name": opts.tun_name,
                "tun_addr": tun_addr,
                "gateway":  gateway,
            })
        );

        // Load TLS identity
        let client_identity =
            client_common::helpers::load_tls_identity(&cfg)?;

        // Server TLS cert is signed by Let's Encrypt (via nginx SNI passthrough),
        // not by the PhantomVPN CA in the conn string (that CA is for client mTLS
        // only). The webpki public root store verifies the LE server cert against
        // `server_name`; no extra server_ca needed. v0.27.0: server verification
        // is always on — the old skip_verify was a MITM hole (ADR 0011).
        let server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>> = None;

        // Build TLS client config
        let client_config =
            phantom_core::h2_transport::make_h2_client_tls(server_ca, client_identity)
                .context("Failed to build TLS client config")?;

        let n_streams   = n_data_streams();
        let server_name = cfg.network.server_name.as_deref().unwrap_or("phantom").to_string();

        // Create TUN interface (netifd configures the IP address). It comes up
        // before the streams: netifd waits for it, and the streams connect —
        // and reconnect — behind it for as long as the process lives.
        let tun_file = create_tun(&opts.tun_name, opts.mtu)?;
        let tun_fd   = tun_file.as_raw_fd();
        std::mem::forget(tun_file); // keep fd open; owned by tun_simple threads

        // tun_simple: blocking threads, same channel API as tun_uring
        let (mut tun_pkt_rx, tun_pkt_tx) =
            phantom_core::tun_simple::spawn(tun_fd, 4096)
                .context("Failed to start tun_simple handler")?;
        tracing::info!("tun_simple handler started");

        // Per-stream TX channels
        let mut tx_senders:   Vec<tokio::sync::mpsc::Sender<Bytes>>   = Vec::with_capacity(n_streams);
        let mut tx_receivers: Vec<tokio::sync::mpsc::Receiver<Bytes>> = Vec::with_capacity(n_streams);
        for _ in 0..n_streams {
            let (tx, rx) = tokio::sync::mpsc::channel::<Bytes>(2048);
            tx_senders.push(tx);
            tx_receivers.push(rx);
        }

        // Dispatcher: TUN reader → per-stream channel via flow hash
        let tx_senders_clone   = tx_senders.clone();
        let n_streams_dispatch = n_streams;
        let mut dispatcher = tokio::task::spawn_local(async move {
            let mut drop_full:   u64 = 0;
            let mut drop_closed: u64 = 0;
            while let Some(pkt) = tun_pkt_rx.recv().await {
                let idx = flow_stream_idx(&pkt, n_streams_dispatch);
                match tx_senders_clone[idx].try_send(pkt) {
                    Ok(()) => {}
                    Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                        drop_full += 1;
                        if drop_full == 1 || drop_full % 1024 == 0 {
                            tracing::warn!(
                                "dispatcher: stream {} full (dropped_full={})",
                                idx, drop_full
                            );
                        }
                    }
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                        drop_closed += 1;
                        tracing::warn!(
                            "dispatcher: stream {} closed (dropped_closed={}), exiting",
                            idx, drop_closed
                        );
                        return;
                    }
                }
            }
        });
        drop(tx_senders);

        // N streams, each reconnecting on its own; RX goes straight to TUN.
        for (idx, uplink) in tx_receivers.into_iter().enumerate() {
            tokio::task::spawn_local(run_stream(
                idx,
                n_streams,
                server.clone(),
                server_name.clone(),
                client_config.clone(),
                uplink,
                tun_pkt_tx.clone(),
            ));
        }
        drop(tun_pkt_tx);

        tracing::info!("Tunnel active. Send SIGTERM or SIGINT to stop.");

        let mut shutdown_rx_select = shutdown_rx.clone();
        tokio::select! {
            _ = wait_for_shutdown(&mut shutdown_rx_select) => {
                tracing::info!("Shutdown signal received.");
            }
            _ = &mut dispatcher => {
                // The TUN reader is gone; no reconnect brings it back.
                anyhow::bail!("TUN interface closed");
            }
        }

        tracing::info!("GhostStream OpenWrt client stopped.");
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::async_main()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("phantom-client-openwrt can only be run on Linux.");
}
