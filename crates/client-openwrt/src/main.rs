//! phantom-client-openwrt: minimal VPN daemon for OpenWrt routers.
//!
//! Key differences from client-linux:
//! - No clap — manual arg parsing (--conn-string, --tun-name, --mtu)
//! - Uses tun_simple instead of tun_uring (no io_uring on OpenWrt kernels)
//! - current_thread tokio runtime (saves RAM on routers)
//! - IP addr/routes managed by netifd; we only bring up the interface
//! - Emits JSON to stdout on startup: {"tun_name":"gs0","tun_addr":"...","gateway":"..."}

#[cfg(target_os = "linux")]
mod linux {
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::net::SocketAddr;
    use std::os::unix::io::AsRawFd;
    use std::process::Command;

    use anyhow::Context;
    use bytes::Bytes;
    use client_common::helpers::parse_conn_string;
    use client_common::{tls_connect, tls_rx_loop, tls_tx_loop, with_default_port, write_handshake};
    use phantom_core::wire::{flow_stream_idx, n_data_streams};
    use tokio::signal;
    use tokio::sync::watch;

    const TUNSETIFF: libc::c_ulong = 0x400454CA;
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

    // ─── Main ─────────────────────────────────────────────────────────────────

    #[tokio::main(flavor = "current_thread")]
    pub async fn async_main() -> anyhow::Result<()> {
        // Ring crypto provider must be installed before any TLS usage
        rustls::crypto::ring::default_provider()
            .install_default()
            .expect("Failed to install ring crypto provider");

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

        let raw_addr = cfg.network.server_addr.clone();
        let raw_addr = with_default_port(&raw_addr, 443);
        let server_addr: SocketAddr = if let Ok(addr) = raw_addr.parse() {
            addr
        } else {
            tracing::info!("Resolving DNS for {}", raw_addr);
            tokio::net::lookup_host(&raw_addr)
                .await
                .context("DNS lookup failed")?
                .next()
                .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", raw_addr))?
        };
        tracing::info!("Server address: {}", server_addr);

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

        // Load TLS identity and CA
        let client_identity =
            client_common::helpers::load_tls_identity(&cfg)?;
        let server_ca =
            client_common::helpers::load_server_ca(&cfg)?;

        let skip_verify = cfg.network.insecure;
        if !skip_verify && server_ca.is_none() {
            anyhow::bail!(
                "No CA certificate provided and insecure=false. \
                 Set insecure=true or provide ca_cert in the connection string."
            );
        }

        // Build TLS client config
        let client_config =
            phantom_core::h2_transport::make_h2_client_tls(skip_verify, server_ca, client_identity)
                .context("Failed to build TLS client config")?;

        let n_streams   = n_data_streams();
        let server_name = cfg.network.server_name.as_deref().unwrap_or("phantom").to_string();

        // Open N parallel TLS streams
        let mut tls_writers = Vec::with_capacity(n_streams);
        let mut tls_readers = Vec::with_capacity(n_streams);
        for idx in 0..n_streams {
            let (r, mut w) = tls_connect(server_addr, server_name.clone(), client_config.clone())
                .await
                .with_context(|| format!("stream {}: TLS connect failed", idx))?;
            write_handshake(&mut w, idx as u8, n_streams as u8)
                .await
                .with_context(|| format!("stream {}: write_handshake failed", idx))?;
            tracing::info!("Stream {}: connected", idx);
            tls_readers.push(r);
            tls_writers.push(w);
        }
        tracing::info!("All {} TLS streams up", n_streams);

        // Create TUN interface (netifd configures the IP address)
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

        // Single RX sink for all N rx loops → TUN writer
        let (rx_sink_tx, mut rx_sink_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);

        // Dispatcher: TUN reader → per-stream channel via flow hash
        let tx_senders_clone   = tx_senders.clone();
        let n_streams_dispatch = n_streams;
        tokio::task::spawn_local(async move {
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

        // RX forwarder: sink → TUN writer
        let tun_write_tx = tun_pkt_tx.clone();
        tokio::task::spawn_local(async move {
            while let Some(pkt) = rx_sink_rx.recv().await {
                if tun_write_tx.send(pkt).await.is_err() {
                    return;
                }
            }
        });
        drop(tun_pkt_tx);

        // N TX + N RX tasks
        let mut tx_handles = Vec::with_capacity(n_streams);
        let mut rx_handles = Vec::with_capacity(n_streams);
        for (idx, (w, rxc)) in tls_writers
            .into_iter()
            .zip(tx_receivers.into_iter())
            .enumerate()
        {
            tx_handles.push(tokio::task::spawn_local(async move {
                let res = tls_tx_loop(w, rxc).await;
                tracing::warn!("stream {}: tx loop ended: {:?}", idx, res);
                res
            }));
        }
        for (idx, r) in tls_readers.into_iter().enumerate() {
            let sink = rx_sink_tx.clone();
            rx_handles.push(tokio::task::spawn_local(async move {
                let res = tls_rx_loop(r, sink).await;
                tracing::warn!("stream {}: rx loop ended: {:?}", idx, res);
                res
            }));
        }
        drop(rx_sink_tx);

        tracing::info!("Tunnel active. Send SIGTERM or SIGINT to stop.");

        let mut shutdown_rx_select = shutdown_rx.clone();
        tokio::select! {
            _ = wait_for_shutdown(&mut shutdown_rx_select) => {
                tracing::info!("Shutdown signal received.");
                for h in tx_handles { h.abort(); }
                for h in rx_handles { h.abort(); }
            }
            _ = async {
                for h in &mut tx_handles { let _ = h.await; }
            } => {
                tracing::warn!("All TX loops exited.");
            }
            _ = async {
                for h in &mut rx_handles { let _ = h.await; }
            } => {
                tracing::warn!("All RX loops exited.");
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
