# OpenPhotos 

**Open Source • Self-Hosted • Privacy-First**  
**Your Photos. Your Keys. Your Album Tree.**

OpenPhotos is a self-hosted photo platform with locked albums (E2EE), nested albums, AI-powered discovery, and resumable uploads.

## What's Included

- Rust server binaries: `openphotos` + TUS sidecar `rustus`
- Static web app: `web-photos`

## Build Non-EE Server (No Installer)

### macOS (native build)

```bash
cargo build --release --no-default-features --bin openphotos
cargo build --release --manifest-path rustus/Cargo.toml --bin rustus
```

Build outputs:

- `target/release/openphotos`
- `rustus/target/release/rustus`

### Linux (Docker cross-build via script)

```bash
DOCKER_IMAGE="${DOCKER_IMAGE:-rust:1-bookworm}" USE_LIBHEIF=0 ./start.sh --build-linux --linux-target x86_64-unknown-linux-gnu
DOCKER_IMAGE="${DOCKER_IMAGE:-rust:1-bookworm}" USE_LIBHEIF=0 ./start.sh --build-linux --linux-target aarch64-unknown-linux-gnu
```

Build outputs:

- `dist/linux/x86_64-unknown-linux-gnu/openphotos`
- `dist/linux/x86_64-unknown-linux-gnu/rustus`
- `dist/linux/aarch64-unknown-linux-gnu/openphotos`
- `dist/linux/aarch64-unknown-linux-gnu/rustus`

### Windows (Docker cross-build via script)

```bash
./start.sh --build-windows --windows-target x86_64-pc-windows-msvc
```

Build outputs:

- `dist/windows/x86_64-pc-windows-msvc/openphotos.exe`
- `dist/windows/x86_64-pc-windows-msvc/rustus.exe`

## Build Web Client 

```bash
./build_static_web.sh
```

Build output:

- `web-photos/out`

