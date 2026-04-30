# OpenPhotos 

[**Try The Demo**](https://demo.openphotos.ca)

**Open Source • Self-Hosted • Privacy-First**  
**Your Photos. Your Keys. Your Album Tree.**

OpenPhotos is a self-hosted photo platform with locked albums (E2EE), nested albums, AI-powered discovery, and resumable uploads.

**Links:** [Demo](https://demo.openphotos.ca) • [Docs](https://openphotos.ca/docs/index.html) • [Download](https://openphotos.ca/download/index.html) • [GitHub Releases](https://github.com/openphotos-ca/openphotos/releases)

## 1. Demo

Access the demo here: [https://demo.openphotos.ca](https://demo.openphotos.ca)

For the mobile app, use `https://demo.openphotos.ca` for the Server Endpoint URL.
Download the iOS app from the App Store: [OpenPhotos](https://apps.apple.com/us/app/openphotos/id6759428882)

### Login Credentials

| Email | Password |
| --- | --- |
| `demo@openphotos.ca` | `demo` |

## 2. Quick Start

This is the shortest path to a working OpenPhotos server for evaluation or a first home install.
If you plan to build from source, skip to
[Build from source code](#build-from-source-code).

### Requirements

- Use a computer, Raspberry Pi, or NAS that can stay online while clients upload and index media.
- A good starting point is at least 4 GB of RAM.
- Supported host options include Windows 64-bit, macOS on Apple Silicon or Intel, 64-bit Linux, or
  any device that can run Docker and Docker Compose.
- If phones or other computers need to reach the server on your LAN, make sure port `3003` is
  reachable from those devices.

### Option A: Use an installer

Download the latest release assets from
[GitHub Releases](https://github.com/openphotos-ca/openphotos/releases).

- Windows: use the `setup.exe` asset.
- macOS: use the `.pkg` asset.
- Linux: use the one-line installer on common glibc + systemd distributions. It detects `amd64` vs
  `arm64` and starts installation. If a matching Linux tarball is in the current directory or beside
  a local `install_linux.sh`, the installer uses that local file instead of downloading the tarball
  from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/scripts/install_linux.sh | sudo env "PATH=$PATH" bash
```

- Linux release assets include small wrapper scripts, smaller online tarballs, and larger bundled
  tarballs. The bundled `openphotos-linux_<version>_<arch>.tar.gz` files include the standard
  models. The online `openphotos-linux-online_<version>_<arch>.tar.gz` installers reuse
  `openphotos_models.zip` from the same folder when present, or download models from GitHub during
  setup. With the one-line installer, run the command from the folder containing the local tarball
  and model ZIP.
- iOS client: install [OpenPhotos on the App Store](https://apps.apple.com/us/app/openphotos/id6759428882).
- Other downloads are also listed on the OpenPhotos download page:
  [https://openphotos.ca/download/index.html](https://openphotos.ca/download/index.html).

Native installers provision or reuse models during setup when needed, so the first install can take
longer than later reinstalls.

Linux uninstall uses the installed helper. The default keeps data and model folders; `--purge`
removes data, config, logs, and models too:

```bash
sudo openphotos-uninstall
sudo openphotos-uninstall --purge
```

### Option B: Use Docker

Create a working directory:

```bash
mkdir openphotos
cd openphotos
```

For Intel / AMD CPUs:

```bash
curl -L -o compose.yaml https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/docker/compose.yaml
curl -L -o .env https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/docker/openphotos.env.amd64
sudo docker compose up -d
```

For ARM64 CPUs:

```bash
curl -L -o compose.yaml https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/docker/compose.yaml
curl -L -o .env https://raw.githubusercontent.com/openphotos-ca/openphotos/refs/heads/main/docker/openphotos.env.arm64
sudo docker compose up -d
```

The default `.env` is fine for a first test install. Review storage paths before importing a full
library.

### Start and verify

If you use an installer, the server usually starts automatically after installation. If you use
Docker, `sudo docker compose up -d` starts it.

Verify the server health endpoint:

```bash
curl http://localhost:3003/ping
```

Open the web app:

```text
http://localhost:3003/
```

From another device on the same network, replace `localhost` with the server's LAN IP address:

```text
http://<server-ip>:3003/
```

On a phone or tablet, do not use `localhost`; it points to the phone itself. Use the same reachable
server URL you use from the browser, such as `http://<server-ip>:3003/`.

Back up a small album first so you can confirm upload speed, metadata, and thumbnail generation
before importing a full library.

## 3. Build from source code

The source tree includes:

- Rust server binaries: `openphotos` + TUS sidecar `rustus`
- Static web app: `web-photos`
- Android app source: `android-java`
- Android release helper: `scripts/build_android_installer.sh`
- Docker / NAS deployment files: `Dockerfile`, `compose.yaml`, `docker/`, `docs/docker.md`
- Docker build helper for local OSS / EE images: `scripts/build_docker_image.sh`
- GitHub Actions workflow for OSS-only multi-arch GHCR publishing: `.github/workflows/docker-release.yml`

### Build Server (No Installer)

#### Download Models (Before Build)

GitHub source uploads do not include large model binaries. Download runtime models first:

```bash
./download_models.sh
```

This populates required runtime files under `models/` (CLIP + face models).

#### macOS (native build)

```bash
cargo build --release --no-default-features --bin openphotos
cargo build --release --manifest-path rustus/Cargo.toml --bin rustus
```

Build outputs:

- `target/release/openphotos`
- `rustus/target/release/rustus`

#### Linux (Docker cross-build via script)

```bash
DOCKER_IMAGE="${DOCKER_IMAGE:-rust:1.90-bookworm}" USE_LIBHEIF=0 ./start.sh --build-linux --linux-target x86_64-unknown-linux-gnu
DOCKER_IMAGE="${DOCKER_IMAGE:-rust:1.90-bookworm}" USE_LIBHEIF=0 ./start.sh --build-linux --linux-target aarch64-unknown-linux-gnu
```

Build outputs:

- `dist/linux/x86_64-unknown-linux-gnu/openphotos`
- `dist/linux/x86_64-unknown-linux-gnu/rustus`
- `dist/linux/aarch64-unknown-linux-gnu/openphotos`
- `dist/linux/aarch64-unknown-linux-gnu/rustus`

#### Windows (Docker cross-build via script)

```bash
./start.sh --build-windows --windows-target x86_64-pc-windows-msvc
```

Build outputs:

- `dist/windows/x86_64-pc-windows-msvc/openphotos.exe`
- `dist/windows/x86_64-pc-windows-msvc/rustus.exe`

#### Build Web Client

```bash
./build_static_web.sh
```

Build output:

- `web-photos/out`

#### Docker / NAS Deployment

Use the public OSS container image:

```bash
cp docker/openphotos.env.example .env
docker compose up -d
```

Build the OSS image locally from source:

```bash
scripts/prepare_linux_ffmpeg_bundle.sh --arch amd64,arm64 --output-dir dist/linux-ffmpeg
scripts/build_docker_image.sh --oss --platform linux/amd64
OPENPHOTOS_IMAGE=openphotos:local docker compose up -d
```

Build the enterprise image locally from the private source tree:

```bash
scripts/prepare_linux_ffmpeg_bundle.sh --arch amd64,arm64 --output-dir dist/linux-ffmpeg
scripts/build_docker_image.sh --ee --platform linux/amd64
OPENPHOTOS_IMAGE=openphotos-ee:local docker compose up -d
```

For ARM NAS devices, switch the build platform to `linux/arm64`.

Local Docker builds use the same Linux ffmpeg bundle root as the Linux installers:

```text
dist/linux-ffmpeg
```

If you keep those bundles somewhere else, pass:

```bash
scripts/build_docker_image.sh --oss --platform linux/amd64 --ffmpeg-bundle-dir /path/to/linux-ffmpeg
```

The public GitHub export intentionally omits the real `ee/` source tree. Enterprise Docker images cannot be built from the public repo and are never published to GitHub Packages.

The Compose deployment stores all persistent app data under `/data` in the container. Change `OPENPHOTOS_DATA_MOUNT` in `.env` to use a NAS bind mount instead of the default named volume.

Additional Docker / NAS notes are in:

- `docs/docker.md`

#### Publish OSS Docker Image To GHCR

The exported repo includes a GitHub Actions workflow that publishes the OSS multi-arch image to `ghcr.io/openphotos-ca/openphotos` when you push a `v*.*.*` tag.

Example:

```bash
git tag v0.4.0
git push origin v0.4.0
```

After the first successful push, set the GHCR package visibility to public if you want users to run `docker compose pull` without logging in.

That workflow prepares `dist/linux-ffmpeg` before `docker buildx`, so the published Docker image uses the same bundled Linux `ffmpeg` / `ffprobe` model as local Docker and Linux installer builds.

Enterprise Docker images are local-build only. Use the private source tree with:

```bash
scripts/build_docker_image.sh --ee --platform linux/amd64
```

If you build the EE image on another machine, transfer it with:

```bash
docker save openphotos-ee:local | gzip > openphotos-ee-local.tar.gz
gunzip -c openphotos-ee-local.tar.gz | docker load
```

#### Build Android App

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

### Start Servers (macOS, Linux, Windows)

Run these from the repository root after models are downloaded.

#### macOS

```bash
./start.sh
```

#### Linux

```bash
./start.sh
```

#### Windows (PowerShell)

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
