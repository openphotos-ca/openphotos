#!/bin/bash
# Start All Services for OpenPhotos Photo Management System
# This script starts both the OpenPhotos service (backend) and Web-Photos client (frontend)

set -e

# Args / flags
BACKEND="duckdb"   # duckdb | postgres
PG_INIT="0"
BUILD_LINUX="0"
LINUX_TARGET=""
LINUX_OUT_DIR="dist/linux"
BUILD_WINDOWS="0"
WINDOWS_TARGET=""
WINDOWS_OUT_DIR="dist/windows"
DOCKER_IMAGE="${DOCKER_IMAGE:-rust:1-bookworm}"

usage() {
  echo "Usage: $0 [--db duckdb|postgres] [--pg-init] [--build-linux ...]" >&2
  echo "  --db, --backend   Select embeddings/face backend (default: duckdb)" >&2
  echo "  --pg-init         Initialize Postgres schema before starting (reads POSTGRES_* env)" >&2
  echo "  --build-linux     Build Linux release binaries (openphotos + rustus) in Docker and exit" >&2
  echo "  --linux-target    Rust target triple (default: x86_64-unknown-linux-gnu)" >&2
  echo "  --linux-out       Output directory (default: dist/linux)" >&2
  echo "  --build-windows   Build Windows 64-bit release binaries (openphotos.exe + rustus.exe) in Docker and exit" >&2
  echo "  --windows-target  Rust target triple (default: x86_64-pc-windows-msvc)" >&2
  echo "  --windows-out     Output directory (default: dist/windows)" >&2
  echo "  DOCKER_IMAGE      Builder image (default: rust:1-bookworm)" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --db=*|--backend=*) BACKEND="${1#*=}"; shift ;;
    --db|--backend)
      shift
      [ $# -gt 0 ] || usage
      BACKEND="$1"; shift ;;
    --postgres) BACKEND="postgres"; shift ;;
    --duckdb) BACKEND="duckdb"; shift ;;
    --pg-init) PG_INIT="1"; shift ;;
    --build-linux) BUILD_LINUX="1"; shift ;;
    --linux-target)
      shift
      [ $# -gt 0 ] || usage
      LINUX_TARGET="$1"; shift ;;
    --linux-out)
      shift
      [ $# -gt 0 ] || usage
      LINUX_OUT_DIR="$1"; shift ;;
    --build-windows) BUILD_WINDOWS="1"; shift ;;
    --windows-target)
      shift
      [ $# -gt 0 ] || usage
      WINDOWS_TARGET="$1"; shift ;;
    --windows-out)
      shift
      [ $# -gt 0 ] || usage
      WINDOWS_OUT_DIR="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

# Build Linux release binaries using Docker on macOS.
# Produces:
#   - ${LINUX_OUT_DIR}/${target}/openphotos
#   - ${LINUX_OUT_DIR}/${target}/rustus
build_linux_release() {
  local target="${LINUX_TARGET:-x86_64-unknown-linux-gnu}"
  local repo_root
  repo_root="$(cd "$(dirname "$0")" && pwd)"

  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found. Install Docker Desktop (or a compatible docker CLI) and retry." >&2
    exit 1
  fi

  # Share host Cargo caches with the container to avoid re-downloading the crate index/deps on every run.
  # IMPORTANT: do not mount the full CARGO_HOME (it would shadow /usr/local/cargo/bin inside the image).
  local cargo_cache_root="${CARGO_CACHE_DIR:-$HOME/.cargo}"
  local cargo_registry_cache="${cargo_cache_root}/registry"
  local cargo_git_cache="${cargo_cache_root}/git"
  mkdir -p "${cargo_registry_cache}" "${cargo_git_cache}"

  local docker_platform=""
  case "${target}" in
    x86_64-unknown-linux-gnu|x86_64-unknown-linux-musl) docker_platform="linux/amd64" ;;
    aarch64-unknown-linux-gnu|aarch64-unknown-linux-musl) docker_platform="linux/arm64" ;;
    *) docker_platform="" ;;
  esac

  # Isolate Linux build artifacts by target + builder image to avoid reusing
  # stale build-script binaries compiled against a different glibc.
  local docker_image_key=""
  docker_image_key="$(printf '%s' "${DOCKER_IMAGE}" | tr '/:@.-' '_')"
  local cargo_target_dir="/work/target-linux/${target}/${docker_image_key}"

  local features_args=()
  # Default to disabling libheif for Linux builds: Debian/Ubuntu repos often ship an older
  # libheif than `libheif-sys` requires, and the server can fall back to ffmpeg for HEIC.
  local use_libheif="${USE_LIBHEIF:-0}"
  local libheif_build_from_source="${LIBHEIF_BUILD_FROM_SOURCE:-1}"
  local libheif_version="${LIBHEIF_VERSION:-1.17.6}"
  if [ "${use_libheif}" = "1" ]; then
    features_args+=("--features" "libheif_ffi")
  else
    echo "Building without libheif FFI (HEIC decode will fallback to ffmpeg)" >&2
  fi
  if [ "${ENABLE_EE:-0}" = "1" ]; then
    features_args+=("--features" "ee")
  fi

  mkdir -p "${repo_root}/${LINUX_OUT_DIR}/${target}"

  echo "Building Linux binary via Docker:"
  echo "  Image:  ${DOCKER_IMAGE}"
  echo "  Target: ${target}"
  if [ -n "${docker_platform}" ]; then
    echo "  Docker: --platform=${docker_platform}"
  fi
  echo "  Out:    ${LINUX_OUT_DIR}/${target}/openphotos"
  echo

  # For common GNU targets, the stock toolchain is enough. Keep extra packages minimal.
  # If you enable USE_LIBHEIF=1, install libheif headers so libheif-sys can link.
  local extra_apt=()
  extra_apt+=("build-essential" "pkg-config" "cmake" "perl" "ca-certificates")
  # Needed by `rav1e` (pulled in via AVIF support in the `image` crate) on x86_64.
  if [ "${docker_platform}" = "linux/amd64" ]; then
    extra_apt+=("nasm")
  fi
  if [ "${use_libheif}" = "1" ]; then
    extra_apt+=("libheif-dev" "libde265-dev" "libjpeg-dev" "libpng-dev" "libwebp-dev" "curl")
  fi

  local platform_args=()
  if [ -n "${docker_platform}" ]; then
    platform_args+=(--platform "${docker_platform}")
  fi

  local cache_mounts=(
    -v "${cargo_registry_cache}:/usr/local/cargo/registry"
    -v "${cargo_git_cache}:/usr/local/cargo/git"
  )

  docker run --rm "${platform_args[@]}" \
    -v "${repo_root}:/work" \
    "${cache_mounts[@]}" \
    -w /work \
    -e CARGO_TARGET_DIR="${cargo_target_dir}" \
    "${DOCKER_IMAGE}" \
    bash -c "
      set -euo pipefail
      export CARGO_HTTP_MULTIPLEXING=\${CARGO_HTTP_MULTIPLEXING:-false}
      apt-get update >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${extra_apt[*]} >/dev/null
      if [ '${use_libheif}' = '1' ]; then
        if ! pkg-config --exists 'libheif >= 1.16' 2>/dev/null; then
          if [ '${libheif_build_from_source}' = '1' ]; then
            echo 'libheif-dev is too old; building libheif from source (v${libheif_version})...' >&2
            curl -fsSL -o /tmp/libheif.tar.gz \
              'https://github.com/strukturag/libheif/releases/download/v${libheif_version}/libheif-${libheif_version}.tar.gz'
            tar -xzf /tmp/libheif.tar.gz -C /tmp
            cmake -S /tmp/libheif-${libheif_version} -B /tmp/libheif-build \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/usr/local \
              -DBUILD_SHARED_LIBS=ON \
              -DWITH_EXAMPLES=OFF
            cmake --build /tmp/libheif-build --parallel
            cmake --install /tmp/libheif-build
            ldconfig || true
          fi
          if ! pkg-config --exists 'libheif >= 1.16' 2>/dev/null; then
            echo 'ERROR: no usable libheif >= 1.16 found for libheif_ffi build.' >&2
            echo 'Try a builder image that has libheif >= 1.16 and is ABI-compatible with your deploy host.' >&2
            echo 'Fix: rerun with USE_LIBHEIF=0 to build without libheif (uses ffmpeg fallback for HEIC).' >&2
            exit 3
          fi
        fi
      fi
      if command -v rustup >/dev/null 2>&1; then
        rustup target add '${target}' >/dev/null || true
      fi
      host_triple=\"\$(rustc -vV | sed -n 's/^host: //p' || true)\"
      bin_dir='${cargo_target_dir}/release'
      target_args=()
      if [[ -z \"\$host_triple\" || \"\$host_triple\" != \"${target}\" ]]; then
        target_args=(--target '${target}')
        bin_dir='${cargo_target_dir}/${target}/release'
      fi

      cargo build --release --locked --no-default-features --bin openphotos \"\${target_args[@]}\" ${features_args[*]}
      cargo build --release --locked --manifest-path rustus/Cargo.toml --bin rustus \"\${target_args[@]}\"

      install -m 0755 \"\${bin_dir}/openphotos\" \"/work/${LINUX_OUT_DIR}/${target}/openphotos\"
      install -m 0755 \"\${bin_dir}/rustus\" \"/work/${LINUX_OUT_DIR}/${target}/rustus\"
      if [ '${use_libheif}' = '1' ]; then
        bundle_dir='/work/dist/linux-libheif/${target}/lib'
        mkdir -p \"\${bundle_dir}\"
        # Export libheif runtime closure for Linux installer packaging.
        declare -A copied=()
        copy_lib_with_deps() {
          local lib_path=\"\$1\"
          [ -e \"\$lib_path\" ] || return 0
          local real_path
          real_path=\"\$(readlink -f \"\$lib_path\" 2>/dev/null || echo \"\$lib_path\")\"
          [ -e \"\$real_path\" ] || return 0
          if [ -n \"\${copied[\$real_path]:-}\" ]; then
            return 0
          fi
          copied[\$real_path]=1
          cp -a \"\$real_path\" \"\${bundle_dir}/\" 2>/dev/null || true
          if [ \"\$lib_path\" != \"\$real_path\" ]; then
            cp -a \"\$lib_path\" \"\${bundle_dir}/\" 2>/dev/null || true
          fi
          while IFS= read -r dep; do
            case \"\$dep\" in
              /lib/*/ld-linux-*.so.*|/lib64/ld-linux-*.so.*) continue ;;
              /lib/*/libc.so.*|/usr/lib/*/libc.so.*) continue ;;
              /lib/*/libm.so.*|/usr/lib/*/libm.so.*) continue ;;
              /lib/*/libpthread.so.*|/usr/lib/*/libpthread.so.*) continue ;;
              /lib/*/librt.so.*|/usr/lib/*/librt.so.*) continue ;;
              /lib/*/libdl.so.*|/usr/lib/*/libdl.so.*) continue ;;
            esac
            copy_lib_with_deps \"\$dep\"
          done < <(ldd \"\$real_path\" 2>/dev/null | awk '/=> \\/[^ ]+/ { print \$3 }')
        }

        libdir=\"\$(pkg-config --variable=libdir libheif 2>/dev/null || true)\"
        for candidate in \"\$libdir\"/libheif.so* /usr/local/lib/libheif.so* /usr/lib/*/libheif.so*; do
          [ -e \"\$candidate\" ] || continue
          copy_lib_with_deps \"\$candidate\"
        done
        # Include these explicitly because they are a common runtime requirement.
        for candidate in /usr/lib/*/libwebp.so* /usr/lib/*/libsharpyuv.so* /usr/local/lib/libwebp.so* /usr/local/lib/libsharpyuv.so*; do
          [ -e \"\$candidate\" ] || continue
          cp -a \"\$candidate\" \"\${bundle_dir}/\" 2>/dev/null || true
        done
        echo \"Bundled libheif runtime libs into \${bundle_dir}\"
      fi
      echo 'Built: ${LINUX_OUT_DIR}/${target}/openphotos'
      echo 'Built: ${LINUX_OUT_DIR}/${target}/rustus'
    "
}

if [ "${BUILD_LINUX}" = "1" ]; then
  build_linux_release
  exit 0
fi

# Build Windows release binaries (x86_64-pc-windows-msvc) using Docker on macOS/Linux.
# Produces:
#   - ${WINDOWS_OUT_DIR}/${target}/openphotos.exe
#   - ${WINDOWS_OUT_DIR}/${target}/rustus.exe
build_windows_release() {
  local target="${WINDOWS_TARGET:-x86_64-pc-windows-msvc}"
  local repo_root
  repo_root="$(cd "$(dirname "$0")" && pwd)"

  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found. Install Docker Desktop (or a compatible docker CLI) and retry." >&2
    exit 1
  fi

  # Windows cross-compile is done via MSVC target using cargo-xwin.
  # This avoids the ONNX Runtime limitation on windows-gnu and produces a .exe artifact.
  mkdir -p "${repo_root}/${WINDOWS_OUT_DIR}/${target}"

  echo "Building Windows binaries via Docker:"
  echo "  Image:  ${DOCKER_IMAGE}"
  echo "  Target: ${target}"
  echo "  Docker: --platform=linux/amd64"
  echo "  Out:    ${WINDOWS_OUT_DIR}/${target}/openphotos.exe"
  echo "          ${WINDOWS_OUT_DIR}/${target}/rustus.exe"
  echo

  # Share host Cargo caches with the container to avoid re-downloading the crate index/deps.
  local cargo_cache_root="${CARGO_CACHE_DIR:-$HOME/.cargo}"
  local cargo_registry_cache="${cargo_cache_root}/registry"
  local cargo_git_cache="${cargo_cache_root}/git"
  mkdir -p "${cargo_registry_cache}" "${cargo_git_cache}"

  # Share host caches for cargo-xwin (Windows SDK/CRT) and ort (ONNX Runtime prebuilt binaries).
  local host_cache_root="${CACHE_DIR:-$HOME/.cache}"
  local cargo_xwin_cache="${host_cache_root}/cargo-xwin"
  local ort_cache="${host_cache_root}/ort.pyke.io"
  mkdir -p "${cargo_xwin_cache}" "${ort_cache}"

  local cache_mounts=(
    -v "${cargo_registry_cache}:/usr/local/cargo/registry"
    -v "${cargo_git_cache}:/usr/local/cargo/git"
    -v "${cargo_xwin_cache}:/root/.cache/cargo-xwin"
    -v "${ort_cache}:/root/.cache/ort.pyke.io"
  )

  docker run --rm --platform linux/amd64 \
    -v "${repo_root}:/work" \
    "${cache_mounts[@]}" \
    -w /work \
    -e CARGO_TARGET_DIR=/work/target-win \
    "${DOCKER_IMAGE}" \
    bash -c "
      set -euo pipefail
      export CARGO_HTTP_MULTIPLEXING=\${CARGO_HTTP_MULTIPLEXING:-false}
      target_triple='${target}'

      if [[ '${target}' == *-pc-windows-gnu ]]; then
        echo 'ERROR: windows-gnu target is not supported by ONNX Runtime prebuilt binaries used by ort/ort-sys.' >&2
        echo 'Use --windows-target x86_64-pc-windows-msvc instead.' >&2
        exit 2
      fi

      apt-get update >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential pkg-config cmake perl ca-certificates \
        clang lld llvm \
        nasm curl unzip ninja-build >/dev/null

      if command -v rustup >/dev/null 2>&1; then
        rustup target add '${target}' >/dev/null || true
      fi

      if ! command -v cargo-xwin >/dev/null 2>&1; then
        cargo install cargo-xwin --locked
      fi

      # Pre-cache Windows SDK/CRT to stabilize builds and allow us to patch mixed-case .lib names.
      xwin_arch='x86_64'
      case \"\${target_triple}\" in
        x86_64-*) xwin_arch='x86_64' ;;
        aarch64-*) xwin_arch='aarch64' ;;
      esac
      cargo xwin cache xwin --xwin-arch \"\${xwin_arch}\" >/dev/null

      # Some Windows .lib files are uppercased in the SDK (e.g. PATHCCH.lib), but lld-link is case-sensitive on Linux.
      # Ensure a correctly-cased copy is available on the library search path.
      extra_lib_dir=\"/work/target-win/win-extra-libs/\${target_triple}\"
      mkdir -p \"\${extra_lib_dir}\"
      um_lib_dir=\"/root/.cache/cargo-xwin/xwin/sdk/lib/um/\${xwin_arch}\"
      if [ ! -f \"\${extra_lib_dir}/PathCch.lib\" ]; then
        if [ -f \"\${um_lib_dir}/PathCch.lib\" ]; then
          cp -f \"\${um_lib_dir}/PathCch.lib\" \"\${extra_lib_dir}/PathCch.lib\"
        elif [ -f \"\${um_lib_dir}/PATHCCH.lib\" ]; then
          cp -f \"\${um_lib_dir}/PATHCCH.lib\" \"\${extra_lib_dir}/PathCch.lib\"
        elif [ -f \"\${um_lib_dir}/pathcch.lib\" ]; then
          cp -f \"\${um_lib_dir}/pathcch.lib\" \"\${extra_lib_dir}/PathCch.lib\"
        else
          echo 'ERROR: PathCch.lib not found in cargo-xwin SDK cache.' >&2
          echo \"Checked: \${um_lib_dir}\" >&2
          exit 4
        fi
      fi

      # DuckDB: link against a prebuilt Windows package (MSVC).
      # Default version matches the currently pinned duckdb/libduckdb-sys series in Cargo.lock.
      duck_ver=\"\${DUCKDB_WIN_VERSION:-1.3.2}\"
      duck_url=\"https://github.com/duckdb/duckdb/releases/download/v\${duck_ver}/libduckdb-windows-amd64.zip\"
      duck_dir=\"/work/target-win/duckdb-\${duck_ver}-\${target_triple}\"
      mkdir -p \"\${duck_dir}\"
      if [ ! -f \"\${duck_dir}/duckdb.lib\" ]; then
        echo \"Downloading DuckDB Windows library v\${duck_ver}...\"
        curl -fsSL \"\${duck_url}\" -o /tmp/duckdb.zip
        unzip -oq /tmp/duckdb.zip -d \"\${duck_dir}\"
      fi
      export DUCKDB_LIB_DIR=\"\${duck_dir}\"
      export DUCKDB_INCLUDE_DIR=\"\${duck_dir}\"

      # ONNX Runtime: use an explicit install dir to avoid ort-sys' downloaded-binaries path on Windows,
      # which currently forces linking against DirectML.lib (often missing in cross environments).
      ort_ver=\"\${ORT_WIN_VERSION:-1.22.0}\"
      ort_url=\"\${ORT_WIN_URL:-https://cdn.pyke.io/0/pyke:ort-rs/ms@\${ort_ver}/x86_64-pc-windows-msvc.tgz}\"
      ort_dir=\"/work/target-win/onnxruntime-\${ort_ver}-\${target_triple}\"
      if [ ! -f \"\${ort_dir}/onnxruntime/lib/onnxruntime.lib\" ]; then
        echo \"Downloading ONNX Runtime v\${ort_ver} (Windows MSVC)...\"
        rm -rf \"\${ort_dir}\"
        mkdir -p \"\${ort_dir}\"
        curl -fsSL \"\${ort_url}\" -o /tmp/ort.tgz
        tar -xzf /tmp/ort.tgz -C \"\${ort_dir}\"
      fi
      export ORT_LIB_LOCATION=\"\${ort_dir}/onnxruntime\"
      export ORT_PREFER_DYNAMIC_LINK=1
      export ORT_SKIP_DOWNLOAD=1

      # Some vendored C deps (e.g. libwebp) include SSSE3/SSE4.1 codepaths. When cross-compiling
      # with clang-cl, set a reasonable baseline CPU so required intrinsics are enabled.
      # Override with WIN_TARGET_CPU if you need a different baseline.
      export TARGET_CPU=\"\${WIN_TARGET_CPU:-haswell}\"

      export RUSTFLAGS=\"\${RUSTFLAGS:-} -L native=\${extra_lib_dir}\"
      cargo xwin build --release --no-default-features --bin openphotos --target '${target}'
      # Build rustus without default features for Windows to avoid rdkafka/cpp toolchain
      # requirements in the cross-build container.
      cargo xwin build --release --manifest-path rustus/Cargo.toml --no-default-features --bin rustus --target '${target}'
      bin_dir='/work/target-win/${target}/release'
      install -m 0755 \"\${bin_dir}/openphotos.exe\" \"/work/${WINDOWS_OUT_DIR}/${target}/openphotos.exe\"
      install -m 0755 \"\${bin_dir}/rustus.exe\" \"/work/${WINDOWS_OUT_DIR}/${target}/rustus.exe\"
      # Ship runtime DLLs alongside the executable.
      if [ -f \"\${duck_dir}/duckdb.dll\" ]; then
        install -m 0644 \"\${duck_dir}/duckdb.dll\" \"/work/${WINDOWS_OUT_DIR}/${target}/duckdb.dll\"
      fi
      if [ -d \"\${ORT_LIB_LOCATION}/lib\" ]; then
        shopt -s nullglob
        for ort_dll in \"\${ORT_LIB_LOCATION}/lib\"/*.dll; do
          if [ -f \"\${ort_dll}\" ]; then
            install -m 0644 \"\${ort_dll}\" \"/work/${WINDOWS_OUT_DIR}/${target}/\$(basename \"\${ort_dll}\")\"
          fi
        done
      fi
      shopt -s nullglob
      for dll in \"\${bin_dir}\"/*.dll; do
        # Some build scripts may leave behind dangling absolute symlinks from previous Docker runs.
        # Only copy real files (or valid symlinks).
        if [ -f \"\${dll}\" ]; then
          install -m 0644 \"\${dll}\" \"/work/${WINDOWS_OUT_DIR}/${target}/\$(basename \"\${dll}\")\"
        fi
      done
      echo 'Built: ${WINDOWS_OUT_DIR}/${target}/openphotos.exe'
      echo 'Built: ${WINDOWS_OUT_DIR}/${target}/rustus.exe'
    "
}

if [ "${BUILD_WINDOWS}" = "1" ]; then
  build_windows_release
  exit 0
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Starting OpenPhotos Photo Management System${NC}"
echo -e "${CYAN}════════════════════════════════════════════${NC}"

# Function to check if port is in use
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 0  # Port is in use
    else
        return 1  # Port is free
    fi
}

# Function to cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}🛑 Shutting down all services...${NC}"
    
    # Kill OpenPhotos service
    if [ ! -z "$ALBUMBUD_PID" ]; then
        kill $ALBUMBUD_PID 2>/dev/null || true
        echo -e "${GREEN}✅ OpenPhotos service stopped${NC}"
    fi
    
    # Kill Next.js dev server
    if [ ! -z "$NEXT_PID" ]; then
        kill $NEXT_PID 2>/dev/null || true
        echo -e "${GREEN}✅ Web client stopped${NC}"
    fi

    # Kill Rustus TUS server
    if [ ! -z "$RUSTUS_PID" ]; then
        kill $RUSTUS_PID 2>/dev/null || true
        echo -e "${GREEN}✅ Rustus TUS server stopped${NC}"
    fi
    
    # Kill any remaining processes on the ports
    lsof -ti:3002 | xargs kill -9 2>/dev/null || true
    lsof -ti:3003 | xargs kill -9 2>/dev/null || true
    
    echo -e "${GREEN}✅ All services stopped. Goodbye!${NC}"
    exit 0
}

# Trap SIGINT and SIGTERM
trap cleanup SIGINT SIGTERM

# Check if ports are already in use
if check_port 3003; then
    echo -e "${YELLOW}⚠️  Port 3003 is already in use (OpenPhotos service)${NC}"
    echo -e "${YELLOW}   Kill existing process or use a different port${NC}"
    lsof -i:3003
    exit 1
fi

if check_port 3002; then
    echo -e "${YELLOW}⚠️  Port 3002 is already in use (Web client)${NC}"
    echo -e "${YELLOW}   Kill existing process or use a different port${NC}"
    lsof -i:3002
    exit 1
fi

# Optional: check rustus port
if check_port 1081; then
    echo -e "${YELLOW}⚠️  Port 1081 is already in use (Rustus TUS)${NC}"
    lsof -i:1081
    exit 1
fi

# Start OpenPhotos Service (Backend)
echo -e "${CYAN}────────────────────────────────────────────${NC}"
echo -e "${BLUE}1️⃣  Starting OpenPhotos Service (Backend)...${NC}"
echo -e "${CYAN}────────────────────────────────────────────${NC}"

# We're already in the albumbud directory

# Always build to pick up latest changes
echo -e "${YELLOW}Building OpenPhotos service...${NC}"
# Gate EE build by ENABLE_EE env (default off)
# Default to disabling libheif FFI for portable builds (HEIC decode falls back to ffmpeg).
# Override with USE_LIBHEIF=1 if you intentionally want libheif_ffi.
USE_LIBHEIF=${USE_LIBHEIF:-0}
FEATURES_ARGS=()
if [ "${USE_LIBHEIF}" = "1" ]; then
  FEATURES_ARGS+=("--features" "libheif_ffi")
else
  echo -e "${YELLOW}Building without libheif FFI (HEIC decode will fallback to ffmpeg)${NC}"
fi
if [ "${ENABLE_EE:-0}" = "1" ]; then
  echo -e "${CYAN}Building with EE features enabled${NC}"
  FEATURES_ARGS+=("--features" "ee")
fi
cargo build --release --locked --no-default-features ${FEATURES_ARGS[@]}

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenPhotos service build failed!${NC}"
    exit 1
fi

# Start OpenPhotos service in background
echo -e "${GREEN}Starting OpenPhotos service on port 3003...${NC}"
#RUST_LOG=info ./target/release/openphotos  --model-path models    --database ":memory:"  --log-level info &
# Prefer absolute path for data dir to avoid CWD issues
DATA_DIR_ABS="$(cd "$(dirname "$0")" && pwd)/data"
#RUST_LOG=info FACE_DEBUG=1  FACE_MIN_CONF=0.6 PERSON_MIN_CONF=0.6 FACE_MIN_SKIN_FRAC=0.08  ./target/release/openphotos  --model-path models   --database "$DATA_DIR_ABS"   --log-level info &

# - FACE_MIN_AREA_RATIO (default 0.001)
#      - FACE_MIN_CONF (default 0.7)
#      - FACE_MIN_SIZE (default 60)
#      - Set FACE_DEBUG=1 to log bbox/ratios.

# Optional Postgres schema initialization
if [ "$BACKEND" = "postgres" ] && [ "$PG_INIT" = "1" ]; then
    echo -e "${YELLOW}Initializing Postgres schema (pg_init)...${NC}"
    if ./target/release/pg_init; then
        echo -e "${GREEN}✅ Postgres schema initialized${NC}"
    else
        echo -e "${RED}❌ Postgres initialization failed. Check POSTGRES_* env and connectivity.${NC}"
        exit 1
    fi
fi

# In Postgres mode, ensure no on-disk DuckDB files linger to avoid confusion
if [ "$BACKEND" = "postgres" ]; then
  if [ -f "$DATA_DIR_ABS/users.duckdb" ] || [ -f "$DATA_DIR_ABS/data.duckdb" ]; then
    echo -e "${YELLOW}⚠️  Removing legacy DuckDB files under data/ (Postgres mode)${NC}"
    rm -f "$DATA_DIR_ABS/users.duckdb" "$DATA_DIR_ABS/users.duckdb.wal" "$DATA_DIR_ABS/data.duckdb" "$DATA_DIR_ABS/data.duckdb.wal" 2>/dev/null || true
  fi
fi

RUST_LOG=info EXIF_DEBUG=1 EXIFTOOL_FALLBACK=1 RUST_BACKTRACE=full \
FACE_DEBUG=1 FACE_MIN_CONF=0.65 PHASH_T_MAX=10 \
# Limit native thread pools used by ORT to reduce contention
OMP_NUM_THREADS=${OMP_NUM_THREADS:-1} \
# Cap concurrent indexing tasks to stabilize under load (tune as needed)
INGEST_CONCURRENCY=${INGEST_CONCURRENCY:-4} \
# Keep YOLO object detection enabled by default; can be overridden to 0 if needed
OBJECT_DETECT_ON_INDEX=${OBJECT_DETECT_ON_INDEX:-1} \
# OCR configuration (photos only). Enable and adjust as needed.
OCR_ENABLED=${OCR_ENABLED:-false} \
# Default OCR model path if present
OCR_MODEL_PATH=${OCR_MODEL_PATH:-models/ocr/ch} \
OCR_MAX_SIDE=${OCR_MAX_SIDE:-2048} \
OCR_THREADS=${OCR_THREADS:-1} \
OCR_CONCURRENCY=${OCR_CONCURRENCY:-2} \
# Detection tuning
OCR_DET_THRESH=${OCR_DET_THRESH:-0.30} \
OCR_DET_DILATE=${OCR_DET_DILATE:-1} \
OCR_DET_MIN_AREA_FRAC=${OCR_DET_MIN_AREA_FRAC:-0.002} \
OCR_DET_MIN_AREA_PX=${OCR_DET_MIN_AREA_PX:-48} \
OCR_DET_MERGE_IOU=${OCR_DET_MERGE_IOU:-0.20} \
# Recognition tuning
OCR_REC_HEIGHT=${OCR_REC_HEIGHT:-48} \
OCR_REC_MAX_WIDTH=${OCR_REC_MAX_WIDTH:-320} \
OCR_CLS_ROTATE=${OCR_CLS_ROTATE:-true} \
EMBEDDINGS_BACKEND=${BACKEND} \
PERSON_ASSIGN_THRESHOLD=0.40 ./target/release/openphotos --model-path models --database "$DATA_DIR_ABS" --log-level info &
ALBUMBUD_PID=$!

## OCR model presence check (warn only)
if [ "${OCR_ENABLED}" = "true" ]; then
    REC_PATH="${OCR_MODEL_PATH}/rec.onnx"
    if [ ! -f "$REC_PATH" ]; then
        echo -e "${YELLOW}⚠️  OCR_ENABLED=true but recognizer missing: ${REC_PATH}${NC}"
        echo -e "${YELLOW}   Run: REC_URL=\"https://<mirror>/ch_PP-OCRv3_rec_infer.onnx\" scripts/download_ocr_models.sh ${OCR_MODEL_PATH}${NC}"
    fi
fi

# Wait for OpenPhotos service to be ready
echo -e "${YELLOW}Waiting for OpenPhotos service to start...${NC}"
for i in {1..30}; do
    if curl -s http://localhost:3003/ping >/dev/null 2>&1; then
        echo -e "${GREEN}✅ OpenPhotos service is ready!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}❌ OpenPhotos service failed to start${NC}"
        cleanup
        exit 1
    fi
    sleep 1
done


# ────────────────────────────────────────────
# 2) Start Rustus TUS Server (sidecar on loopback)
echo -e "${CYAN}────────────────────────────────────────────${NC}"
echo -e "${BLUE}2️⃣  Starting Rustus TUS Server...${NC}"
echo -e "${CYAN}────────────────────────────────────────────${NC}"

echo -e "${YELLOW}Building Rustus...${NC}"
cargo build --release --locked --manifest-path rustus/Cargo.toml
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Rustus build failed!${NC}"
    cleanup
    exit 1
fi

# Prepare upload directories
UPLOAD_DIR_ABS="$(cd "$(dirname "$0")" && pwd)/data/uploads"
mkdir -p "$UPLOAD_DIR_ABS"

echo -e "${GREEN}Starting Rustus (TUS) on 127.0.0.1:1081...${NC}"
RUSTUS_SERVER_HOST=127.0.0.1 \
RUSTUS_SERVER_PORT=1081 \
RUSTUS_URL=/files \
RUSTUS_DATA_DIR="$UPLOAD_DIR_ABS" \
RUSTUS_INFO_DIR="$UPLOAD_DIR_ABS" \
RUSTUS_TUS_EXTENSIONS="creation,termination,creation-with-upload,creation-defer-length,concatenation,checksum" \
RUSTUS_MAX_BODY_SIZE=52428800 \
RUSTUS_HOOKS="pre-create,post-finish" \
RUSTUS_HOOKS_FORMAT=v2 \
RUSTUS_HOOKS_HTTP_URLS="http://127.0.0.1:3003/api/upload/hooks" \
RUSTUS_HOOKS_HTTP_PROXY_HEADERS="Authorization,X-Request-ID,Cookie" \
RUSTUS_LOG_LEVEL=INFO \
./rustus/target/release/rustus &
RUSTUS_PID=$!

echo -e "${YELLOW}Waiting for Rustus to become ready...${NC}"
for i in {1..30}; do
    if curl -s http://127.0.0.1:1081/health >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Rustus TUS server is ready!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}❌ Rustus failed to start${NC}"
        cleanup
        exit 1
    fi
    sleep 1
done




cd ..

# Success message
echo -e "${CYAN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}🎉 OpenPhotos is running!${NC}"
echo -e "${CYAN}════════════════════════════════════════════${NC}"
echo -e "${BLUE}🌐 OpenPhotos Web Interface:${NC} ${GREEN}http://localhost:3002${NC}"
echo -e "   - Modern photo grid with semantic search"
echo -e "   - Intelligent face clustering"
echo -e "   - YOLO object detection integration"
echo
echo -e "${BLUE}🔧 OpenPhotos API Backend:${NC} ${GREEN}http://localhost:3003${NC}"
echo -e "   - CLIP semantic search API"
echo -e "   - Face processing & clustering"
echo -e "   - YOLO object detection"
echo -e "${CYAN}════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
echo

# Keep script running
wait $ALBUMBUD_PID $NEXT_PID
