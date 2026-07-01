#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a local OpenPhotos Docker image.

Usage:
  scripts/build_docker_image.sh --oss|--ee [--platform <platform>] [--tag <tag>] [--ffmpeg-bundle-dir <path>] [--pull] [--no-cache] [--fresh]

Options:
  --oss                 Build the OSS image (default tag: openphotos:local)
  --ee                  Build the enterprise image from the private source tree
                        (default tag: openphotos-ee:local)
  --platform <platform> Docker target platform, for example linux/amd64 or linux/arm64
  --tag <tag>           Override the output image tag
  --ffmpeg-bundle-dir <path>
                        Linux ffmpeg bundle root (default: dist/linux-ffmpeg)
  --pull                Pull newer base images before building
  --no-cache            Disable Docker layer cache for this build
  --fresh               Convenience flag for --pull --no-cache
  -h, --help            Show this help
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

pull_image_with_retries() {
  local image="$1"
  local platform="${2:-}"
  local attempts="${BASE_IMAGE_PULL_RETRIES:-4}"
  local delay=2
  local try
  local pull_cmd=(docker pull)

  if [[ -n "$platform" ]]; then
    pull_cmd+=(--platform "$platform")
  fi
  pull_cmd+=("$image")

  for ((try = 1; try <= attempts; try++)); do
    if "${pull_cmd[@]}"; then
      return 0
    fi
    if [[ "$try" -lt "$attempts" ]]; then
      echo "Retrying base image pull for $image in ${delay}s (attempt $((try + 1))/$attempts)..." >&2
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  echo "ERROR: failed to pull base image $image after $attempts attempts" >&2
  return 1
}

resolve_repo_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$ROOT_DIR/$path"
  fi
}

default_platform() {
  case "$(uname -m)" in
    arm64|aarch64) printf '%s\n' "linux/arm64" ;;
    x86_64|amd64) printf '%s\n' "linux/amd64" ;;
    *) printf '%s\n' "" ;;
  esac
}

dir_has_files() {
  local dir="$1"
  local first_file
  if [[ ! -d "$dir" ]]; then
    return 1
  fi
  first_file="$(find "$dir" -type f -print -quit 2>/dev/null || true)"
  [[ -n "$first_file" ]]
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./ffmpeg_bundle.sh
source "$ROOT_DIR/scripts/ffmpeg_bundle.sh"
MODE=""
PLATFORM="${PLATFORM:-}"
TAG=""
FFMPEG_BUNDLE_DIR="${FFMPEG_BUNDLE_DIR:-$ROOT_DIR/dist/linux-ffmpeg}"
TEMP_CONTEXT=""
PULL=0
NO_CACHE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oss)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: specify only one of --oss or --ee" >&2
        exit 1
      fi
      MODE="oss"
      shift
      ;;
    --ee)
      if [[ -n "$MODE" ]]; then
        echo "ERROR: specify only one of --oss or --ee" >&2
        exit 1
      fi
      MODE="ee"
      shift
      ;;
    --platform)
      [[ $# -ge 2 ]] || { echo "ERROR: --platform requires a value" >&2; exit 1; }
      PLATFORM="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { echo "ERROR: --tag requires a value" >&2; exit 1; }
      TAG="$2"
      shift 2
      ;;
    --ffmpeg-bundle-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --ffmpeg-bundle-dir requires a value" >&2; exit 1; }
      FFMPEG_BUNDLE_DIR="$2"
      shift 2
      ;;
    --pull)
      PULL=1
      shift
      ;;
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    --fresh)
      PULL=1
      NO_CACHE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: specify one of --oss or --ee" >&2
  usage
  exit 1
fi

require_cmd docker

if [[ -z "$PLATFORM" ]]; then
  PLATFORM="$(default_platform)"
fi
if [[ -z "$PLATFORM" ]]; then
  echo "ERROR: could not determine Docker platform automatically. Pass --platform." >&2
  exit 1
fi

if [[ -z "$TAG" ]]; then
  if [[ "$MODE" == "ee" ]]; then
    TAG="openphotos-ee:local"
  else
    TAG="openphotos:local"
  fi
fi

ENABLE_EE=0
if [[ "$MODE" == "ee" ]]; then
  ENABLE_EE=1
  if ! dir_has_files "$ROOT_DIR/ee/server" || ! dir_has_files "$ROOT_DIR/ee/web"; then
    echo "ERROR: EE build requested but ee/server or ee/web is missing." >&2
    echo "Use the private source tree; the public GitHub export does not include enterprise source." >&2
    exit 1
  fi
fi

cleanup() {
  if [[ -n "$TEMP_CONTEXT" && -d "$TEMP_CONTEXT" ]]; then
    rm -rf "$TEMP_CONTEXT"
  fi
}
trap cleanup EXIT

FFMPEG_BUNDLE_DIR="$(resolve_repo_path "$FFMPEG_BUNDLE_DIR")"
BUNDLE_ARCH="$(normalize_ffmpeg_bundle_arch "$PLATFORM")"
FFMPEG_RUNTIME_DIR="$(resolve_ffmpeg_bundle_runtime_dir "$FFMPEG_BUNDLE_DIR" "$BUNDLE_ARCH")"
CANONICAL_FFMPEG_BUNDLE_DIR="$ROOT_DIR/dist/linux-ffmpeg"
BUILD_CONTEXT="$ROOT_DIR"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile"

if [[ "$FFMPEG_BUNDLE_DIR" != "$CANONICAL_FFMPEG_BUNDLE_DIR" ]]; then
  require_cmd rsync
  TEMP_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/openphotos-docker-context.XXXXXX")"
  rsync -a "$ROOT_DIR/" "$TEMP_CONTEXT/"
  rm -rf "$TEMP_CONTEXT/dist/linux-ffmpeg"
  mkdir -p "$TEMP_CONTEXT/dist/linux-ffmpeg"
  rsync -a "$FFMPEG_BUNDLE_DIR/" "$TEMP_CONTEXT/dist/linux-ffmpeg/"
  BUILD_CONTEXT="$TEMP_CONTEXT"
  DOCKERFILE_PATH="$TEMP_CONTEXT/Dockerfile"
fi

echo "Prefetching Docker base images..."
pull_image_with_retries "node:20-bookworm-slim"
pull_image_with_retries "debian:bookworm-slim"
pull_image_with_retries "ubuntu:24.04" "$PLATFORM"
pull_image_with_retries "rust:1.90-bookworm" "$PLATFORM"

build_cmd=(docker buildx build --load -f "$DOCKERFILE_PATH" -t "$TAG" --build-arg "ENABLE_EE=$ENABLE_EE")
build_cmd+=(--platform "$PLATFORM")
if [[ "$PULL" == "1" ]]; then
  build_cmd+=(--pull)
fi
if [[ "$NO_CACHE" == "1" ]]; then
  build_cmd+=(--no-cache)
fi
build_cmd+=("$BUILD_CONTEXT")

echo "Building Docker image:"
echo "  Mode: $MODE"
echo "  Tag: $TAG"
echo "  Platform: $PLATFORM"
echo "  ffmpeg bundle root: $FFMPEG_BUNDLE_DIR"
echo "  ffmpeg runtime dir: $FFMPEG_RUNTIME_DIR"
if [[ "$PULL" == "1" ]]; then
  echo "  Pull newer base images: yes"
fi
if [[ "$NO_CACHE" == "1" ]]; then
  echo "  Build cache disabled: yes"
fi
echo

"${build_cmd[@]}"

echo
echo "Built image: $TAG"
echo "Run with: OPENPHOTOS_IMAGE=$TAG docker compose up -d"
