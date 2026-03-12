#!/bin/bash
# Deploy phantom-server binary to remote server via rsync + SSH
# Usage: ./scripts/deploy.sh [user@host] [ssh_key_path]
#
# Example: ./scripts/deploy.sh root@38.180.207.110 ~/.ssh/personal

set -euo pipefail

REMOTE="${1:-root@38.180.207.110}"
SSH_KEY="${2:-$HOME/.ssh/personal}"
REMOTE_DIR="/opt/phantom-vpn"

echo "=== PhantomVPN Deploy: local → $REMOTE ==="

# ─── Build locally (cross-compile for linux-x86_64) ──────────────────────────
echo "[1/3] Building release binary..."
cargo build --release -p phantom-server
echo "  Built: target/release/phantom-server ($(du -sh target/release/phantom-server | cut -f1))"

# ─── Sync to server ───────────────────────────────────────────────────────────
echo "[2/3] Syncing to $REMOTE:$REMOTE_DIR ..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE" "mkdir -p $REMOTE_DIR/config"

rsync -avz --progress \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    target/release/phantom-server \
    target/release/phantom-keygen \
    "$REMOTE:$REMOTE_DIR/"

# Sync config only if it doesn't already have real keys
rsync -avz --progress --ignore-existing \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    config/server.toml \
    "$REMOTE:$REMOTE_DIR/config/"

# ─── Restart service ─────────────────────────────────────────────────────────
echo "[3/3] Restarting phantom-vpn service..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE" \
    "systemctl restart phantom-vpn 2>/dev/null || \
     $REMOTE_DIR/phantom-server --config $REMOTE_DIR/config/server.toml &"

echo ""
echo "=== Deploy complete! ==="
echo "Check status: ssh -i $SSH_KEY $REMOTE 'systemctl status phantom-vpn || journalctl -n 50 -u phantom-vpn'"
