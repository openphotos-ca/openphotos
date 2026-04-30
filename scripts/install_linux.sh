#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
if [[ "$SCRIPT_NAME" =~ ^[0-9]+$ ]]; then
  SCRIPT_NAME="install_linux.sh"
fi
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
LOCAL_SCRIPT_DIR=""
if [[ -f "$SCRIPT_SOURCE" ]]; then
  LOCAL_SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  case "$LOCAL_SCRIPT_DIR" in
    /dev/fd|/dev/fd/*|/proc/*/fd|/proc/*/fd/*)
      LOCAL_SCRIPT_DIR=""
      ;;
  esac
fi
GITHUB_REPO="${OPENPHOTOS_INSTALL_REPO:-openphotos-ca/openphotos}"
VERSION="${OPENPHOTOS_INSTALL_VERSION:-latest}"
ASSET_BASE_URL="${OPENPHOTOS_INSTALL_ASSET_BASE_URL:-}"
RK3588_MODE="${OPENPHOTOS_RK3588:-auto}"
STANDARD_MODELS_ASSET="${OPENPHOTOS_MODELS_ASSET:-openphotos_models.zip}"
RK3588_MODELS_ASSET="${OPENPHOTOS_RK3588_MODELS_ASSET:-openphotos_models_rk3588.zip}"
LOCAL_ASSET_DIR="${OPENPHOTOS_INSTALL_LOCAL_ASSET_DIR:-}"
DRY_RUN=0
UNINSTALL_MODE=""

CURL_FLAGS=(-fL --retry 5 --retry-delay 2 --retry-max-time 120)

usage() {
  cat <<USAGE
Install OpenPhotos on Linux from GitHub release assets.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --version <tag>       Install a specific release tag, for example v0.6.0.
  --repo <owner/repo>   GitHub repo to download from (default: ${GITHUB_REPO}).
  --asset-base-url <u>  Download wrapper assets from this base URL instead of GitHub.
  --rk3588             Force RK3588 model provisioning on arm64.
  --no-rk3588          Disable automatic RK3588 model provisioning.
  --uninstall          Uninstall OpenPhotos, keeping data and model folders.
  --uninstall-purge    Uninstall OpenPhotos and remove data, config, logs, and models.
  --dry-run            Print the detected plan without downloading or installing.
  -h, --help           Show this help.

Environment:
  OPENPHOTOS_INSTALL_REPO             Override the GitHub repo.
  OPENPHOTOS_INSTALL_VERSION          Override the release tag.
  OPENPHOTOS_INSTALL_ASSET_BASE_URL   Override the release asset base URL.
  OPENPHOTOS_INSTALL_LOCAL_ASSET_DIR  Directory to scan for local installers and model ZIPs.
                                      By default the local script directory and current directory are scanned.
  OPENPHOTOS_MODELS_ASSET             Standard model ZIP name (default: ${STANDARD_MODELS_ASSET}).
  OPENPHOTOS_RK3588_MODELS_ASSET      RK3588 model ZIP name (default: ${RK3588_MODELS_ASSET}).
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

as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_systemctl_if_available() {
  if has_command systemctl; then
    as_root systemctl "$@" >/dev/null 2>&1 || true
  fi
}

print_uninstall_plan() {
  local mode="$1"

  printf 'Would stop and disable services: openphotos.service rustus.service\n'
  printf 'Would remove service units:\n'
  printf '  /etc/systemd/system/openphotos.service\n'
  printf '  /etc/systemd/system/rustus.service\n'
  printf 'Would remove binaries:\n'
  printf '  /usr/local/bin/openphotos\n'
  printf '  /usr/local/bin/rustus\n'
  printf '  /usr/local/bin/openphotos-uninstall\n'

  if [[ "$mode" == "purge" ]]; then
    printf 'Would remove all OpenPhotos files including data and models:\n'
    printf '  /opt/openphotos\n'
    printf '  /opt/rknn\n'
    printf '  /etc/openphotos\n'
    printf '  /var/lib/openphotos\n'
    printf '  /var/log/openphotos\n'
    printf '  /var/tmp/openphotos-installer\n'
    printf 'Would remove system user/group when possible: openphotos\n'
  else
    printf 'Would remove program files while keeping data and models:\n'
    printf '  remove /opt/openphotos/bin\n'
    printf '  remove /opt/openphotos/defaults\n'
    printf '  remove /opt/openphotos/lib\n'
    printf '  remove /opt/openphotos/web-photos\n'
    printf '  remove /opt/rknn\n'
    printf '  keep /opt/openphotos/models\n'
    printf '  keep /var/lib/openphotos\n'
    printf '  keep /etc/openphotos\n'
    printf '  keep /var/log/openphotos\n'
    printf '  remove /var/tmp/openphotos-installer\n'
  fi
}

uninstall_openphotos() {
  local mode="$1"

  [[ "$mode" == "keep" || "$mode" == "purge" ]] || fail "invalid uninstall mode: $mode"

  if [[ "$DRY_RUN" == "1" ]]; then
    print_uninstall_plan "$mode"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    require_command sudo
  fi

  note "stopping OpenPhotos services..."
  run_systemctl_if_available disable --now openphotos.service rustus.service
  run_systemctl_if_available stop openphotos.service rustus.service

  note "removing OpenPhotos service units and binaries..."
  as_root rm -f \
    /etc/systemd/system/openphotos.service \
    /etc/systemd/system/rustus.service \
    /usr/local/bin/openphotos \
    /usr/local/bin/rustus \
    /usr/local/bin/openphotos-uninstall
  run_systemctl_if_available daemon-reload
  run_systemctl_if_available reset-failed openphotos.service rustus.service

  if [[ "$mode" == "purge" ]]; then
    note "removing OpenPhotos data, models, config, logs, and runtime files..."
    as_root rm -rf \
      /opt/openphotos \
      /opt/rknn \
      /etc/openphotos \
      /var/lib/openphotos \
      /var/log/openphotos \
      /var/tmp/openphotos-installer

    if id -u openphotos >/dev/null 2>&1; then
      as_root userdel openphotos >/dev/null 2>&1 || true
    fi
    if getent group openphotos >/dev/null 2>&1; then
      as_root groupdel openphotos >/dev/null 2>&1 || true
    fi
  else
    note "removing OpenPhotos program files and keeping data/models..."
    as_root rm -rf \
      /opt/openphotos/bin \
      /opt/openphotos/defaults \
      /opt/openphotos/lib \
      /opt/openphotos/web-photos \
      /opt/rknn \
      /var/tmp/openphotos-installer
  fi

  note "uninstall complete"
}

local_asset_dirs() {
  if [[ -n "$LOCAL_ASSET_DIR" ]]; then
    printf '%s\n' "$LOCAL_ASSET_DIR"
    return 0
  fi

  if [[ -n "$LOCAL_SCRIPT_DIR" ]]; then
    printf '%s\n' "$LOCAL_SCRIPT_DIR"
  fi

  if [[ -z "$LOCAL_SCRIPT_DIR" || "$LOCAL_SCRIPT_DIR" != "$PWD" ]]; then
    printf '%s\n' "$PWD"
  fi
}

find_local_file() {
  local asset_name="$1"
  local dir source_path

  while IFS= read -r dir; do
    source_path="${dir%/}/${asset_name}"
    if [[ -f "$source_path" ]]; then
      printf '%s\n' "$source_path"
      return 0
    fi
  done < <(local_asset_dirs)

  return 1
}

stage_local_asset() {
  local asset_name="$1"
  local destination_dir="$2"
  local source_path=""

  if source_path="$(find_local_file "$asset_name")"; then
    cp "$source_path" "$destination_dir/$asset_name"
    note "using local ${asset_name} from $(dirname "$source_path")"
    return 0
  fi

  return 1
}

find_unique_local_archive() {
  local description="$1"
  local prefix_name="$2"
  local suffix="$3"
  local -a matches=()
  local dir

  shopt -s nullglob
  while IFS= read -r dir; do
    matches+=( "${dir%/}/${prefix_name}"*"${suffix}" )
  done < <(local_asset_dirs)
  shopt -u nullglob

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    fail "multiple local ${description} archives found; pass --version or remove the extra files."
  fi

  return 1
}

find_local_installer_archive() {
  local version="$1"
  local arch="$2"
  local version_no_v="${version#v}"
  local candidate
  local dir

  if [[ "$version" != "latest" ]]; then
    while IFS= read -r dir; do
      candidate="${dir%/}/openphotos-linux-online_${version_no_v}_${arch}.tar.gz"
      if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi

      candidate="${dir%/}/openphotos-linux_${version_no_v}_${arch}.tar.gz"
      if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(local_asset_dirs)

    return 1
  fi

  if candidate="$(find_unique_local_archive "online ${arch}" "openphotos-linux-online_" "_${arch}.tar.gz")"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if candidate="$(find_unique_local_archive "bundled ${arch}" "openphotos-linux_" "_${arch}.tar.gz")"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

stage_local_tarball_assets() {
  local destination_dir="$1"
  local dir
  local source_path
  while IFS= read -r dir; do
    shopt -s nullglob
    for source_path in "${dir%/}"/openphotos-linux*_"${ARCH}".tar.gz; do
      cp "$source_path" "$destination_dir/$(basename "$source_path")"
      note "using local $(basename "$source_path") from $dir"
    done
    shopt -u nullglob
  done < <(local_asset_dirs)
}

print_local_tarball_assets() {
  local dir
  local source_path
  while IFS= read -r dir; do
    shopt -s nullglob
    for source_path in "${dir%/}"/openphotos-linux*_"${ARCH}".tar.gz; do
      printf 'Would stage local installer archive: %s\n' "$source_path"
    done
    shopt -u nullglob
  done < <(local_asset_dirs)
}

check_environment() {
  [[ "$(uname -s)" == "Linux" ]] || fail "this installer supports Linux only."
  require_command bash

  if [[ -n "$UNINSTALL_MODE" ]]; then
    return 0
  fi

  require_command mktemp
  require_command tar

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    require_command sudo
  fi

  require_command systemctl
  [[ -d /run/systemd/system ]] || fail "systemd is required and must be running."
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
    --uninstall)
      UNINSTALL_MODE="keep"
      shift
      ;;
    --uninstall-purge)
      UNINSTALL_MODE="purge"
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

if [[ -n "$UNINSTALL_MODE" ]]; then
  uninstall_openphotos "$UNINSTALL_MODE"
  exit 0
fi

ARCH="$(detect_arch)"
VERSION="$(normalize_version "$VERSION")"
WRAPPER_ASSET="openphotos-linux-installer-${ARCH}.sh"
WRAPPER_URL="$(asset_url_for "$WRAPPER_ASSET" "$VERSION")"
WRAPPER_ARGS=()
LOCAL_INSTALLER_ARCHIVE=""

if should_enable_rk3588 "$ARCH" "$RK3588_MODE"; then
  WRAPPER_ARGS+=(--rk3588)
  note "RK3588 detected/enabled; RK3588 models will be provisioned by the release wrapper."
elif [[ "$ARCH" == "arm64" && "$RK3588_MODE" == "auto" ]] && has_rknpu_device_hint; then
  warn "Rockchip NPU device detected, but this system was not identified as RK3588. Use --rk3588 if this is an RK3588 board."
fi

note "release: ${VERSION}"
note "architecture: ${ARCH}"
note "wrapper: ${WRAPPER_URL}"

if LOCAL_INSTALLER_ARCHIVE="$(find_local_installer_archive "$VERSION" "$ARCH")"; then
  note "local installer archive: ${LOCAL_INSTALLER_ARCHIVE}"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ -n "$LOCAL_INSTALLER_ARCHIVE" ]]; then
    printf 'Would install local archive: %s\n' "$LOCAL_INSTALLER_ARCHIVE"
  else
    printf 'Would run: bash <downloaded %s>' "$WRAPPER_ASSET"
    if [[ "${#WRAPPER_ARGS[@]}" -gt 0 ]]; then
      printf ' %q' "${WRAPPER_ARGS[@]}"
    fi
    printf '\n'
  fi
  if local_standard_models="$(find_local_file "$STANDARD_MODELS_ASSET")"; then
    printf 'Would stage local model archive: %s\n' "$local_standard_models"
  fi
  if [[ "$ARCH" == "arm64" ]] && local_rk3588_models="$(find_local_file "$RK3588_MODELS_ASSET")"; then
    printf 'Would stage local RK3588 model archive: %s\n' "$local_rk3588_models"
  fi
  print_local_tarball_assets
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openphotos-install.XXXXXXXXXX")"
RK3588_MARKER_CREATED=0
cleanup() {
  rm -rf "$TMP_DIR"
  if [[ "$RK3588_MARKER_CREATED" == "1" ]]; then
    as_root rm -f /var/tmp/openphotos-installer/enable-rk3588
  fi
}
trap cleanup EXIT

stage_release_assets_for_direct_archive() {
  local local_standard_models=""
  local local_rk3588_models=""

  as_root install -d -m 0755 /var/tmp/openphotos-installer
  if local_standard_models="$(find_local_file "$STANDARD_MODELS_ASSET")"; then
    as_root install -m 0644 "$local_standard_models" "/var/tmp/openphotos-installer/${STANDARD_MODELS_ASSET}"
    note "using local ${STANDARD_MODELS_ASSET} from $(dirname "$local_standard_models")"
  else
    as_root rm -f "/var/tmp/openphotos-installer/${STANDARD_MODELS_ASSET}"
  fi

  if [[ "$ARCH" == "arm64" ]] && local_rk3588_models="$(find_local_file "$RK3588_MODELS_ASSET")"; then
    as_root install -m 0644 "$local_rk3588_models" "/var/tmp/openphotos-installer/${RK3588_MODELS_ASSET}"
    note "using local ${RK3588_MODELS_ASSET} from $(dirname "$local_rk3588_models")"
  else
    as_root rm -f "/var/tmp/openphotos-installer/${RK3588_MODELS_ASSET}"
  fi

  if [[ "${#WRAPPER_ARGS[@]}" -gt 0 ]]; then
    as_root touch /var/tmp/openphotos-installer/enable-rk3588
    RK3588_MARKER_CREATED=1
  else
    as_root rm -f /var/tmp/openphotos-installer/enable-rk3588
  fi
}

run_local_installer_archive() {
  local archive_path="$1"
  local extract_dir="$TMP_DIR/extract"
  local tar_stderr="$TMP_DIR/tar-extract.stderr"

  mkdir -p "$extract_dir"
  if ! tar -xzf "$archive_path" -C "$extract_dir" 2>"$tar_stderr"; then
    cat "$tar_stderr" >&2
    fail "failed to extract installer archive: $archive_path"
  fi
  if [[ -s "$tar_stderr" ]]; then
    if has_command grep; then
      grep -Ev "^tar: Ignoring unknown extended header keyword 'LIBARCHIVE\\.xattr\\." "$tar_stderr" >&2 || true
    else
      cat "$tar_stderr" >&2
    fi
  fi
  [[ -x "$extract_dir/install.sh" ]] || fail "installer archive does not contain executable install.sh"
  as_root bash "$extract_dir/install.sh"
}

prepare_compat_tools() {
  local compat_dir="$TMP_DIR/compat-bin"

  if has_command perl; then
    return 0
  fi
  if ! has_command python3 && ! has_command awk; then
    return 0
  fi

  mkdir -p "$compat_dir"
  cat > "$compat_dir/perl" <<'EOF'
#!/usr/bin/env sh
set -eu

script=""
input_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -0ne)
      shift
      script="${1:-}"
      ;;
    -*)
      ;;
    *)
      input_file="$1"
      ;;
  esac
  shift || break
done

[ -n "$input_file" ] || exit 1
mode=""
case "$script" in
  *tag_name*) mode="tag" ;;
  *browser_download_url*) mode="url" ;;
  *digest*) mode="digest" ;;
  *) exit 127 ;;
esac

if command -v python3 >/dev/null 2>&1; then
  MODE="$mode" python3 - "$input_file" <<'PY'
import json
import os
import sys

mode = os.environ["MODE"]
asset_name = os.environ.get("MODEL_ASSET_NAME", "")

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    release = json.load(fh)

if mode == "tag":
    value = release.get("tag_name") or ""
elif mode in {"url", "digest"}:
    asset = next((item for item in release.get("assets", []) if item.get("name") == asset_name), None)
    if not asset:
        value = ""
    elif mode == "url":
        value = asset.get("browser_download_url") or ""
    else:
        value = asset.get("digest") or ""
else:
    value = ""

if value:
    print(value, end="")
PY
  exit 0
fi

if ! command -v awk >/dev/null 2>&1; then
  exit 127
fi

case "$mode" in
  tag)
    awk '
      match($0, /"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"/) {
        value = substr($0, RSTART, RLENGTH)
        sub(/^.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/"$/, "", value)
        printf "%s", value
        exit
      }
    ' "$input_file"
    ;;
  url|digest)
    key="browser_download_url"
    [ "$mode" = "digest" ] && key="digest"
    awk -v name="$MODEL_ASSET_NAME" -v key="$key" '
      index($0, "\"name\"") && index($0, "\"" name "\"") {
        in_asset = 1
      }
      in_asset && index($0, "\"" key "\"") {
        value = $0
        sub("^.*\"" key "\"[[:space:]]*:[[:space:]]*\"", "", value)
        sub("\".*$", "", value)
        printf "%s", value
        exit
      }
      in_asset && $0 ~ /^[[:space:]]*}[,]?[[:space:]]*$/ {
        in_asset = 0
      }
    ' "$input_file"
    ;;
esac
EOF
  chmod 0755 "$compat_dir/perl"
  export PATH="$compat_dir:$PATH"
  note "perl not found; using metadata compatibility shim for older online installers"
}

if [[ -n "$LOCAL_INSTALLER_ARCHIVE" ]]; then
  note "using local installer archive instead of downloading from GitHub"
  prepare_compat_tools
  stage_release_assets_for_direct_archive
  run_local_installer_archive "$LOCAL_INSTALLER_ARCHIVE"
  exit 0
fi

WRAPPER_PATH="$TMP_DIR/$WRAPPER_ASSET"
if local_wrapper="$(find_local_file "$WRAPPER_ASSET")"; then
  cp "$local_wrapper" "$WRAPPER_PATH"
  note "using local ${WRAPPER_ASSET} from $(dirname "$local_wrapper")"
else
  require_command curl
  note "downloading installer wrapper..."
  curl "${CURL_FLAGS[@]}" -o "$WRAPPER_PATH" "$WRAPPER_URL"
fi
chmod 0755 "$WRAPPER_PATH"
stage_local_asset "$STANDARD_MODELS_ASSET" "$TMP_DIR" || true
if [[ "$ARCH" == "arm64" ]]; then
  stage_local_asset "$RK3588_MODELS_ASSET" "$TMP_DIR" || true
fi
stage_local_tarball_assets "$TMP_DIR"

note "starting OpenPhotos installer..."
prepare_compat_tools
exec bash "$WRAPPER_PATH" "${WRAPPER_ARGS[@]}"
