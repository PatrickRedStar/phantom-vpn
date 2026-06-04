# syntax=docker/dockerfile:1.6

# ─── Builder ──────────────────────────────────────────────────────────────────
FROM rust:1.83-bookworm AS builder

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        clang \
        cmake \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY server/ server/

RUN cargo build --release -p phantom-relay --bin phantom-relay

# ─── Runtime ──────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/phantom-relay /usr/local/bin/phantom-relay

# Пример конфига как seed для первого запуска
COPY server/relay/relay.example.toml /opt/phantom-relay/relay.example.toml

COPY docker/relay/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# /config — bind-mount с relay.toml и опционально LE cert/key
VOLUME ["/config"]

# Не root: relay не нуждается в caps
RUN useradd -r -u 10001 -g nogroup relay
USER relay

EXPOSE 443/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
