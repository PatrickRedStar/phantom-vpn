#!/bin/bash
# One-click deploy/update for phantom-relay on a remote host.
#
# Mirrors deploy.sh (which deploys phantom-server). Builds the binary
# locally if the host OS is Linux, otherwise rsyncs sources and builds
# on the remote host (avoids Exec format mismatch).
#
# Usage:
#   ./scripts/deploy-relay.sh [user@host] [ssh_key_path] [--dry-run]
#
# Examples:
#   ./scripts/deploy-relay.sh root@193.187.95.128 ~/.ssh/personal
#   ./scripts/deploy-relay.sh vps_balancer ~/.ssh/personal --dry-run
#
# Config policy:
#   - if local server/relay/relay.toml exists -> overwrite remote relay.toml
#   - else upload server/relay/relay.example.toml; create relay.toml only if absent
#
# After successful deploy, edit /opt/phantom-relay/config/relay.toml on the
# host and `systemctl restart phantom-relay.service` if you changed it.

set -euo pipefail

REMOTE="${1:-vps_balancer}"
SSH_KEY="${2:-$HOME/.ssh/bot}"
DRY_RUN="${3:-}"

REMOTE_DIR="/opt/phantom-relay"
SERVICE="phantom-relay.service"
LOCAL_OS="$(uname -s)"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=12)
RSYNC_SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=12"

run_cmd() {
    if [[ "$DRY_RUN" == "--dry-run" ]]; then echo "[dry-run] $*"; else eval "$@"; fi
}
run_remote() {
    local cmd="$1"
    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        echo "[dry-run][remote:$REMOTE] $cmd"
    else
        ssh "${SSH_OPTS[@]}" "$REMOTE" "$cmd"
    fi
}

echo "=== PhantomVPN Relay Deploy: local → $REMOTE ==="
[[ "$DRY_RUN" == "--dry-run" ]] && echo "Mode: DRY RUN (no changes)"
echo "Local OS: $LOCAL_OS"

# ─── Step 1: Build (local on Linux, otherwise remote) ────────────────────────
LOCAL_BUILD=1
[[ "$LOCAL_OS" != "Linux" ]] && LOCAL_BUILD=0

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    echo "[1/5] Building release binary locally..."
    run_cmd "cargo build --release -p phantom-relay --bin phantom-relay"
    [[ -f target/release/phantom-relay ]] || { echo "Missing target/release/phantom-relay"; exit 1; }
    echo "  phantom-relay: $(du -sh target/release/phantom-relay | cut -f1)"
else
    echo "[1/5] Local OS is not Linux, will build on remote host..."
fi

# ─── Step 2: Bootstrap remote host ───────────────────────────────────────────
echo "[2/5] Preparing remote host..."
run_remote "sudo mkdir -p '$REMOTE_DIR/config' && sudo chown -R \$(id -u):\$(id -g) '$REMOTE_DIR'"

run_remote "if command -v apt-get >/dev/null 2>&1; then \
  missing=''; \
  command -v cc >/dev/null 2>&1 || missing=\"\$missing build-essential\"; \
  command -v pkg-config >/dev/null 2>&1 || missing=\"\$missing pkg-config\"; \
  if [ -n \"\$missing\" ]; then \
    echo \"Installing build deps:\$missing\"; \
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \$missing; \
  fi; \
fi"

# ─── Step 3: Sync binary / source + config ───────────────────────────────────
echo "[3/5] Syncing artifacts..."
run_remote "sudo systemctl stop '$SERVICE' || true; sudo pkill -x phantom-relay || true"

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    run_cmd "rsync -avz --progress -e \"$RSYNC_SSH\" target/release/phantom-relay \"$REMOTE:$REMOTE_DIR/\""
else
    run_remote "mkdir -p '$REMOTE_DIR/src'"
    # Whitelist sync: relay only depends on its own crate + workspace root files,
    # and uses `--manifest-path server/relay/Cargo.toml` to bypass the workspace
    # so we don't have to ship the rest of the repo (apps/, crates/, etc).
    run_cmd "rsync -avz --delete --progress \
      --include 'server/' \
      --include 'server/relay/' \
      --include 'server/relay/**' \
      --exclude '*' \
      -e \"$RSYNC_SSH\" ./ \"$REMOTE:$REMOTE_DIR/src/\""

    run_remote "if ! command -v rustup >/dev/null 2>&1 && [ ! -x \"\$HOME/.cargo/bin/cargo\" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; \
    fi"
    run_remote "source \"\$HOME/.cargo/env\" 2>/dev/null || true; \
      cd '$REMOTE_DIR/src/server/relay' && \
      cargo build --release --bin phantom-relay && \
      install -m 0755 target/release/phantom-relay '$REMOTE_DIR/phantom-relay.new' && \
      mv -f '$REMOTE_DIR/phantom-relay.new' '$REMOTE_DIR/phantom-relay'"
fi

# Config policy (same as deploy.sh)
if [[ -f "server/relay/relay.toml" ]]; then
    echo "  Config: overwrite remote relay.toml from local server/relay/relay.toml"
    run_cmd "rsync -avz --progress -e \"$RSYNC_SSH\" server/relay/relay.toml \"$REMOTE:$REMOTE_DIR/config/relay.toml\""
elif [[ -f "server/relay/relay.example.toml" ]]; then
    echo "  Config: local relay.toml absent; using relay.example.toml as bootstrap"
    run_cmd "rsync -avz --progress -e \"$RSYNC_SSH\" server/relay/relay.example.toml \"$REMOTE:$REMOTE_DIR/config/relay.example.toml\""
    run_remote "test -f '$REMOTE_DIR/config/relay.toml' || sudo cp '$REMOTE_DIR/config/relay.example.toml' '$REMOTE_DIR/config/relay.toml'"
else
    echo "  [warn] no local relay config found"
fi

# ─── Step 4: Install/refresh systemd unit ────────────────────────────────────
echo "[4/5] Installing systemd unit ($SERVICE)..."
if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run] would install /etc/systemd/system/$SERVICE"
else
    ssh "${SSH_OPTS[@]}" "$REMOTE" "sudo tee /etc/systemd/system/$SERVICE >/dev/null <<'EOF'
[Unit]
Description=PhantomVPN Relay (SNI passthrough)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$REMOTE_DIR
ExecStart=$REMOTE_DIR/phantom-relay --config $REMOTE_DIR/config/relay.toml --verbose
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

# Allow binding privileged ports without running as root if needed
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF"
fi

run_remote "sudo chmod +x '$REMOTE_DIR/phantom-relay' || true"
run_remote "sudo systemctl daemon-reload && sudo systemctl enable --now '$SERVICE' && sudo systemctl restart '$SERVICE'"

# ─── Step 5: Health check ────────────────────────────────────────────────────
echo "[5/5] Post-deploy checks..."
sleep 1
run_remote "systemctl is-active '$SERVICE' || true"
run_remote "sudo journalctl -u '$SERVICE' -n 30 --no-pager || true"

run_remote "port=\$(awk -F= '/^[[:space:]]*listen_addr[[:space:]]*=/{gsub(/[ \"\\047]/, \"\", \$2); split(\$2,a,\":\"); print a[length(a)]; exit}' '$REMOTE_DIR/config/relay.toml'); \
  [ -n \"\$port\" ] || port=443; \
  echo \"Detected listen port: \$port\"; \
  ss -tlnp 2>/dev/null | grep -E \":\$port \" || sudo ss -tlnp | grep -E \":\$port \" || true"

echo ""
echo "=== Deploy complete ==="
echo "Service: $SERVICE on $REMOTE"
echo "Config:  $REMOTE_DIR/config/relay.toml"
echo "Logs:    ssh $REMOTE 'sudo journalctl -u $SERVICE -f'"
