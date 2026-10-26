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
OUT="target/release-server"
LOCAL_BUILD=1
if [[ "$LOCAL_OS" != "Linux" ]]; then
    if command -v cargo-zigbuild >/dev/null 2>&1; then
        # macOS: кросс-сборка через zig под glibc 2.31 (не выше, чем на хостах).
        BUILD="${BUILD/cargo build/cargo zigbuild --target x86_64-unknown-linux-gnu.2.31}"
        OUT="target/x86_64-unknown-linux-gnu/release-server"
    else
        LOCAL_BUILD=0
    fi
fi

if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    echo "[1/5] Building release binary locally..."
    run_cmd "$BUILD"
    if [[ "$DRY_RUN" != "--dry-run" ]]; then
        [[ -f $OUT/phantom-relay ]] || { echo "Missing $OUT/phantom-relay"; exit 1; }
        echo "  phantom-relay: $(du -sh $OUT/phantom-relay | cut -f1)"
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
    run_cmd "rsync -az -e \"$RSYNC_SSH\" $OUT/phantom-relay \"$REMOTE:$REMOTE_DIR/phantom-relay.new\""
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
      install -m 0755 $OUT/phantom-relay '$REMOTE_DIR/phantom-relay.new'"
fi

run_cmd "rsync -az --ignore-existing -e \"$RSYNC_SSH\" server/relay/relay.example.toml \"$REMOTE:$REMOTE_DIR/config/relay.toml\""

# ─── Step 4: Install/refresh systemd unit ────────────────────────────────────
echo "[4/5] Installing systemd unit ($SERVICE)..."
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

# ─── Step 5: Swap binary, restart, verify (rollback on failure) ──────────────
# Как в deploy.sh: прежний бинарь — .prev; реле — единственный вход для всех
# клиентов, поэтому без живого порта сразу откат.
echo "[5/5] Swapping binary, restarting, checking..."
if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run][remote:$REMOTE] swap .new → bin (old → .prev), restart, wait for listen port, rollback on failure"
    exit 0
fi

ssh "${SSH_OPTS[@]}" "$REMOTE" sudo bash -s -- "$REMOTE_DIR" "$SERVICE" <<'REMOTE_EOF'
set -u
dir="$1"; svc="$2"; bin="$dir/phantom-relay"
port=$(awk -F= '/^[[:space:]]*listen_addr[[:space:]]*=/{sub(/#.*/,"",$2); gsub(/[ "\047\t]/,"",$2); n=split($2,a,":"); print a[n]; exit}' "$dir/config/relay.toml")
port="${port:-443}"

# Живо 10 с подряд одним и тем же процессом: crash-loop через Restart=on-failure
# на секунду выглядит active + LISTEN.
healthy() {
    local pid
    for _ in $(seq 1 15); do
        sleep 1
        if systemctl is-active -q "$svc" && ss -Htln "sport = :$port" | grep -q .; then
            pid=$(systemctl show -p MainPID --value "$svc")
            sleep 10
            systemctl is-active -q "$svc" && [ "$(systemctl show -p MainPID --value "$svc")" = "$pid" ]
            return
        fi
    done
    return 1
}

[ -f "$bin" ] && ln -f "$bin" "$bin.prev"
mv -f "$bin.new" "$bin"
systemctl daemon-reload
systemctl enable "$svc" >/dev/null 2>&1
systemctl restart "$svc"

if healthy; then
    echo "OK: $svc active, :$port listening"
    journalctl --namespace=phantom-relay -u "$svc" -n 15 --no-pager || true
    exit 0
fi

echo "[error] после рестарта реле не держит :$port — откат на прежний бинарь" >&2
journalctl --namespace=phantom-relay -u "$svc" -n 40 --no-pager >&2 || true
[ -f "$bin.prev" ] && mv -f "$bin.prev" "$bin"
systemctl restart "$svc"
sleep 2
systemctl is-active "$svc" >&2 || true
exit 1
REMOTE_EOF

echo ""
echo "=== Deploy complete ==="
echo "Service: $SERVICE on $REMOTE"
echo "Config:  $REMOTE_DIR/config/relay.toml (не перезаписывается деплоем)"
echo "Logs:    ssh $REMOTE 'sudo journalctl --namespace=phantom-relay -f'"
