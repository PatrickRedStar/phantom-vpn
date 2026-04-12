//! Simple blocking TUN reader/writer — fallback for kernels without io_uring.
//!
//! Reader: read() in a dedicated thread, filters IPv4, sends Bytes into channel.
//! Writer: receives Bytes from channel, write_all() to TUN fd.
//!
//! Same API as `tun_uring::spawn()` so callers can switch between impls via cfg.

use std::io::{self, Read, Write};
use std::mem;
use std::os::unix::io::{FromRawFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use tokio::sync::mpsc;

const BUF_SIZE: usize = 2048;

pub fn spawn(
    tun_fd: RawFd,
    channel_size: usize,
) -> anyhow::Result<(mpsc::Receiver<Bytes>, mpsc::Sender<Bytes>)> {
    let (read_tx, read_rx) = mpsc::channel::<Bytes>(channel_size);
    let (write_tx, write_rx) = mpsc::channel::<Bytes>(channel_size);

    let stop = Arc::new(AtomicBool::new(false));

    // Set fd to non-blocking so we can poll stop flag without hanging forever.
    // SAFETY: tun_fd is a valid open file descriptor owned by the caller.
    unsafe {
        let flags = libc::fcntl(tun_fd, libc::F_GETFL, 0);
        if flags < 0 {
            return Err(anyhow::anyhow!(
                "tun_simple: fcntl F_GETFL failed: {}",
                io::Error::last_os_error()
            ));
        }
        let rc = libc::fcntl(tun_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        if rc < 0 {
            return Err(anyhow::anyhow!(
                "tun_simple: fcntl F_SETFL O_NONBLOCK failed: {}",
                io::Error::last_os_error()
            ));
        }
    }

    {
        let stop = stop.clone();
        std::thread::Builder::new()
            .name("tun-simple-read".into())
            .spawn(move || {
                reader_loop(tun_fd, read_tx, stop);
            })?;
    }

    {
        let stop = stop.clone();
        std::thread::Builder::new()
            .name("tun-simple-write".into())
            .spawn(move || {
                writer_loop(tun_fd, write_rx, stop);
            })?;
    }

    Ok((read_rx, write_tx))
}

fn reader_loop(fd: RawFd, tx: mpsc::Sender<Bytes>, stop: Arc<AtomicBool>) {
    // Wrap fd in a File for read() convenience, but use mem::forget so we
    // never close the fd — ownership remains with the caller.
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut buf = vec![0u8; BUF_SIZE];

    tracing::info!("tun_simple reader started");

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        match file.read(&mut buf) {
            Ok(0) => {
                // EOF — TUN closed
                tracing::warn!("tun_simple reader: EOF on TUN fd");
                break;
            }
            Ok(n) => {
                // Only forward valid IPv4 packets (version nibble == 4, min 20 B header)
                if n >= 20 && (buf[0] >> 4) == 4 {
                    let mut bm = BytesMut::with_capacity(n);
                    bm.extend_from_slice(&buf[..n]);
                    if tx.blocking_send(bm.freeze()).is_err() {
                        // Receiver dropped — shut down
                        break;
                    }
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                // Nothing ready yet — yield briefly and retry
                std::thread::sleep(Duration::from_micros(100));
            }
            Err(e) => {
                tracing::error!("tun_simple reader: read error: {}", e);
                break;
            }
        }
    }

    // Do NOT close the fd — the caller owns it.
    mem::forget(file);
    tracing::info!("tun_simple reader stopped");
}

fn writer_loop(fd: RawFd, mut rx: mpsc::Receiver<Bytes>, stop: Arc<AtomicBool>) {
    // Same fd-ownership discipline as reader_loop.
    let mut file = unsafe { std::fs::File::from_raw_fd(fd) };

    tracing::info!("tun_simple writer started");

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        match rx.blocking_recv() {
            None => break, // sender dropped
            Some(pkt) => {
                if let Err(e) = file.write_all(&pkt) {
                    tracing::error!("tun_simple writer: write error: {}", e);
                    break;
                }
            }
        }
    }

    mem::forget(file);
    tracing::info!("tun_simple writer stopped");
}
