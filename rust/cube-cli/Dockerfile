# Build cube-cli without a local Rust toolchain:
#   docker build -t cube-cli rust/cube-cli
#   docker run --rm --network host cube-cli meta
FROM rust:1-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/target/release/cube-cli /usr/local/bin/cube-cli
WORKDIR /workspace
ENTRYPOINT ["cube-cli"]
