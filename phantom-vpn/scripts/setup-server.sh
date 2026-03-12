#!/bin/bash
# PhantomVPN Server Setup Script
# Run on the server as root: bash scripts/setup-server.sh

set -euo pipefail

echo "=== PhantomVPN Server Setup ==="

# ─── System deps ──────────────────────────────────────────────────────────────
echo "[1/5] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
    curl build-essential pkg-config \
    iproute2 iptables \
    clang llvm libelf-dev \
    linux-headers-$(uname -r) 2>/dev/null || \
    apt-get install -y -qq linux-headers-generic

# ─── Rust ─────────────────────────────────────────────────────────────────────
echo "[2/5] Installing Rust toolchain..."
if ! command -v rustup &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --profile minimal --default-toolchain stable
    source "$HOME/.cargo/env"
else
    echo "  Rust already installed: $(rustc --version)"
fi

# ─── Build ────────────────────────────────────────────────────────────────────
echo "[3/5] Building phantom-server and phantom-keygen..."
source "$HOME/.cargo/env" 2>/dev/null || true
cd "$(dirname "$0")/.."
cargo build --release -p phantom-server 2>&1 | tail -5
echo "  Binary: $(ls -lh target/release/phantom-server)"

# ─── Key generation ───────────────────────────────────────────────────────────
echo "[4/5] Generating keys (if config not yet filled)..."
if grep -q "REPLACE_ME" config/server.toml 2>/dev/null; then
    echo ""
    echo "  === IMPORTANT: Copy these keys to config/server.toml and config/client.toml ==="
    echo ""
    ./target/release/phantom-keygen
    echo ""
else
    echo "  Keys already configured in config/server.toml"
fi

# ─── systemd service ──────────────────────────────────────────────────────────
echo "[5/5] Installing systemd service..."
INSTALL_DIR="/opt/phantom-vpn"
mkdir -p "$INSTALL_DIR"
cp target/release/phantom-server "$INSTALL_DIR/"
cp -r config "$INSTALL_DIR/"

cat > /etc/systemd/system/phantom-vpn.service << 'EOF'
[Unit]
Description=PhantomVPN Server (WebRTC masquerade)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/phantom-vpn
ExecStart=/opt/phantom-vpn/phantom-server --config /opt/phantom-vpn/config/server.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo ""
echo "=== Setup complete! ==="
echo ""
echo "Next steps:"
echo "  1. Edit /opt/phantom-vpn/config/server.toml — fill in your keys"
echo "  2. systemctl enable --now phantom-vpn"
echo "  3. systemctl status phantom-vpn"
echo "  4. journalctl -fu phantom-vpn"
