# OpenPhotos 

[**Try The Demo**](https://demo.openphotos.ca)

**Open Source • Self-Hosted • Privacy-First**  
**Your Photos. Your Keys. Your Album Tree.**

OpenPhotos is a self-hosted photo platform with locked albums (E2EE), nested albums, AI-powered discovery, and resumable uploads.

## Demo

Access the demo here: [https://demo.openphotos.ca](https://demo.openphotos.ca)

For the mobile app, use `https://demo.openphotos.ca` for the Server Endpoint URL.
Download the iOS app from the App Store: [OpenPhotos](https://apps.apple.com/us/app/openphotos/id6759428882)

### Login Credentials

| Email | Password |
| --- | --- |
| `demo@openphotos.ca` | `demo` |

## What's Included

- Rust server binaries: `openphotos` + TUS sidecar `rustus`
- Static web app: `web-photos`
- Android app source: `android-java`
- Android release helper: `scripts/build_android_installer.sh`
- Docker / NAS deployment files: `Dockerfile`, `compose.yaml`, `docker/`, `docs/docker.md`
- GitHub Actions workflow for multi-arch GHCR publishing: `.github/workflows/docker-release.yml`

## Download Models (Before Build)

GitHub source uploads do not include large model binaries. Download runtime models first:

```bash
./download_models.sh
```

This populates required runtime files under `models/` (CLIP + face models).

## Build Server (No Installer)

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

## Docker / NAS Deployment

Build and run the official single-container Docker image locally:

```bash
cp docker/openphotos.env.example .env
docker buildx build --load --platform linux/amd64 -t openphotos:local .
OPENPHOTOS_IMAGE=openphotos:local docker compose up -d
```

For ARM NAS devices, switch the build platform to `linux/arm64`.

The Compose deployment stores all persistent app data under `/data` in the container. Change `OPENPHOTOS_DATA_MOUNT` in `.env` to use a NAS bind mount instead of the default named volume.

Additional Docker / NAS notes are in:

- `docs/docker.md`

## Publish Docker Image To GHCR

The exported repo includes a GitHub Actions workflow that publishes multi-arch images to `ghcr.io/openphotos-ca/openphotos` when you push a `v*.*.*` tag.

Example:

```bash
git tag v0.4.0
git push origin v0.4.0
```

After the first successful push, set the GHCR package visibility to public if you want users to run `docker compose pull` without logging in.

## Build Android App

The exported source includes the Android project under `android-java`.

Before building, make sure the Android SDK is discoverable either by:

- setting `ANDROID_HOME` or `ANDROID_SDK_ROOT`, or
- creating `android-java/local.properties` with `sdk.dir=/absolute/path/to/Android/sdk`

The export intentionally does not include `android-java/local.properties` because that file is machine-specific.

Build a debug APK:

```bash
cd android-java
./gradlew :app:assembleDebug
```

Build output:

- `android-java/app/build/outputs/apk/debug/app-debug.apk`

Optional release APK helper:

```bash
scripts/build_android_installer.sh
```

The helper tries `ANDROID_HOME` / `ANDROID_SDK_ROOT` first, then common Android SDK install locations, and writes `android-java/local.properties` automatically when needed.
It always produces an installable signed release APK.
If `ANDROID_KEYSTORE_*` env vars are not provided, it auto-generates and reuses:

```bash
android-java/.openphotos-signing/openphotos-auto-release.jks
```

Back up that keystore file. Future app updates must use the same signing key.

Build output:

- `dist/android-packages/openphotos-android-release.apk`

## Start Servers (macOS, Linux, Windows)

Run these from the repository root after models are downloaded.

### macOS

```bash
./start.sh
```

### Linux

```bash
./start.sh
```

### Windows (PowerShell)

1. Build binaries:

```powershell
cargo build --release --locked --no-default-features
cargo build --release --locked --manifest-path rustus/Cargo.toml --bin rustus
```

2. Start Rustus (Terminal 1):

```powershell
$env:RUSTUS_SERVER_HOST="127.0.0.1"
$env:RUSTUS_SERVER_PORT="1081"
$env:RUSTUS_URL="/files"
$env:RUSTUS_DATA_DIR="$PWD\data\uploads"
$env:RUSTUS_INFO_DIR="$PWD\data\uploads"
$env:RUSTUS_TUS_EXTENSIONS="creation,termination,creation-with-upload,creation-defer-length,concatenation,checksum"
$env:RUSTUS_MAX_BODY_SIZE="52428800"
$env:RUSTUS_HOOKS="pre-create,post-finish"
$env:RUSTUS_HOOKS_FORMAT="v2"
$env:RUSTUS_HOOKS_HTTP_URLS="http://127.0.0.1:3003/api/upload/hooks"
$env:RUSTUS_HOOKS_HTTP_PROXY_HEADERS="Authorization,X-Request-ID,Cookie"
$env:RUSTUS_LOG_LEVEL="INFO"
New-Item -ItemType Directory -Force -Path "$PWD\data\uploads" | Out-Null
.\rustus\target\release\rustus.exe
```

3. Start OpenPhotos (Terminal 2):

```powershell
.\target\release\openphotos.exe --model-path models --database data --log-level info
```

Health checks:

- `http://127.0.0.1:3003/ping` (OpenPhotos API)
- `http://127.0.0.1:1081/health` (Rustus)
