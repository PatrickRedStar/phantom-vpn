#!/bin/bash
# One-click deploy/update for phantom-server on remote host.
#
# Features:
# - Local build on Linux host, remote build fallback on non-Linux
# - Bootstrap empty host (/opt/phantom-vpn + runtime deps)
# - Idempotent systemd setup (phantom-server.service, sandboxed)
# - Config sync policy:
#   * overwrite only if local server/config/server.toml exists
#   * otherwise upload server.example.toml and create server.toml once
# - Сервис останавливается только на время замены бинаря; прежний бинарь и unit
#   хранятся как .prev (и server.toml тоже). Если после рестарта порт [h2] не
#   слушается или нет NAT-правила (при заданном wan_iface) — откат.
#
# Usage (из любого каталога репо):
#   server/scripts/deploy.sh [user@host] [ssh_key_path] [--dry-run]
#
# Examples:
#   server/scripts/deploy.sh vdsina ~/.ssh/personal
#   server/scripts/deploy.sh vdsina ~/.ssh/personal --dry-run

set -euo pipefail

cd "$(dirname "$0")/../.."

REMOTE="${1:-vdsina}"
SSH_KEY="${2:-$HOME/.ssh/personal}"
DRY_RUN="${3:-}"

REMOTE_DIR="/opt/phantom-vpn"
SERVICE="phantom-server.service"
LEGACY_SERVICE="phantom-vpn.service"
LOCAL_OS="$(uname -s)"
BUILD="cargo build --locked --profile release-server -p phantom-server --bin phantom-server --bin phantom-keygen"

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

[[ -f server/scripts/keys.py ]] || { echo "Missing server/scripts/keys.py"; exit 1; }

# ─── Step 1: Build locally ────────────────────────────────────────────────────
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
    echo "[1/5] Building release binaries locally..."
    run_cmd "$BUILD"
    if [[ "$DRY_RUN" != "--dry-run" ]]; then
        for b in phantom-server phantom-keygen; do
            [[ -f "$OUT/$b" ]] || { echo "Missing $OUT/$b"; exit 1; }
            echo "  $b: $(du -sh "$OUT/$b" | cut -f1)"
        done
    fi
else
    echo "[1/5] Local OS is not Linux, using remote build mode..."
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

# ─── Step 3: Ship new binaries next to the running ones (*.new) ──────────────
# Сервис пока работает: остановка — только в шаге 5, вплотную к замене.
echo "[3/5] Syncing project artifacts..."
if [[ "$LOCAL_BUILD" -eq 1 ]]; then
    run_cmd "rsync -az -e \"$RSYNC_SSH\" $OUT/phantom-server \"$REMOTE:$REMOTE_DIR/phantom-server.new\""
    run_cmd "rsync -az -e \"$RSYNC_SSH\" $OUT/phantom-keygen \"$REMOTE:$REMOTE_DIR/phantom-keygen.new\""
else
    # Remote build mode: sync source and build on server to avoid Exec format mismatch.
    # Тот же набор, что COPY в docker/server/Dockerfile: cargo читает манифесты
    # всех членов workspace, даже когда собирается один -p.
    run_remote "mkdir -p '$REMOTE_DIR/src'"
    run_cmd "rsync -az --delete --relative \
      --exclude 'target' --exclude '.DS_Store' \
      -e \"$RSYNC_SSH\" Cargo.toml Cargo.lock crates server apps/linux apps/openwrt \"$REMOTE:$REMOTE_DIR/src/\""

    run_remote "if ! command -v rustup >/dev/null 2>&1; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; \
    fi"
    run_remote "source \"\$HOME/.cargo/env\" 2>/dev/null || true; \
      cd '$REMOTE_DIR/src' && $BUILD"
    run_remote "install -m 0755 '$REMOTE_DIR/src/target/release-server/phantom-server' '$REMOTE_DIR/phantom-server.new' && \
      install -m 0755 '$REMOTE_DIR/src/target/release-server/phantom-keygen' '$REMOTE_DIR/phantom-keygen.new'"
fi
run_cmd "rsync -az -e \"$RSYNC_SSH\" server/scripts/keys.py \"$REMOTE:$REMOTE_DIR/keys.py\""

# Прежний server.toml — для отката в шаге 5.
run_remote "f='$REMOTE_DIR/config/server.toml'; [ -f \"\$f\" ] && cp -p \"\$f\" \"\$f.prev\" || true"

# Config policy:
# - if local server/config/server.toml exists -> overwrite remote server.toml
# - else -> sync server.example.toml; create server.toml only if absent
if [[ -f "server/config/server.toml" ]]; then
    echo "  Config policy: overwrite remote server.toml from local server/config/server.toml"
    run_cmd "rsync -az -e \"$RSYNC_SSH\" server/config/server.toml \"$REMOTE:$REMOTE_DIR/config/server.toml\""
else
    echo "  Config policy: local server.toml absent; using server.example.toml as bootstrap template"
    run_cmd "rsync -az -e \"$RSYNC_SSH\" server/config/server.example.toml \"$REMOTE:$REMOTE_DIR/config/server.example.toml\""
    run_remote "test -f '$REMOTE_DIR/config/server.toml' || cp '$REMOTE_DIR/config/server.example.toml' '$REMOTE_DIR/config/server.toml'"
fi
# Явный hard_timeout_secs (наследство шаблона install.py: 86400) возвращает
# суточный обрыв всех сессий — дефолт сервера 0, строку убираем (.prev выше).
run_remote "f='$REMOTE_DIR/config/server.toml'; grep -Eq '^[[:space:]]*hard_timeout_secs[[:space:]]*=' \"\$f\" && \
  sed -i -E '/^[[:space:]]*hard_timeout_secs[[:space:]]*=/d' \"\$f\" && echo '  server.toml: hard_timeout_secs removed' || true"

# ─── Step 4: Install/refresh systemd unit ────────────────────────────────────
echo "[4/5] Installing/updating systemd service ($SERVICE)..."
run_remote "if systemctl list-unit-files | grep -q '^$LEGACY_SERVICE'; then \
  systemctl disable --now '$LEGACY_SERVICE' || true; \
  rm -f '/etc/systemd/system/$LEGACY_SERVICE'; \
fi"

# Sandbox. Сервер сам создаёт TUN, вызывает iptables/sysctl (ip_forward) и пишет
# clients.json, admin-server.* и clients/<name>/ в каталоге конфига — поэтому
# без PrivateDevices/ProtectKernelTunables/ProtectKernelModules, а /run открыт
# под /run/xtables.lock. Прежний unit остаётся как .prev для отката.
UNIT="[Unit]
Description=PhantomVPN Server (H2/TLS transport)
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

NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ProtectSystem=strict
ReadWritePaths=$REMOTE_DIR/config /run
ProtectHome=yes
PrivateTmp=yes
ProtectControlGroups=yes
ProtectKernelLogs=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run] would install /etc/systemd/system/$SERVICE"
else
    ssh "${SSH_OPTS[@]}" "$REMOTE" "f=/etc/systemd/system/$SERVICE; \
      [ -f \$f ] && cp -p \$f \$f.prev; \
      cat > \$f.new && mv -f \$f.new \$f" <<<"$UNIT"
fi

# ─── Step 5: Swap binaries, restart, verify (rollback on failure) ────────────
echo "[5/5] Swapping binaries and restarting..."
if [[ "$DRY_RUN" == "--dry-run" ]]; then
    echo "[dry-run][remote:$REMOTE] swap *.new → bin (old → .prev), restart, wait for [h2] port, rollback on failure"
    exit 0
fi

ssh "${SSH_OPTS[@]}" "$REMOTE" bash -s -- "$REMOTE_DIR" "$SERVICE" <<'REMOTE_EOF'
set -u
dir="$1"; svc="$2"; unit="/etc/systemd/system/$svc"

# Порт транспорта — [h2].listen_addr (дефолт сервера 0.0.0.0:9443).
cfg="$dir/config/server.toml"
port=$(awk '/^\[/{h=($0 ~ /^\[h2\][[:space:]]*(#.*)?$/)} h && /^[[:space:]]*listen_addr[[:space:]]*=/{sub(/#.*/,""); gsub(/["\047 \t]/,""); n=split($0,a,":"); print a[n]; exit}' "$cfg")
port="${port:-9443}"

# NAT сервер ставит сам и ошибки iptables только логирует — проверяем правило.
nat_ok() {
    ! grep -Eq '^[[:space:]]*wan_iface[[:space:]]*=' "$cfg" ||
        iptables -t nat -S POSTROUTING 2>/dev/null | grep -q phantom-vpn-
}

for b in phantom-server phantom-keygen; do
    [ -f "$dir/$b" ] && ln -f "$dir/$b" "$dir/$b.prev"
    mv -f "$dir/$b.new" "$dir/$b"
done
systemctl daemon-reload
systemctl enable "$svc" >/dev/null 2>&1
systemctl restart "$svc"

# Живо 10 с подряд одним и тем же процессом: crash-loop через Restart=on-failure
# на секунду выглядит active + LISTEN + NAT.
ok=0
for _ in $(seq 1 15); do
    sleep 1
    if systemctl is-active -q "$svc" && ss -Htln "sport = :$port" | grep -q . && nat_ok; then
        pid=$(systemctl show -p MainPID --value "$svc")
        sleep 10
        systemctl is-active -q "$svc" && [ "$(systemctl show -p MainPID --value "$svc")" = "$pid" ] && ok=1
        break
    fi
done

if [ "$ok" = 1 ]; then
    echo "OK: $svc active, :$port listening, NAT ok"
    systemctl status "$svc" --no-pager -n 15 || true
    exit 0
fi

echo "[error] после рестарта :$port не слушается, нет NAT-правила или сервис перезапускается — откат на прежние бинарь, unit и server.toml" >&2
journalctl -u "$svc" -n 40 --no-pager >&2 || true
for b in phantom-server phantom-keygen; do
    [ -f "$dir/$b.prev" ] && mv -f "$dir/$b.prev" "$dir/$b"
done
[ -f "$unit.prev" ] && mv -f "$unit.prev" "$unit"
[ -f "$cfg.prev" ] && cp -p "$cfg.prev" "$cfg"
systemctl daemon-reload
systemctl restart "$svc"
sleep 2
systemctl is-active "$svc" >&2 || true
exit 1
REMOTE_EOF

run_remote "python3 '$REMOTE_DIR/keys.py' --help >/dev/null && echo 'keys.py: OK' || echo 'keys.py: FAILED'"

echo ""
echo "=== Deploy complete ==="
echo "Service: $SERVICE"
echo "Keys management command:"
echo "  ssh -i $SSH_KEY $REMOTE \"python3 $REMOTE_DIR/keys.py --server-config $REMOTE_DIR/config/server.toml --keyring $REMOTE_DIR/config/clients.json\""
