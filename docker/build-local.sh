#!/bin/sh
# Local docker build validator. Run before pushing changes that affect
# docker/{server,relay}/* or workspace Cargo.toml / Dockerfile dependencies.
#
# Builds both server and relay images for linux/amd64 (native on linux,
# Linux-VM on macOS — both fast, no QEMU). Smoke-tests entrypoint bootstrap
# of server image to verify CA generation + server.toml render.
#
# Why this exists: CI feedback loop (~1m) is slow when iterating fixes.
# Local build catches Cargo workspace resolve errors, dep edition bumps,
# missing COPY directives etc. in ~3 minutes instead of 5+ CI rounds.

set -eu

cd "$(dirname "$0")/.."

echo "=== Building ghoststream-relay:local (linux/amd64) ==="
docker buildx build --platform linux/amd64 \
    -f docker/relay/Dockerfile \
    -t ghoststream-relay:local \
    --load \
    .

echo
echo "=== Building ghoststream-server:local (linux/amd64) ==="
docker buildx build --platform linux/amd64 \
    -f docker/server/Dockerfile \
    -t ghoststream-server:local \
    --load \
    .

echo
echo "=== Smoke-test: server bootstrap ==="
TEST_DIR="$(mktemp -d -t gs-docker-smoke.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/config"

if ! timeout 5 docker run --rm \
    -e SERVER_NAME=smoke.example.com \
    -v "$TEST_DIR/config:/config" \
    ghoststream-server:local 2>&1 | head -20; then
    # timeout 5 returns 124 on kill, that's expected (server starts then hits TUN).
    :
fi

echo
echo "=== Generated state ==="
ls "$TEST_DIR/config"

echo
test -f "$TEST_DIR/config/ca.crt"     || { echo "FAIL: ca.crt missing";     exit 1; }
test -f "$TEST_DIR/config/server.toml"|| { echo "FAIL: server.toml missing";exit 1; }
test -f "$TEST_DIR/config/clients.json" || { echo "FAIL: clients.json missing"; exit 1; }
grep -q '\[h2\]' "$TEST_DIR/config/server.toml" || { echo "FAIL: [h2] section missing"; exit 1; }

echo "OK — both images build, server bootstrap generates valid state."
echo "Safe to push and trigger CI."
