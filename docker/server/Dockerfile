# syntax=docker/dockerfile:1.6

# ─── Builder ──────────────────────────────────────────────────────────────────
FROM rust:1.83-bookworm AS builder

WORKDIR /src

# Системные зависимости для сборки (rustls/ring чистый, openssl-sys не нужен)
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        clang \
        cmake \
    && rm -rf /var/lib/apt/lists/*

# Скопировать только то что нужно для server-сборки.
# crates/client-* и apps/ исключены через .dockerignore, но дублируем для надёжности.
COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY server/ server/

# Сборка только server crate, без всего workspace.
RUN cargo build --release \
        -p phantom-server \
        --bin phantom-server \
        --bin phantom-keygen

# ─── Runtime ──────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# iptables/ip — phantom-server вызывает их сам (sysctl ip_forward + MASQUERADE + FORWARD).
# python3 — для keys.py (управление пользователями через `docker exec`).
# tini — корректный PID 1 + reaping.
RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables \
        iproute2 \
        procps \
        python3-minimal \
        tini \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Установка бинарей
COPY --from=builder /src/target/release/phantom-server /usr/local/bin/phantom-server
COPY --from=builder /src/target/release/phantom-keygen /usr/local/bin/phantom-keygen

# keys.py + alias для docker exec
COPY server/scripts/keys.py /opt/phantom-vpn/keys.py
RUN chmod +x /opt/phantom-vpn/keys.py \
    && ln -s /opt/phantom-vpn/keys.py /usr/local/bin/keys

# Стандартный пример конфига внутри образа — entrypoint скопирует если /config пуст
COPY server/config/server.example.toml /opt/phantom-vpn/server.example.toml

# Entrypoint c self-bootstrap
COPY docker/server/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /config — bind-mount point для state
VOLUME ["/config"]

EXPOSE 443/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
