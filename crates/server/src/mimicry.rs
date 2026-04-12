//! TLS/HTTPS mimicry warmup.
//!
//! In the first ~2 seconds of a freshly-accepted VPN session we don't want
//! to let the client flood the TLS channel with full-bandwidth VPN payload —
//! that pattern is trivially fingerprinted by TSPU heuristics as
//! "TLS handshake followed by instant traffic hammering → VPN".
//!
//! Instead, we write a staged sequence of frames that looks like a typical
//! mobile HTTPS page load: a small HTML-sized burst, a pause, a larger
//! "image-sized" burst, another pause, and a "final bundle". After the
//! schedule completes, the normal `tls_write_loop` takes over at full rate.
//!
//! Each emitted frame is a VALID wire-format batch containing exactly one
//! bogus 16-byte placeholder IP packet (will be parsed but discarded by the
//! TUN path — it fails the IPv4 sanity check in `tls_rx_loop`). Padding fills
//! the rest of the target size. The receiving side drops these frames
//! harmlessly.
//!
//! Only the first connection of a new session runs the warmup — subsequent
//! streams join directly. That keeps the aggregate warmup budget fixed at
//! ~60 KB per session regardless of stream count.

use std::time::Duration;

use rand::Rng;
use tokio::io::{AsyncWrite, AsyncWriteExt};

use phantom_core::wire::build_batch_plaintext;

/// Base warmup schedule: (delay_before_burst, target_bytes_in_burst).
/// Total on-wire bytes over warmup: ~50 KB over ~1300 ms. Matches an HTTPS
/// page load with HTML + a couple of lazy-loaded images.
/// Each element gets per-session random jitter applied at runtime (see
/// `jittered_schedule`) so that successive sessions do not share the same
/// timing/size fingerprint.
const SCHEDULE: &[(u64, usize)] = &[
    (70,  2 * 1024),  // "HTML"
    (330, 8 * 1024),  // "image 1"
    (200, 16 * 1024), // "image 2"
    (200, 24 * 1024), // "bundle"
];

/// Apply random jitter to the base schedule: delay ±25%, size ±20%.
fn jittered_schedule() -> Vec<(Duration, usize)> {
    let mut rng = rand::thread_rng();
    SCHEDULE.iter().map(|&(delay_ms, size)| {
        let d_jitter: f64 = rng.gen_range(0.75..=1.25);
        let s_jitter: f64 = rng.gen_range(0.80..=1.20);
        let jittered_delay = Duration::from_millis((delay_ms as f64 * d_jitter) as u64);
        let jittered_size  = ((size as f64 * s_jitter) as usize).max(64);
        (jittered_delay, jittered_size)
    }).collect()
}

/// Placeholder IP packet: 16 zero bytes. Fails IPv4 parse (version nibble = 0)
/// so the client TUN writer discards it without side effects.
const PLACEHOLDER_PKT: [u8; 16] = [0u8; 16];

/// Run the mimicry warmup schedule against `writer`.
///
/// Each step sleeps for the specified delay, then emits a frame with
/// `[4B frame_len]` + batch plaintext padded to the target size. The client
/// reads these frames through its normal RX loop and discards the placeholder
/// packets. Returns early on first write error (peer closed).
pub async fn warmup_write<W>(writer: &mut W) -> std::io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let schedule = jittered_schedule();
    for &(delay, target) in &schedule {
        tokio::time::sleep(delay).await;

        // Build one valid batch frame: [2B pktlen=16][16B zeros][2B 0x0000][padding]
        let mut plaintext = vec![0u8; target];
        let pt_len = build_batch_plaintext(
            &[&PLACEHOLDER_PKT[..]],
            target,
            &mut plaintext,
        ).map_err(|e| std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("build_batch_plaintext: {:?}", e),
        ))?;

        let mut frame = Vec::with_capacity(4 + pt_len);
        frame.extend_from_slice(&(pt_len as u32).to_be_bytes());
        frame.extend_from_slice(&plaintext[..pt_len]);

        writer.write_all(&frame).await?;
    }
    writer.flush().await?;
    Ok(())
}
