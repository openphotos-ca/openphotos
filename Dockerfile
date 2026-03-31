# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM node:20-bookworm-slim AS web-builder
WORKDIR /work/web-photos

ENV NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_ENABLE_EE=0

COPY web-photos/package.json web-photos/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY web-photos ./
RUN NEXT_PUBLIC_API_URL=/api NEXT_PUBLIC_ENABLE_EE=0 npm run build

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS model-builder
WORKDIR /work

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY download_models.sh ./
COPY models/oiv7_classes.txt ./models/oiv7_classes.txt
RUN ./download_models.sh /work/models

# rustus currently fails on newer floating `rust:1` images due to a transitive
# dependency/compiler interaction; pin to the repo's known-good toolchain.
FROM --platform=$TARGETPLATFORM rust:1.90-bookworm AS rust-builder
WORKDIR /work

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      nasm \
      perl \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock build.rs ./
COPY src ./src
COPY rustus ./rustus
COPY face-normalizer ./face-normalizer

RUN cargo build --release --locked --no-default-features --bin openphotos \
    && cargo build --release --locked --manifest-path rustus/Cargo.toml --bin rustus

FROM debian:bookworm-slim

ARG TARGETARCH

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      ffmpeg \
      tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/openphotos

ENV SERVER_ADDRESS=0.0.0.0:3003 \
    MODEL_PATH=/opt/openphotos/models \
    DATABASE_PATH=/data \
    LIBRARY_DIR=/data/library \
    LOG_LEVEL=info \
    EMBEDDINGS_BACKEND=duckdb \
    OCR_ENABLED=false \
    OPENPHOTOS_INSTALL_MODE=docker \
    OPENPHOTOS_UPDATE_ENABLED=false \
    OPENPHOTOS_INSTALL_ARCH=${TARGETARCH} \
    RUSTUS_ORIGIN=http://127.0.0.1:1081 \
    RUSTUS_STORAGE=file-storage \
    RUSTUS_SERVER_HOST=127.0.0.1 \
    RUSTUS_SERVER_PORT=1081 \
    RUSTUS_URL=/files \
    RUSTUS_DATA_DIR=/data/uploads \
    RUSTUS_INFO_DIR=/data/uploads \
    RUSTUS_TUS_EXTENSIONS=creation,termination,creation-with-upload,creation-defer-length,concatenation,checksum \
    RUSTUS_HOOKS=pre-create,post-finish \
    RUSTUS_HOOKS_FORMAT=v2 \
    RUSTUS_HOOKS_HTTP_URLS=http://127.0.0.1:3003/api/upload/hooks \
    RUSTUS_HOOKS_HTTP_PROXY_HEADERS=Authorization,X-Request-ID,Cookie \
    RUSTUS_LOG_LEVEL=INFO \
    RUSTUS_MAX_BODY_SIZE=16777216

COPY --from=model-builder /work/models /opt/openphotos/models
COPY --from=web-builder /work/web-photos/out /opt/openphotos/web-photos/out
COPY --from=rust-builder /work/target/release/openphotos /usr/local/bin/openphotos
COPY --from=rust-builder /work/rustus/target/release/rustus /usr/local/bin/rustus
COPY docker/entrypoint.sh /usr/local/bin/openphotos-container-entrypoint

RUN chmod 0755 /usr/local/bin/openphotos-container-entrypoint \
    && mkdir -p /data /opt/openphotos/web-photos

VOLUME ["/data"]
EXPOSE 3003

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=5 \
  CMD curl -fsS http://127.0.0.1:3003/ping || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/openphotos-container-entrypoint"]
