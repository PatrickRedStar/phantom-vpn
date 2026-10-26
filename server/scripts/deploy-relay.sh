#!/bin/bash
# One-click deploy/update for phantom-relay on a remote host.
#
# Mirrors deploy.sh (which deploys phantom-server). Builds the binary
# locally if the host OS is Linux, otherwise rsyncs sources and builds
# on the remote host (avoids Exec format mismatch).
#
# Usage (из любого каталога репо):
#   server/scripts/deploy-relay.sh [user@host] [ssh_key_path] [--dry-run]
#
# Examples:
#   server/scripts/deploy-relay.sh vps_balancer ~/.ssh/bot        # боевое реле (balancer)
#   server/scripts/deploy-relay.sh spongebob@89.169.175.55 ~/.ssh/personal --dry-run
#
# Config policy: существующий /opt/phantom-relay/config/relay.toml на хосте
# НИКОГДА не перезаписывается — у каждого реле свой конфиг (balancer слушает
# 127.0.0.1:5443 за nginx, .55 — 0.0.0.0:443). На чистый хост кладётся
# server/relay/relay.example.toml как relay.toml — его надо отредактировать и
# `systemctl restart phantom-relay.service`. server/relay/relay.toml в репо —
# конфиг реле .55, на другие хосты его не льём.

set -euo pipefail

cd "$(dirname "$0")/../.."

REMOTE="${1:-vps_balancer}"
SSH_KEY="${2:-$HOME/.ssh/bot}"
DRY_RUN="${3:-}"

REMOTE_DIR="/opt/phantom-relay"
SERVICE="phantom-relay.service"
LOCAL_OS="$(uname -s)"
BUILD="cargo build --locked --profile release-server -p phantom-relay --bin phantom-relay"

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
    run_cmd "$BUILD"
    if [[ "$DRY_RUN" != "--dry-run" ]]; then
        [[ -f target/release-server/phantom-relay ]] || { echo "Missing target/release-server/phantom-relay"; exit 1; }
        echo "  phantom-relay: $(du -sh target/release-server/phantom-relay | cut -f1)"
    fi
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

# ─── Step 3: Ship new binary next to the running one (*.new) + config ────────
# Реле пока работает: остановка — только в шаге 4, вплотную к замене бинаря.
echo "[3/5] Syncing artifacts..."
if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    run_cmd "rsync -az -e \"$RSYNC_SSH\" target/release-server/phantom-relay \"$REMOTE:$REMOTE_DIR/phantom-relay.new\""
else
    run_remote "mkdir -p '$REMOTE_DIR/src'"
    # Тот же набор, что COPY в docker/relay/Dockerfile: сборка идёт в workspace
    # с корневым Cargo.lock (--locked) и профилем release-server.
    run_cmd "rsync -az --delete --relative \
      --exclude 'target' --exclude '.DS_Store' \
      -e \"$RSYNC_SSH\" Cargo.toml Cargo.lock crates server apps/linux apps/openwrt \"$REMOTE:$REMOTE_DIR/src/\""

    run_remote "if ! command -v rustup >/dev/null 2>&1 && [ ! -x \"\$HOME/.cargo/bin/cargo\" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; \
    fi"
    run_remote "source \"\$HOME/.cargo/env\" 2>/dev/null || true; \
      cd '$REMOTE_DIR/src' && $BUILD && \
      install -m 0755 target/release-server/phantom-relay '$REMOTE_DIR/phantom-relay.new'"
fi

run_cmd "rsync -az --ignore-existing -e \"$RSYNC_SSH\" server/relay/relay.example.toml \"$REMOTE:$REMOTE_DIR/config/relay.toml\""

# ─── Step 4: Install/refresh systemd unit, swap binary, restart ──────────────
echo "[4/5] Installing systemd unit ($SERVICE) and swapping binary..."
if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run] would install /etc/systemd/system/$SERVICE + journald@phantom-relay.conf"
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
ExecStart=$REMOTE_DIR/phantom-relay --config $REMOTE_DIR/config/relay.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

# Allow binding privileged ports without running as root if needed
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Свой журнал с хранением ≤2 суток: в логах реле адреса клиентов, а общий
# journald хоста (на balancer — ещё xray/3x-ui) не трогаем.
# Смотреть: journalctl --namespace=phantom-relay -f
LogNamespace=phantom-relay

[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/systemd/journald@phantom-relay.conf >/dev/null <<'EOF'
[Journal]
MaxRetentionSec=1day
MaxFileSec=1day
EOF"
fi

run_remote "sudo systemctl daemon-reload && sudo systemctl enable '$SERVICE' >/dev/null 2>&1; \
  sudo mv -f '$REMOTE_DIR/phantom-relay.new' '$REMOTE_DIR/phantom-relay' && \
  sudo systemctl restart '$SERVICE'"

# ─── Step 5: Health check ────────────────────────────────────────────────────
echo "[5/5] Post-deploy checks..."
sleep 1
run_remote "systemctl is-active '$SERVICE' || true"
run_remote "sudo journalctl --namespace=phantom-relay -u '$SERVICE' -n 30 --no-pager || true"

run_remote "port=\$(awk -F= '/^[[:space:]]*listen_addr[[:space:]]*=/{gsub(/[ \"\\047]/, \"\", \$2); split(\$2,a,\":\"); print a[length(a)]; exit}' '$REMOTE_DIR/config/relay.toml'); \
  [ -n \"\$port\" ] || port=443; \
  echo \"Detected listen port: \$port\"; \
  ss -tlnp 2>/dev/null | grep -E \":\$port \" || sudo ss -tlnp | grep -E \":\$port \" || true"

echo ""
echo "=== Deploy complete ==="
echo "Service: $SERVICE on $REMOTE"
echo "Config:  $REMOTE_DIR/config/relay.toml (не перезаписывается деплоем)"
echo "Logs:    ssh $REMOTE 'sudo journalctl --namespace=phantom-relay -f'"
