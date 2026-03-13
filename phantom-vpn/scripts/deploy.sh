#!/bin/bash
# One-click deploy/update for phantom-server on remote host.
#
# Features:
# - Local build on Linux host, remote build fallback on non-Linux
# - Bootstrap empty host (/opt/phantom-vpn + runtime deps)
# - Idempotent systemd setup (phantom-server.service)
# - Config sync policy:
#   * overwrite only if local config/server.toml exists
#   * otherwise upload server.example.toml and create server.toml once
# - Post-deploy health checks + keys.py smoke check
#
# Usage:
#   ./scripts/deploy.sh [user@host] [ssh_key_path] [--dry-run]
#
# Examples:
#   ./scripts/deploy.sh root@89.110.109.128 ~/.ssh/personal
#   ./scripts/deploy.sh vdsina ~/.ssh/personal --dry-run

set -euo pipefail

REMOTE="${1:-root@89.110.109.128}"
SSH_KEY="${2:-$HOME/.ssh/personal}"
DRY_RUN="${3:-}"

REMOTE_DIR="/opt/phantom-vpn"
SERVICE="phantom-server.service"
LEGACY_SERVICE="phantom-vpn.service"
LOCAL_OS="$(uname -s)"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=12)
RSYNC_SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=12"

run_cmd() {
    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

run_remote() {
    local cmd="$1"
    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        echo "[dry-run][remote:$REMOTE] $cmd"
    else
        ssh "${SSH_OPTS[@]}" "$REMOTE" "$cmd"
    fi
}

echo "=== PhantomVPN Deploy: local → $REMOTE ==="
[[ "$DRY_RUN" == "--dry-run" ]] && echo "Mode: DRY RUN (no changes)"
echo "Local OS: $LOCAL_OS"

# ─── Step 1: Build locally ────────────────────────────────────────────────────
LOCAL_BUILD=1
if [[ "$LOCAL_OS" != "Linux" ]]; then
    LOCAL_BUILD=0
fi

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    echo "[1/5] Building release binaries locally..."
    run_cmd "cargo build --release -p phantom-server --bin phantom-server --bin phantom-keygen"
    [[ -f target/release/phantom-server ]] || { echo "Missing target/release/phantom-server"; exit 1; }
    [[ -f target/release/phantom-keygen ]] || { echo "Missing target/release/phantom-keygen"; exit 1; }
else
    echo "[1/5] Local OS is not Linux, using remote build mode..."
fi

[[ -f scripts/keys.py ]] || { echo "Missing scripts/keys.py"; exit 1; }

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    echo "  phantom-server: $(du -sh target/release/phantom-server | cut -f1)"
    echo "  phantom-keygen: $(du -sh target/release/phantom-keygen | cut -f1)"
fi

# ─── Step 2: Bootstrap remote host (idempotent) ──────────────────────────────
echo "[2/5] Preparing remote host..."
run_remote "mkdir -p '$REMOTE_DIR/config'"

run_remote "if command -v apt-get >/dev/null 2>&1; then \
  missing=''; \
  command -v curl >/dev/null 2>&1 || missing=\"\$missing curl\"; \
  command -v ip >/dev/null 2>&1 || missing=\"\$missing iproute2\"; \
  command -v iptables >/dev/null 2>&1 || missing=\"\$missing iptables\"; \
  command -v python3 >/dev/null 2>&1 || missing=\"\$missing python3\"; \
  command -v cc >/dev/null 2>&1 || missing=\"\$missing build-essential\"; \
  command -v pkg-config >/dev/null 2>&1 || missing=\"\$missing pkg-config\"; \
  if [ -n \"\$missing\" ]; then \
    echo \"Installing runtime deps:\$missing\"; \
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \$missing; \
  fi; \
fi"

# ─── Step 3: Sync binaries/scripts/config ────────────────────────────────────
echo "[3/5] Syncing project artifacts..."
if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    run_cmd "rsync -avz --progress -e \"$RSYNC_SSH\" target/release/phantom-server target/release/phantom-keygen scripts/keys.py \"$REMOTE:$REMOTE_DIR/\""
else
    # Remote build mode: sync source and build on server to avoid Exec format mismatch.
    run_remote "mkdir -p '$REMOTE_DIR/src'"
    run_cmd "rsync -avz --delete --progress \
      --exclude '.git' --exclude 'target' --exclude '.cursor' --exclude '.DS_Store' \
      -e \"$RSYNC_SSH\" ./ \"$REMOTE:$REMOTE_DIR/src/\""

    run_remote "if ! command -v rustup >/dev/null 2>&1; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; \
    fi"
    run_remote "source \"\$HOME/.cargo/env\" 2>/dev/null || true; \
      cd '$REMOTE_DIR/src' && \
      cargo build --release -p phantom-server --bin phantom-server --bin phantom-keygen"
    run_remote "cp '$REMOTE_DIR/src/target/release/phantom-server' '$REMOTE_DIR/phantom-server' && \
      cp '$REMOTE_DIR/src/target/release/phantom-keygen' '$REMOTE_DIR/phantom-keygen' && \
      cp '$REMOTE_DIR/src/scripts/keys.py' '$REMOTE_DIR/keys.py'"
fi

# Config policy:
# - if local config/server.toml exists -> overwrite remote server.toml
# - else -> sync server.example.toml; create server.toml only if absent
if [[ -f "config/server.toml" ]]; then
    echo "  Config policy: overwrite remote server.toml from local config/server.toml"
    run_cmd "rsync -avz --progress -e \"$RSYNC_SSH\" config/server.toml \"$REMOTE:$REMOTE_DIR/config/server.toml\""
elif [[ -f "config/server.example.toml" ]]; then
    echo "  Config policy: local server.toml absent; using server.example.toml as bootstrap template"
    run_cmd "rsync -avz --progress -e \"$RSYNC_SSH\" config/server.example.toml \"$REMOTE:$REMOTE_DIR/config/server.example.toml\""
    run_remote "test -f '$REMOTE_DIR/config/server.toml' || cp '$REMOTE_DIR/config/server.example.toml' '$REMOTE_DIR/config/server.toml'"
else
    echo "  [warn] No local config file found (config/server.toml or config/server.example.toml)."
fi

# ─── Step 4: Install/refresh systemd unit ────────────────────────────────────
echo "[4/5] Installing/updating systemd service ($SERVICE)..."
run_remote "if systemctl list-unit-files | grep -q '^$LEGACY_SERVICE'; then \
  systemctl disable --now '$LEGACY_SERVICE' || true; \
  rm -f '/etc/systemd/system/$LEGACY_SERVICE'; \
fi"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run] would install /etc/systemd/system/$SERVICE"
else
    ssh "${SSH_OPTS[@]}" "$REMOTE" "cat > /etc/systemd/system/$SERVICE <<'EOF'
[Unit]
Description=PhantomVPN Server (QUIC/HTTP3 transport)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$REMOTE_DIR
ExecStart=$REMOTE_DIR/phantom-server --config $REMOTE_DIR/config/server.toml --verbose
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF"
fi

run_remote "chmod +x '$REMOTE_DIR/phantom-server' '$REMOTE_DIR/phantom-keygen' '$REMOTE_DIR/keys.py' || true"
run_remote "systemctl daemon-reload && systemctl enable --now '$SERVICE' && systemctl restart '$SERVICE'"

# ─── Step 5: Health checks and key manager smoke check ───────────────────────
echo "[5/5] Running post-deploy checks..."
run_remote "systemctl is-active '$SERVICE' || true"
run_remote "systemctl status '$SERVICE' --no-pager -n 30 || true"

run_remote "port=\$(awk -F= '/^[[:space:]]*listen_addr[[:space:]]*=/{gsub(/[ \"\\047]/, \"\", \$2); split(\$2,a,\":\"); print a[length(a)]; exit}' '$REMOTE_DIR/config/server.toml'); \
  [ -n \"\$port\" ] || port=443; \
  echo \"Detected listen port: \$port\"; \
  ss -lunp | grep -E \":\$port[[:space:]]\" || true"

run_remote "journalctl -u '$SERVICE' -n 50 --no-pager || true"
run_remote "python3 '$REMOTE_DIR/keys.py' --help >/dev/null && echo 'keys.py: OK' || echo 'keys.py: FAILED'"
run_remote "if journalctl -u '$SERVICE' -n 40 --no-pager | grep -q 'Exec format error'; then \
  echo '[error] Exec format error detected. Check build mode and remote architecture.'; \
  exit 1; \
fi"

echo ""
echo "=== Deploy complete ==="
echo "Service: $SERVICE"
echo "Keys management command:"
echo "  ssh -i $SSH_KEY $REMOTE \"python3 $REMOTE_DIR/keys.py --server-config $REMOTE_DIR/config/server.toml --keyring $REMOTE_DIR/config/clients.json\""
