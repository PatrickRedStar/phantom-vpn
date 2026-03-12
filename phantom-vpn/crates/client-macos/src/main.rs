//! phantom-client-macos: macOS VPN client.
//! Uses macOS `utun` via AF_SYSTEM sockets.

#[cfg(target_os = "macos")]
mod macos {
    use std::net::SocketAddr;
    use std::sync::Arc;
    use std::io::{self, Read, Write};
    use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
    use std::pin::Pin;
    use std::process::Command;
    use std::task::Poll;

    use anyhow::Context;
    use clap::Parser;
    use tokio::io::unix::AsyncFd;
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, AsyncReadExt};
    use tokio::net::UdpSocket;
    use tokio::sync::mpsc;

    use client_common::helpers::{self, Args};

    const AF_SYSTEM: libc::c_int = 32;
    const SYSPROTO_CONTROL: libc::c_int = 2;
    const UTUN_CONTROL_NAME: &[u8] = b"com.apple.net.utun_control\0";
    const UTUN_OPT_IFNAME: libc::c_int = 2;

    const CTLIOCGINFO: libc::c_ulong = 0xc0644e03;

#[repr(C)]
struct ctl_info {
    ctl_id: u32,
    ctl_name: [libc::c_char; 96],
}

#[repr(C)]
struct sockaddr_ctl {
    sc_len: libc::c_uchar,
    sc_family: libc::c_uchar,
    ss_sysaddr: u16,
    sc_id: u32,
    sc_unit: u32,
    sc_reserved: [u32; 5],
}

// ─── AsyncTun macOS ──────────────────────────────────────────────────────────

// On macOS utun, data read/written must include a 4-byte protocol family header.
// AF_INET is 2 in network byte order: [0, 0, 0, 2].

struct AsyncTun {
    inner: AsyncFd<std::fs::File>,
}

impl AsyncTun {
    fn new(fd: RawFd) -> io::Result<Self> {
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        Ok(Self { inner: AsyncFd::new(file)? })
    }
}

impl AsyncRead for AsyncTun {
    fn poll_read(
        self: Pin<&mut Self>, cx: &mut std::task::Context<'_>, buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            let mut guard = match self.inner.poll_read_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            
            // Read into a temporary buffer to strip the 4-byte PI header
            let mut temp_buf = vec![0u8; buf.remaining() + 4];
            
            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::read(
                        inner.as_raw_fd(),
                        temp_buf.as_mut_ptr() as *mut libc::c_void,
                        temp_buf.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n) }
            }) {
                Ok(Ok(n)) => {
                    if n >= 4 {
                        buf.put_slice(&temp_buf[4..n as usize]);
                    }
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(e)) => return Poll::Ready(Err(e)),
                Err(_blocked) => continue, // try again later
            }
        }
    }
}

impl AsyncWrite for AsyncTun {
    fn poll_write(
        self: Pin<&mut Self>, cx: &mut std::task::Context<'_>, data: &[u8],
    ) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = match self.inner.poll_write_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            
            // Prepend the 4-byte PI header (AF_INET = 2)
            let mut write_buf = Vec::with_capacity(data.len() + 4);
            write_buf.extend_from_slice(&[0, 0, 0, 2]); // AF_INET
            write_buf.extend_from_slice(data);

            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.as_raw_fd(),
                        write_buf.as_ptr() as *const libc::c_void,
                        write_buf.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n) }
            }) {
                Ok(Ok(n)) => {
                    // return the number of user bytes written, not including header
                    let written_user_bytes = if n >= 4 { (n as usize) - 4 } else { 0 };
                    return Poll::Ready(Ok(written_user_bytes));
                }
                Ok(Err(e))    => return Poll::Ready(Err(e)),
                Err(_blocked) => continue,
            }
        }
    }
    
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

// ─── Control Commands ────────────────────────────────────────────────────────

fn run_cmd(prog: &str, args: &[&str]) -> anyhow::Result<()> {
    let status = Command::new(prog).args(args).status()
        .with_context(|| format!("Failed to exec: {} {}", prog, args.join(" ")))?;
    if !status.success() {
        anyhow::bail!("{} {} exited with {}", prog, args.join(" "), status);
    }
    Ok(())
}

fn add_default_route(tun_name: &str, gateway: &str) -> anyhow::Result<()> {
    // macOS 'route' command
    let _ = run_cmd("route", &["delete", "default"]);
    run_cmd("route", &["add", "default", gateway, "-iface", tun_name])?;
    tracing::info!("Default route set via {} gw {}", tun_name, gateway);
    Ok(())
}

// ─── UTUN Creation ───────────────────────────────────────────────────────────

fn create_utun(addr_cidr: &str, mtu: u32) -> anyhow::Result<(RawFd, String)> {
    let fd = unsafe { libc::socket(AF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL) };
    if fd < 0 {
        anyhow::bail!("Failed to create AF_SYSTEM socket: {}", io::Error::last_os_error());
    }

    let mut info = ctl_info {
        ctl_id: 0,
        ctl_name: [0; 96],
    };
    for (i, &b) in UTUN_CONTROL_NAME.iter().enumerate() {
        info.ctl_name[i] = b as libc::c_char;
    }

    let ret = unsafe { libc::ioctl(fd, CTLIOCGINFO, &mut info as *mut _) };
    if ret < 0 {
        unsafe { libc::close(fd); }
        anyhow::bail!("CTLIOCGINFO failed: {}", io::Error::last_os_error());
    }

    let addr = sockaddr_ctl {
        sc_len: std::mem::size_of::<sockaddr_ctl>() as libc::c_uchar,
        sc_family: AF_SYSTEM as libc::c_uchar,
        ss_sysaddr: libc::AF_SYS_CONTROL as u16,
        sc_id: info.ctl_id,
        sc_unit: 0, // 0 lets system pick the next available utunX
        sc_reserved: [0; 5],
    };

    let ret = unsafe { 
        libc::connect(
            fd, 
            &addr as *const _ as *const libc::sockaddr, 
            std::mem::size_of_val(&addr) as libc::socklen_t
        ) 
    };
    if ret < 0 {
        unsafe { libc::close(fd); }
        anyhow::bail!("connect to utun failed: {}", io::Error::last_os_error());
    }

    // Get the interface name
    let mut ifname = [0u8; 16];
    let mut ifname_len = ifname.len() as libc::socklen_t;
    let ret = unsafe {
        libc::getsockopt(
            fd,
            SYSPROTO_CONTROL,
            UTUN_OPT_IFNAME,
            ifname.as_mut_ptr() as *mut libc::c_void,
            &mut ifname_len,
        )
    };
    if ret < 0 {
        unsafe { libc::close(fd); }
        anyhow::bail!("getsockopt UTUN_OPT_IFNAME failed: {}", io::Error::last_os_error());
    }
    
    // Convert to string, trimming nulls
    let ifname_str = std::str::from_utf8(&ifname[..(ifname_len as usize - 1)])
        .unwrap_or("utunX")
        .to_string();

    // Set non-blocking
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    // Parse the IP address and get a destination address 
    // Usually `ifconfig utunX <source_ip> <dest_ip> mtu <mtu> up`
    // We'll use the IP before the slash as both src and dst for simplicity
    let ip = addr_cidr.split('/').next().unwrap_or("10.7.0.2");
    
    run_cmd("ifconfig", &[&ifname_str, ip, ip, "mtu", &mtu.to_string(), "up"])?;
    tracing::info!("TUN {} up: addr={} mtu={}", ifname_str, ip, mtu);

    Ok((fd, ifname_str))
}

// ─── Main ────────────────────────────────────────────────────────────────────

    #[tokio::main]
    pub async fn async_main() -> anyhow::Result<()> {
        let args = Args::parse();
        helpers::init_logging(args.verbose);
        tracing::info!("PhantomVPN macOS Client starting...");

    let cfg = helpers::load_config(&args.config)?;

    let server_addr: SocketAddr = if let Some(ref sa) = args.server {
        sa.parse().context("Invalid --server address")?
    } else {
        cfg.network.server_addr.parse().context("Invalid config server_addr")?
    };
    tracing::info!("Server address: {}", server_addr);

    let client_keys = Arc::new(helpers::load_client_keys(&cfg)?);
    let server_public = helpers::load_server_public_key(&cfg)?;
    let shared_secret = helpers::load_shared_secret(&cfg)?;
    tracing::info!("Client public key: {}", hex::encode(&client_keys.public));

    // ─── UDP socket ──────────────────────────────────────────────────────
    let bind_addr: SocketAddr = "0.0.0.0:0".parse().unwrap();
    let socket = Arc::new(UdpSocket::bind(bind_addr).await.context("UDP bind failed")?);
    socket.connect(server_addr).await.context("UDP connect failed")?;
    tracing::info!("UDP socket bound, targeting {}", server_addr);

    // ─── Noise IK Handshake ──────────────────────────────────────────────
    tracing::info!("Performing Noise IK handshake...");
    let (noise_session, our_ssrc) = helpers::perform_handshake(
        &socket, &client_keys, &server_public, &shared_secret,
    ).await.context("Handshake failed")?;
    tracing::info!("Handshake complete! SSRC={:#010x}", our_ssrc);

    // ─── TUN interface ───────────────────────────────────────────────────
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1380);

    tracing::info!("Creating macOS utun interface...");
    let (fd, ifname) = create_utun(tun_addr, tun_mtu)?;
    let async_tun = AsyncTun::new(fd).context("Failed to create async TUN")?;
    let (mut tun_reader, mut tun_writer) = tokio::io::split(async_tun);

    // Default route
    if let Some(ref gw) = cfg.network.default_gw {
        add_default_route(&ifname, gw)
            .unwrap_or_else(|e| tracing::warn!("Route setup failed: {}", e));
    }

    // ─── Channels ────────────────────────────────────────────────────────
    let noise_arc = Arc::new(tokio::sync::Mutex::new(noise_session));
    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(256);
    let (udp_pkt_tx, mut udp_pkt_rx) = mpsc::channel::<Vec<u8>>(256);

    // ─── TUN writer: decrypted packets → TUN ─────────────────────────────
    tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        while let Some(pkt) = udp_pkt_rx.recv().await {
            if let Err(e) = tun_writer.write_all(&pkt).await {
                tracing::error!("TUN write error: {}", e);
            }
        }
    });

    // ─── TUN reader: TUN → channel ───────────────────────────────────────
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        loop {
            match tun_reader.read(&mut buf).await {
                Ok(0) => continue,
                Ok(n) => {
                    if tun_pkt_tx.send(buf[..n].to_vec()).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    tracing::error!("TUN read error: {}", e);
                    tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                }
            }
        }
    });

    // ─── UDP RX (server → decrypt → TUN) ─────────────────────────────────
    {
        let sock_rx  = socket.clone();
        let noise_rx = noise_arc.clone();
        tokio::spawn(async move {
            if let Err(e) = client_common::udp_rx_loop(sock_rx, noise_rx, udp_pkt_tx).await {
                tracing::error!("udp_rx_loop exited: {}", e);
            }
        });
    }

    // ─── TUN → encrypt → UDP ─────────────────────────────────────────────
    {
        let sock_tx  = socket.clone();
        let noise_tx = noise_arc.clone();
        tokio::spawn(async move {
            if let Err(e) = client_common::tun_to_udp_loop(tun_pkt_rx, sock_tx, noise_tx, our_ssrc).await {
                tracing::error!("tun_to_udp_loop exited: {}", e);
            }
        });
    }

    tracing::info!("Tunnel active on {}. Press Ctrl-C to exit.", ifname);
    tokio::signal::ctrl_c().await?;
        tracing::info!("Shutting down...");
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    macos::async_main()
}

#[cfg(not(target_os = "macos"))]
fn main() {
    println!("PhantomVPN macOS Client can only be run on macOS.");
}
