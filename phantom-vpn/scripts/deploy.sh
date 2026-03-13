#!/bin/bash
# Deploy phantom-server binary to remote server via rsync + SSH
# Usage: ./scripts/deploy.sh [user@host] [ssh_key_path]
#
# Example: ./scripts/deploy.sh root@89.110.109.128 ~/.ssh/personal

set -euo pipefail

REMOTE="${1:-root@89.110.109.128}"
SSH_KEY="${2:-$HOME/.ssh/personal}"
REMOTE_DIR="/opt/phantom-vpn"
SERVICE="phantom-server"

echo "=== PhantomVPN Deploy: local → $REMOTE ==="

# ─── Build locally ────────────────────────────────────────────────────────────
echo "[1/3] Building release binary..."
cargo build --release -p phantom-server -p phantom-keygen
echo "  phantom-server: $(du -sh target/release/phantom-server | cut -f1)"
echo "  phantom-keygen: $(du -sh target/release/phantom-keygen | cut -f1)"

# ─── Sync to server ───────────────────────────────────────────────────────────
echo "[2/3] Syncing to $REMOTE:$REMOTE_DIR ..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE" "mkdir -p $REMOTE_DIR/config"

# Sync binaries
rsync -avz --progress \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    target/release/phantom-server \
    target/release/phantom-keygen \
    "$REMOTE:$REMOTE_DIR/"

# Sync config only if it doesn't already have real keys (--ignore-existing)
rsync -avz --progress --ignore-existing \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    config/server.toml \
    "$REMOTE:$REMOTE_DIR/config/"

# Sync key manager script
rsync -avz --progress \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    scripts/keys.py \
    "$REMOTE:$REMOTE_DIR/"

# ─── Restart service ─────────────────────────────────────────────────────────
echo "[3/3] Restarting $SERVICE service..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE" \
    "systemctl restart $SERVICE 2>/dev/null || \
     $REMOTE_DIR/phantom-server --config $REMOTE_DIR/config/server.toml &"

echo ""
echo "=== Deploy complete! ==="
echo "Статус сервиса:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE" \
    "systemctl is-active $SERVICE && systemctl status $SERVICE --no-pager -n 5 || true"
echo ""
echo "Управление ключами:"
echo "  ssh -i $SSH_KEY $REMOTE 'python3 $REMOTE_DIR/keys.py'"
