//! Headless smoke tests — run on any host (Mac/Linux/Windows) with
//! `cargo test -p client-windows-core`. The trait-object test proves that
//! `MockBackend` can be plugged into `client_core_runtime::TunIo::Backend`,
//! which is the cross-platform path the Windows client uses.

use std::sync::Arc;

use client_core_runtime::TunIo;
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

#[test]
fn tun_io_backend_accepts_mock_via_trait_object() {
    let backend = Arc::new(MockBackend::new());
    backend.push_rx(vec![0xAA, 0xBB, 0xCC]);

    // The whole point of the TunBackend trait: the runtime sees only
    // `Arc<dyn TunBackend>` and never knows whether it's the production
    // Wintun backend or a test mock.
    let tun_io = TunIo::Backend(backend);

    match tun_io {
        TunIo::Backend(b) => {
            let mut buf = [0u8; 8];
            let n = b.read(&mut buf).expect("read via dyn");
            assert_eq!(n, 3);
            assert_eq!(&buf[..n], &[0xAA, 0xBB, 0xCC]);
        }
        #[allow(unreachable_patterns)]
        _ => panic!("expected TunIo::Backend variant"),
    }
}
