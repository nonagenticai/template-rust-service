# template-rust-service image.
#
# Both stages are debian:13-slim from Docker Hub, so builder and runtime share one glibc and
# `docker build .` works on a fresh clone with no registry credentials. The builder installs
# the pinned toolchain with rustup.
# RUST_TOOLCHAIN must equal rust-toolchain.toml.
ARG RUST_TOOLCHAIN=1.99.0

FROM debian:13-slim AS build
ARG RUST_TOOLCHAIN
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# cmake/perl: aws-lc-sys (rustls' default crypto provider, via sqlx tls-rustls).
# git: Cargo fetches the `[patch.crates-io]` git dependency in Cargo.toml.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl git perl pkg-config \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
    && rustc --version

WORKDIR /src
COPY . .
# sqlx::migrate! embeds migrations/ into the binary, so the runtime image needs no SQL files.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked \
    && install -D -m 0755 target/release/template-rust-service /out/service

FROM debian:13-slim AS runtime
# ca-certificates: outbound https (rustls-native-certs). curl: the HEALTHCHECK.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 65532 app \
    && useradd --system --uid 65532 --gid 65532 --home-dir /var/lib/app --create-home app
COPY --from=build /out/service /usr/local/bin/template-rust-service
# No port is baked in: BIND_ADDR (host:port) and DATABASE_URL are required at runtime. The
# image publishes no port; the deployment decides which one to expose.
ENV RUST_LOG=info
WORKDIR /var/lib/app
USER 65532:65532
# Liveness of the HTTP server on whatever port BIND_ADDR names.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["sh", "-c", "curl -fsS -o /dev/null \"http://127.0.0.1:${BIND_ADDR##*:}/health\""]
ENTRYPOINT ["/usr/local/bin/template-rust-service"]
