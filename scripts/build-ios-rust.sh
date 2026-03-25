#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR/crates/client-ios"

echo "[iOS Rust] ensure targets exist:"
echo "  rustup target add aarch64-apple-ios aarch64-apple-ios-sim"

echo "[iOS Rust] build device staticlib"
cargo build --release --target aarch64-apple-ios

echo "[iOS Rust] build simulator staticlib"
cargo build --release --target aarch64-apple-ios-sim

echo "[iOS Rust] done"
echo "device:    target/aarch64-apple-ios/release/libphantom_ios.a"
echo "simulator: target/aarch64-apple-ios-sim/release/libphantom_ios.a"
