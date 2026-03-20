//! io_uring-based TUN reader/writer.
//!
//! Reader: pre-submits N reads, on each completion sends packet + resubmits that buffer.
//! Writer: collects packets from channel, submits batch writes.

use std::os::unix::io::RawFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use io_uring::{IoUring, opcode, types};
use tokio::sync::mpsc;

const RING_SIZE: u32 = 64;
const BUF_SIZE: usize = 2048;
const N_READ_BUFS: usize = 16;

pub fn spawn(
    tun_fd: RawFd,
    channel_size: usize,
) -> anyhow::Result<(mpsc::Receiver<Vec<u8>>, mpsc::Sender<Vec<u8>>)> {
    let (read_tx, read_rx) = mpsc::channel::<Vec<u8>>(channel_size);
    let (write_tx, write_rx) = mpsc::channel::<Vec<u8>>(channel_size);

    let stop = Arc::new(AtomicBool::new(false));

    {
        let stop = stop.clone();
        std::thread::Builder::new()
            .name("tun-uring-read".into())
            .spawn(move || {
                if let Err(e) = reader_loop(tun_fd, read_tx, stop) {
                    tracing::error!("io_uring reader: {}", e);
                }
            })?;
    }

    {
        let stop = stop.clone();
        std::thread::Builder::new()
            .name("tun-uring-write".into())
            .spawn(move || {
                if let Err(e) = writer_loop(tun_fd, write_rx, stop) {
                    tracing::error!("io_uring writer: {}", e);
                }
            })?;
    }

    Ok((read_rx, write_tx))
}

fn reader_loop(
    fd: RawFd,
    tx: mpsc::Sender<Vec<u8>>,
    stop: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    let mut ring = IoUring::new(RING_SIZE)?;
    let fd_t = types::Fd(fd);

    // Pre-allocate read buffers
    let mut bufs: Vec<Vec<u8>> = (0..N_READ_BUFS)
        .map(|_| vec![0u8; BUF_SIZE])
        .collect();

    // Submit initial reads — each buffer gets one pending read
    for (i, buf) in bufs.iter_mut().enumerate() {
        let entry = opcode::Read::new(fd_t, buf.as_mut_ptr(), buf.len() as u32)
            .build()
            .user_data(i as u64);
        unsafe { ring.submission().push(&entry).expect("SQ full on init"); }
    }
    ring.submit()?;

    tracing::info!("io_uring TUN reader started (bufs={})", N_READ_BUFS);

    loop {
        if stop.load(Ordering::Relaxed) { break; }

        // Wait for at least 1 completion
        ring.submit_and_wait(1)?;

        // Collect completed indices first (can't borrow ring mutably while iterating CQ)
        let mut completed: Vec<(usize, i32)> = Vec::with_capacity(N_READ_BUFS);
        for cqe in ring.completion() {
            completed.push((cqe.user_data() as usize, cqe.result()));
        }

        // Process completions and resubmit
        for (idx, result) in completed {
            if result > 0 {
                let len = result as usize;
                if len >= 20 && (bufs[idx][0] >> 4) == 4 {
                    if tx.blocking_send(bufs[idx][..len].to_vec()).is_err() {
                        stop.store(true, Ordering::Relaxed);
                        return Ok(());
                    }
                }
            }

            // Resubmit this buffer
            let entry = opcode::Read::new(fd_t, bufs[idx].as_mut_ptr(), bufs[idx].len() as u32)
                .build()
                .user_data(idx as u64);
            unsafe { ring.submission().push(&entry).expect("SQ full on resubmit"); }
        }

        ring.submit()?;
    }

    Ok(())
}

fn writer_loop(
    fd: RawFd,
    mut rx: mpsc::Receiver<Vec<u8>>,
    stop: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    let mut ring = IoUring::new(RING_SIZE)?;
    let fd_t = types::Fd(fd);
    let mut pending: Vec<Vec<u8>> = Vec::with_capacity(32);

    tracing::info!("io_uring TUN writer started");

    loop {
        if stop.load(Ordering::Relaxed) { break; }

        // Wait for first packet
        let first = match rx.blocking_recv() {
            Some(p) => p,
            None => break,
        };
        pending.push(first);

        // Drain more from channel (non-blocking)
        while pending.len() < 32 {
            match rx.try_recv() {
                Ok(p) => pending.push(p),
                Err(_) => break,
            }
        }

        // Submit all writes
        for (i, pkt) in pending.iter().enumerate() {
            let entry = opcode::Write::new(fd_t, pkt.as_ptr(), pkt.len() as u32)
                .build()
                .user_data(i as u64);
            unsafe {
                if ring.submission().push(&entry).is_err() {
                    ring.submit()?;
                    ring.submission().push(&entry).expect("SQ full after drain");
                }
            }
        }

        ring.submit_and_wait(pending.len())?;
        ring.completion().for_each(|_| {});
        pending.clear();
    }

    Ok(())
}

// ─── Multiqueue: spawn io_uring reader+writer per TUN queue FD ──────────────

/// Spawns io_uring handler threads for multiple TUN queue FDs.
/// All readers merge into one Receiver, all writers share one Sender.
pub fn spawn_multiqueue(
    fds: Vec<RawFd>,
    channel_size: usize,
) -> anyhow::Result<(mpsc::Receiver<Vec<u8>>, mpsc::Sender<Vec<u8>>)> {
    if fds.is_empty() {
        anyhow::bail!("spawn_multiqueue: no FDs provided");
    }
    if fds.len() == 1 {
        return spawn(fds[0], channel_size);
    }

    let (merged_tx, merged_rx) = mpsc::channel::<Vec<u8>>(channel_size);
    let (write_tx, write_rx) = mpsc::channel::<Vec<u8>>(channel_size);
    let stop = Arc::new(AtomicBool::new(false));
    let n_queues = fds.len();

    // Reader thread per queue — all merge into merged_tx
    for (i, &fd) in fds.iter().enumerate() {
        let tx = merged_tx.clone();
        let stop = stop.clone();
        std::thread::Builder::new()
            .name(format!("tun-mq-read-{}", i))
            .spawn(move || {
                if let Err(e) = reader_loop(fd, tx, stop) {
                    tracing::error!("io_uring reader queue {}: {}", i, e);
                }
            })?;
    }
    drop(merged_tx);

    // Writer thread per queue + round-robin dispatcher
    let mut writer_txs: Vec<mpsc::Sender<Vec<u8>>> = Vec::with_capacity(n_queues);
    for (i, &fd) in fds.iter().enumerate() {
        let (wtx, wrx) = mpsc::channel::<Vec<u8>>(channel_size / n_queues + 1);
        writer_txs.push(wtx);
        let stop = stop.clone();
        std::thread::Builder::new()
            .name(format!("tun-mq-write-{}", i))
            .spawn(move || {
                if let Err(e) = writer_loop(fd, wrx, stop) {
                    tracing::error!("io_uring writer queue {}: {}", i, e);
                }
            })?;
    }

    // Fan-out: write_rx → round-robin to writer threads
    std::thread::Builder::new()
        .name("tun-mq-dispatch".into())
        .spawn(move || {
            let mut idx = 0usize;
            let mut rx = write_rx;
            while let Some(pkt) = rx.blocking_recv() {
                if writer_txs[idx].blocking_send(pkt).is_err() {
                    break;
                }
                idx = (idx + 1) % n_queues;
            }
        })?;

    tracing::info!("io_uring multiqueue TUN: {} queues", n_queues);
    Ok((merged_rx, write_tx))
}
