//! Headless smoke tests — run on any host (Mac/Linux/Windows) with
//! `cargo test -p client-windows-core`.

use client_windows_core::{MockBackend, TunBackend};

#[test]
fn mock_backend_roundtrip() {
    let backend = MockBackend::new();

    // Inbound: external "stack" pushes a packet, runtime reads it.
    backend.push_rx(vec![1, 2, 3, 4]);
    let mut buf = [0u8; 16];
    let n = backend.read(&mut buf).expect("read");
    assert_eq!(n, 4);
    assert_eq!(&buf[..n], &[1, 2, 3, 4]);

    // Outbound: runtime writes, external observer drains.
    backend.write(&[5, 6, 7]).expect("write");
    let drained = backend.drain_tx();
    assert_eq!(drained, vec![vec![5, 6, 7]]);
}

#[test]
fn mock_backend_read_empty_would_block() {
    let backend = MockBackend::new();
    let mut buf = [0u8; 16];
    let err = backend.read(&mut buf).expect_err("empty rx should error");
    assert_eq!(err.kind(), std::io::ErrorKind::WouldBlock);
}
