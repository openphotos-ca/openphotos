#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
if [[ "$SCRIPT_NAME" =~ ^[0-9]+$ ]]; then
  SCRIPT_NAME="install_linux.sh"
fi
GITHUB_REPO="${OPENPHOTOS_INSTALL_REPO:-openphotos-ca/openphotos}"
VERSION="${OPENPHOTOS_INSTALL_VERSION:-latest}"
ASSET_BASE_URL="${OPENPHOTOS_INSTALL_ASSET_BASE_URL:-}"
RK3588_MODE="${OPENPHOTOS_RK3588:-auto}"
DRY_RUN=0

CURL_FLAGS=(-fL --retry 5 --retry-delay 2 --retry-max-time 120)

usage() {
  cat <<USAGE
Install OpenPhotos on Debian/Ubuntu Linux from GitHub release assets.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --version <tag>       Install a specific release tag, for example v0.6.0.
  --repo <owner/repo>   GitHub repo to download from (default: ${GITHUB_REPO}).
  --asset-base-url <u>  Download wrapper assets from this base URL instead of GitHub.
  --rk3588             Force RK3588 model provisioning on arm64.
  --no-rk3588          Disable automatic RK3588 model provisioning.
  --dry-run            Print the detected plan without downloading or installing.
  -h, --help           Show this help.

Environment:
  OPENPHOTOS_INSTALL_REPO             Override the GitHub repo.
  OPENPHOTOS_INSTALL_VERSION          Override the release tag.
  OPENPHOTOS_INSTALL_ASSET_BASE_URL   Override the release asset base URL.
  OPENPHOTOS_RK3588                   auto, 1, true, yes, 0, false, or no.
USAGE
}

note() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '%s: warning: %s\n' "$SCRIPT_NAME" "$*" >&2
}

fail() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  has_command "$cmd" || fail "required command not found: ${cmd}"
}

normalize_version() {
  local version="$1"
  if [[ "$version" == "latest" ]]; then
    printf '%s\n' "$version"
  elif [[ "$version" == v* ]]; then
    printf '%s\n' "$version"
  else
    printf 'v%s\n' "$version"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' "amd64"
      ;;
    aarch64|arm64)
      printf '%s\n' "arm64"
      ;;
    *)
      fail "unsupported Linux architecture: $(uname -m). OpenPhotos release installers currently support amd64 and arm64."
      ;;
  esac
}

contains_rk3588() {
  local path="$1"
  [[ -r "$path" ]] || return 1
  LC_ALL=C tr '\0' '\n' < "$path" 2>/dev/null | grep -Eiq '(^|[^[:alnum:]])rk3588s?([^[:alnum:]]|$)|rockchip,rk3588s?'
}

detect_rk3588_soc() {
  local path
  for path in \
    /proc/device-tree/compatible \
    /proc/device-tree/model \
    /sys/firmware/devicetree/base/compatible \
    /sys/firmware/devicetree/base/model; do
    contains_rk3588 "$path" && return 0
  done

  if [[ -r /proc/cpuinfo ]] && grep -Eiq 'rk3588s?' /proc/cpuinfo; then
    return 0
  fi

  return 1
}

has_rknpu_device_hint() {
  compgen -G "/dev/rknpu*" >/dev/null 2>&1 && return 0
  compgen -G "/sys/bus/platform/devices/*rknpu*" >/dev/null 2>&1 && return 0
  compgen -G "/sys/class/misc/rknpu*" >/dev/null 2>&1 && return 0
  return 1
}

should_enable_rk3588() {
  local arch="$1"
  local mode="$2"

  case "$mode" in
    auto|"")
      [[ "$arch" == "arm64" ]] || return 1
      detect_rk3588_soc
      ;;
    1|true|TRUE|yes|YES|on|ON)
      [[ "$arch" == "arm64" ]] || fail "--rk3588 is only supported by the arm64 installer."
      return 0
      ;;
    0|false|FALSE|no|NO|off|OFF)
      return 1
      ;;
    *)
      fail "invalid RK3588 mode: ${mode}. Use auto, 1, true, yes, 0, false, or no."
      ;;
  esac
}

asset_url_for() {
  local asset_name="$1"
  local version="$2"
  local base="${ASSET_BASE_URL%/}"

  if [[ -n "$base" ]]; then
    printf '%s/%s\n' "$base" "$asset_name"
  elif [[ "$version" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$GITHUB_REPO" "$asset_name"
  else
    printf 'https://github.com/%s/releases/download/%s/%s\n' "$GITHUB_REPO" "$version" "$asset_name"
  fi
}

check_environment() {
  [[ "$(uname -s)" == "Linux" ]] || fail "this installer supports Linux only."
  require_command bash
  require_command curl
  require_command mktemp

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  require_command dpkg
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    require_command sudo
  fi

  if ! has_command systemctl || [[ ! -d /run/systemd/system ]]; then
    warn "systemd does not appear to be active. The package can install, but OpenPhotos services may not auto-start."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value."
      VERSION="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || fail "--repo requires a value."
      GITHUB_REPO="$2"
      shift 2
      ;;
    --asset-base-url)
      [[ $# -ge 2 ]] || fail "--asset-base-url requires a value."
      ASSET_BASE_URL="$2"
      shift 2
      ;;
    --rk3588)
      RK3588_MODE="1"
      shift
      ;;
    --no-rk3588)
      RK3588_MODE="0"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

check_environment

ARCH="$(detect_arch)"
VERSION="$(normalize_version "$VERSION")"
WRAPPER_ASSET="openphotos-linux-installer-${ARCH}.sh"
WRAPPER_URL="$(asset_url_for "$WRAPPER_ASSET" "$VERSION")"
WRAPPER_ARGS=()

if should_enable_rk3588 "$ARCH" "$RK3588_MODE"; then
  WRAPPER_ARGS+=(--rk3588)
  note "RK3588 detected/enabled; RK3588 models will be provisioned by the release wrapper."
elif [[ "$ARCH" == "arm64" && "$RK3588_MODE" == "auto" ]] && has_rknpu_device_hint; then
  warn "Rockchip NPU device detected, but this system was not identified as RK3588. Use --rk3588 if this is an RK3588 board."
fi

note "release: ${VERSION}"
note "architecture: ${ARCH}"
note "wrapper: ${WRAPPER_URL}"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'Would run: bash <downloaded %s>' "$WRAPPER_ASSET"
  if [[ "${#WRAPPER_ARGS[@]}" -gt 0 ]]; then
    printf ' %q' "${WRAPPER_ARGS[@]}"
  fi
  printf '\n'
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openphotos-install.XXXXXXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WRAPPER_PATH="$TMP_DIR/$WRAPPER_ASSET"
note "downloading installer wrapper..."
curl "${CURL_FLAGS[@]}" -o "$WRAPPER_PATH" "$WRAPPER_URL"
chmod 0755 "$WRAPPER_PATH"

note "starting OpenPhotos installer..."
exec bash "$WRAPPER_PATH" "${WRAPPER_ARGS[@]}"
