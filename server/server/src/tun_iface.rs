//! TUN интерфейс на Linux: создание, настройка, async read/write.

use std::fs::File;
use std::io::{self};
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::pin::Pin;
use std::task::Poll;
use std::process::Command;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::io::unix::AsyncFd;

// ─── ioctl constants ─────────────────────────────────────────────────────────

const TUNSETIFF:       libc::c_ulong = 0x400454CA;
const IFF_TUN:         libc::c_short = 0x0001;
const IFF_NO_PI:       libc::c_short = 0x1000;
const IFF_MULTI_QUEUE: libc::c_short = 0x0100;
/// Fail with EBUSY if the interface already exists (e.g. a second server
/// instance must not silently attach to the live tun).
const IFF_TUN_EXCL:    libc::c_short = 0x8000u16 as libc::c_short;

#[repr(C)]
struct Ifreq {
    ifr_name:  [libc::c_char; libc::IFNAMSIZ],
    ifr_flags: libc::c_short,
    _pad:      [u8; 22],
}

// ─── TunInterface (synchronous) ───────────────────────────────────────────────

pub struct TunInterface {
    pub name: String,
    file:     File,
}

impl TunInterface {
    /// Открывает /dev/net/tun и настраивает интерфейс через ioctl TUNSETIFF
    pub fn create(name: &str) -> io::Result<Self> {
        let file = Self::open_queue(name, IFF_TUN | IFF_NO_PI | IFF_TUN_EXCL)?;
        Ok(TunInterface { name: name.to_string(), file })
    }

    /// Create TUN with multiqueue support. Returns N file descriptors (one per queue).
    /// First FD creates the interface, subsequent FDs attach to additional queues.
    /// Each queue can be read/written independently by a separate thread.
    pub fn create_multiqueue(name: &str, n_queues: usize) -> io::Result<(Self, Vec<File>)> {
        let flags = IFF_TUN | IFF_NO_PI | IFF_MULTI_QUEUE;
        // EXCL only on the creating open: attaching further queues to the
        // interface we just made would fail with it.
        let first = Self::open_queue(name, flags | IFF_TUN_EXCL)?;
        let mut extra_fds = Vec::with_capacity(n_queues.saturating_sub(1));
        for _ in 1..n_queues {
            extra_fds.push(Self::open_queue(name, flags)?);
        }
        Ok((TunInterface { name: name.to_string(), file: first }, extra_fds))
    }

    fn open_queue(name: &str, flags: libc::c_short) -> io::Result<File> {
        let file = unsafe {
            let fd = libc::open(
                b"/dev/net/tun\0".as_ptr() as *const libc::c_char,
                libc::O_RDWR | libc::O_NONBLOCK,
            );
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            File::from_raw_fd(fd)
        };

        let mut ifr = Ifreq {
            ifr_name:  [0; libc::IFNAMSIZ],
            ifr_flags: flags,
            _pad:      [0; 22],
        };
        let copy_len = name.len().min(libc::IFNAMSIZ - 1);
        for (i, &b) in name.as_bytes()[..copy_len].iter().enumerate() {
            ifr.ifr_name[i] = b as libc::c_char;
        }

        #[allow(clippy::unnecessary_cast)]
        let ret = unsafe { libc::ioctl(file.as_raw_fd(), TUNSETIFF as _, &ifr as *const _) };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(file)
    }

    pub fn configure(&self, addr_cidr: &str, mtu: u32) -> io::Result<()> {
        run_cmd("ip", &["addr", "add", addr_cidr, "dev", &self.name])?;
        run_cmd("ip", &["link", "set", "dev", &self.name,
            "mtu", &mtu.to_string(),
            "txqueuelen", "10000",
            "up"])?;
        tracing::info!("TUN {} up: addr={} mtu={} txqueuelen=10000", self.name, addr_cidr, mtu);
        Ok(())
    }

    pub fn into_file(self) -> File {
        self.file
    }
}

// ─── AsyncTun ────────────────────────────────────────────────────────────────

/// Async TUN wrapper — implements tokio AsyncRead + AsyncWrite
/// so it can be split with tokio::io::split()
pub struct AsyncTun {
    inner: AsyncFd<File>,
}

impl AsyncTun {
    pub fn new(file: File) -> io::Result<Self> {
        Ok(Self { inner: AsyncFd::new(file)? })
    }
}

impl AsyncRead for AsyncTun {
    fn poll_read(
        self:  Pin<&mut Self>,
        cx:    &mut std::task::Context<'_>,
        buf:   &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            let mut guard = match self.inner.poll_read_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            let unfilled = buf.initialize_unfilled();
            match guard.try_io(|inner| {
                // SAFETY: AsyncFd guarantees the fd is ready; we read without mut ref clone
                let n = unsafe {
                    libc::read(
                        inner.as_raw_fd(),
                        unfilled.as_mut_ptr() as *mut libc::c_void,
                        unfilled.len(),
                    )
                };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(Ok(n)) => {
                    buf.advance(n);
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(e))    => return Poll::Ready(Err(e)),
                Err(_blocked) => continue,
            }
        }
    }
}

impl AsyncWrite for AsyncTun {
    fn poll_write(
        self:  Pin<&mut Self>,
        cx:    &mut std::task::Context<'_>,
        data:  &[u8],
    ) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = match self.inner.poll_write_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.as_raw_fd(),
                        data.as_ptr() as *const libc::c_void,
                        data.len(),
                    )
                };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            }) {
                Ok(result)    => return Poll::Ready(result),
                Err(_blocked) => continue,
            }
        }
    }

    fn poll_flush(
        self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>
    ) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(
        self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>
    ) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

impl AsRawFd for AsyncTun {
    fn as_raw_fd(&self) -> RawFd {
        self.inner.as_raw_fd()
    }
}

// ─── NAT ─────────────────────────────────────────────────────────────────────

/// Private / special destinations a client must not reach through the exit
/// (the provider's internal networks, other clients, link-local metadata).
const BLOCKED_DST: &[&str] = &[
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16",
];

/// All iptables rules of the server: (table, chain, rule spec). The order is
/// the final order inside each chain: setup inserts them at the top (`-I … 1`)
/// in reverse, teardown deletes by the same spec — so both never drift apart.
fn nat_rules(tun: &str, wan: &str, subnet: &str, exit_ip: Option<&str>, admin_port: u16)
    -> Vec<(&'static str, &'static str, Vec<String>)>
{
    let comment = format!("phantom-vpn-{}", tun);
    let rule = |table: &'static str, chain: &'static str, spec: &[&str]| {
        let mut v: Vec<String> = spec.iter().map(|s| s.to_string()).collect();
        v.extend(["-m", "comment", "--comment", &comment].map(String::from));
        (table, chain, v)
    };
    let admin_port = admin_port.to_string();
    let mut rules = vec![match exit_ip {
        // SNAT: трафик выходит с конкретного IP (второй IP сервера)
        Some(ip) => rule("nat", "POSTROUTING", &["-s", subnet, "-o", wan, "-j", "SNAT", "--to-source", ip]),
        None => rule("nat", "POSTROUTING", &["-s", subnet, "-o", wan, "-j", "MASQUERADE"]),
    }];
    // FORWARD: no private destinations, no SMTP (spam from the only exit IP
    // gets it blacklisted), then the usual tun ⇄ wan accept.
    for dst in BLOCKED_DST {
        rules.push(rule("filter", "FORWARD", &["-i", tun, "-d", dst, "-j", "DROP"]));
    }
    rules.push(rule("filter", "FORWARD", &["-i", tun, "-p", "tcp", "--dport", "25", "-j", "REJECT"]));
    rules.push(rule("filter", "FORWARD", &["-i", tun, "-o", wan, "-j", "ACCEPT"]));
    rules.push(rule("filter", "FORWARD", &["-i", wan, "-o", tun,
        "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"]));
    // INPUT from the tunnel: only the admin API, SSH, DNS and ping reach the
    // exit host itself; everything else on it stays invisible to clients.
    rules.push(rule("filter", "INPUT", &["-i", tun, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"]));
    rules.push(rule("filter", "INPUT", &["-i", tun, "-p", "icmp", "-j", "ACCEPT"]));
    rules.push(rule("filter", "INPUT", &["-i", tun, "-p", "tcp", "--dport", &admin_port, "-j", "ACCEPT"]));
    rules.push(rule("filter", "INPUT", &["-i", tun, "-p", "tcp", "--dport", "22", "-j", "ACCEPT"]));
    rules.push(rule("filter", "INPUT", &["-i", tun, "-p", "udp", "--dport", "53", "-j", "ACCEPT"]));
    rules.push(rule("filter", "INPUT", &["-i", tun, "-p", "tcp", "--dport", "53", "-j", "ACCEPT"]));
    rules.push(rule("filter", "INPUT", &["-i", tun, "-j", "DROP"]));
    rules
}

/// Forwarding + NAT + tunnel firewall. Any failure is returned: a server that
/// "works" without NAT gives clients a connected tunnel with no internet.
pub fn setup_nat(tun_name: &str, wan_iface: &str, subnet: &str, exit_ip: Option<&str>, admin_port: u16) -> io::Result<()> {
    if !std::path::Path::new("/sys/class/net").join(wan_iface).exists() {
        return Err(io::Error::other(format!("WAN interface '{}' not found ([network].wan_iface)", wan_iface)));
    }
    run_cmd("sysctl", &["-w", "net.ipv4.ip_forward=1"])?;
    for (table, chain, spec) in nat_rules(tun_name, wan_iface, subnet, exit_ip, admin_port).iter().rev() {
        let mut args = vec!["-t", table, "-I", chain, "1"];
        args.extend(spec.iter().map(String::as_str));
        run_cmd("iptables", &args)?;
    }
    match exit_ip {
        Some(ip) => tracing::info!("NAT: {} → {} via SNAT {} (subnet {})", tun_name, wan_iface, ip, subnet),
        None => tracing::info!("NAT: {} → {} via MASQUERADE (subnet {})", tun_name, wan_iface, subnet),
    }
    Ok(())
}

pub fn teardown_nat(tun_name: &str, wan_iface: &str, subnet: &str, exit_ip: Option<&str>, admin_port: u16) {
    for (table, chain, spec) in nat_rules(tun_name, wan_iface, subnet, exit_ip, admin_port) {
        let mut args = vec!["-t", table, "-D", chain];
        args.extend(spec.iter().map(String::as_str));
        // Rule may be absent (first start / already removed) — that's fine.
        let _ = run_cmd("iptables", &args);
    }
    tracing::info!("NAT teardown: {} → {}", tun_name, wan_iface);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn run_cmd(prog: &str, args: &[&str]) -> io::Result<()> {
    let status = Command::new(prog)
        .args(args)
        .status()?;
    if !status.success() {
        return Err(io::Error::other(format!("{} {} failed", prog, args.join(" "))));
    }
    Ok(())
}
