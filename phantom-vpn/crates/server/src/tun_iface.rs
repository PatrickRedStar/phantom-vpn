//! TUN интерфейс на Linux: создание, настройка, async read/write.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::pin::Pin;
use std::task::Poll;
use std::process::Command;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::io::unix::AsyncFd;

// ─── ioctl constants ─────────────────────────────────────────────────────────

const TUNSETIFF: libc::c_ulong = 0x400454CA;
const IFF_TUN:   libc::c_short = 0x0001;
const IFF_NO_PI: libc::c_short = 0x1000;

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
            ifr_flags: IFF_TUN | IFF_NO_PI,
            _pad:      [0; 22],
        };
        let copy_len = name.len().min(libc::IFNAMSIZ - 1);
        for (i, &b) in name.as_bytes()[..copy_len].iter().enumerate() {
            ifr.ifr_name[i] = b as libc::c_char;
        }

        let ret = unsafe { libc::ioctl(file.as_raw_fd(), TUNSETIFF, &ifr as *const _) };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(TunInterface { name: name.to_string(), file })
    }

    pub fn configure(&self, addr_cidr: &str, mtu: u32) -> io::Result<()> {
        run_cmd("ip", &["addr", "add", addr_cidr, "dev", &self.name])?;
        run_cmd("ip", &["link", "set", "dev", &self.name, "mtu", &mtu.to_string(), "up"])?;
        tracing::info!("TUN {} up: addr={} mtu={}", self.name, addr_cidr, mtu);
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

pub fn setup_nat(tun_name: &str, wan_iface: &str, subnet: &str) -> io::Result<()> {
    let _ = run_cmd("sysctl", &["-w", "net.ipv4.ip_forward=1"]);
    let _ = run_cmd("iptables", &["-t", "nat", "-A", "POSTROUTING",
        "-s", subnet, "-o", wan_iface, "-j", "MASQUERADE"]);
    let _ = run_cmd("iptables", &["-A", "FORWARD",
        "-i", tun_name, "-o", wan_iface, "-j", "ACCEPT"]);
    let _ = run_cmd("iptables", &["-A", "FORWARD",
        "-i", wan_iface, "-o", tun_name,
        "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT"]);
    tracing::info!("NAT: {} → {} (subnet {})", tun_name, wan_iface, subnet);
    Ok(())
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
