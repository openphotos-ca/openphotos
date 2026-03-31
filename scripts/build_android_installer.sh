#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build an Android release APK for OpenPhotos.

Usage:
  scripts/build_android_installer.sh [options]

Options:
  --output-dir <path>  Output directory (default: dist/android-packages)
  --no-build           Skip rebuilding and reuse the existing release APK
  --rebuild            Rebuild the release APK before packaging (default)
  -h, --help           Show this help

Default behavior:
- If Android signing env vars are set, use that keystore
- Otherwise, create and reuse android-java/.openphotos-signing/openphotos-auto-release.jks

Required environment for signed release builds:
  ANDROID_KEYSTORE_PATH
  ANDROID_KEYSTORE_PASSWORD
  ANDROID_KEY_ALIAS
  ANDROID_KEY_PASSWORD

Artifact:
  <output-dir>/openphotos-android-release.apk
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

require_dir() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    echo "ERROR: $label not found: $path" >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    echo "ERROR: $label not found: $path" >&2
    exit 1
  fi
}

resolve_repo_path() {
  local root="$1"
  local path="$2"
  if [[ "$path" = /* ]]; then
    echo "$path"
  else
    echo "$root/$path"
  fi
}

validate_release_signing_env() {
  local missing=()
  local var

  for var in \
    ANDROID_KEYSTORE_PATH \
    ANDROID_KEYSTORE_PASSWORD \
    ANDROID_KEY_ALIAS \
    ANDROID_KEY_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "ERROR: missing required Android release signing environment variables: ${missing[*]}" >&2
    echo "Set ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD." >&2
    exit 1
  fi

  if [[ ! -f "${ANDROID_KEYSTORE_PATH}" ]]; then
    echo "ERROR: ANDROID_KEYSTORE_PATH does not point to an existing file: ${ANDROID_KEYSTORE_PATH}" >&2
    exit 1
  fi
}

have_release_signing_env() {
  local var
  for var in \
    ANDROID_KEYSTORE_PATH \
    ANDROID_KEYSTORE_PASSWORD \
    ANDROID_KEY_ALIAS \
    ANDROID_KEY_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      return 1
    fi
  done
  return 0
}

have_any_release_signing_env() {
  local var
  for var in \
    ANDROID_KEYSTORE_PATH \
    ANDROID_KEYSTORE_PASSWORD \
    ANDROID_KEY_ALIAS \
    ANDROID_KEY_PASSWORD; do
    if [[ -n "${!var:-}" ]]; then
      return 0
    fi
  done
  return 1
}

resolve_android_sdk_dir() {
  local candidate=""

  if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}" ]]; then
    printf '%s\n' "${ANDROID_HOME}"
    return 0
  fi

  if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}" ]]; then
    printf '%s\n' "${ANDROID_SDK_ROOT}"
    return 0
  fi

  if [[ -f "$ANDROID_DIR/local.properties" ]]; then
    candidate="$(sed -n 's/^sdk\\.dir=//p' "$ANDROID_DIR/local.properties" | head -n 1)"
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  for candidate in \
    "$HOME/Library/Android/sdk" \
    "$HOME/Android/Sdk" \
    "$HOME/AppData/Local/Android/Sdk"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_android_sdk_config() {
  local sdk_dir="$1"
  export ANDROID_HOME="$sdk_dir"
  export ANDROID_SDK_ROOT="$sdk_dir"

  if [[ ! -f "$ANDROID_DIR/local.properties" ]]; then
    printf 'sdk.dir=%s\n' "$sdk_dir" > "$ANDROID_DIR/local.properties"
    echo "Created android-java/local.properties using detected SDK: $sdk_dir"
  fi
}

ensure_auto_release_keystore() {
  local keystore_dir="$1"
  local keystore_path="$2"
  local alias="$3"
  local password="$4"
  local dname="$5"

  if [[ -f "$keystore_path" ]]; then
    echo "Reusing local release keystore: $keystore_path"
    echo "Back up this file. Future app updates must use the same signing key."
    return 0
  fi

  if ! command -v keytool >/dev/null 2>&1; then
    echo "ERROR: keytool is required to generate a local Android release keystore." >&2
    echo "Install keytool (usually via a JDK) or provide ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD." >&2
    exit 1
  fi
  mkdir -p "$keystore_dir"
  chmod 700 "$keystore_dir" 2>/dev/null || true

  (
    umask 077
    keytool -genkeypair -v \
      -keystore "$keystore_path" \
      -storetype PKCS12 \
      -storepass "$password" \
      -alias "$alias" \
      -keypass "$password" \
      -keyalg RSA \
      -keysize 2048 \
      -validity 10000 \
      -dname "$dname"
  )

  echo "Generated local release keystore: $keystore_path"
  echo "Back up this file. Future app updates must use the same signing key."
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/version_helpers.sh
source "$ROOT_DIR/scripts/version_helpers.sh"
CANONICAL_SERVER_VERSION="$(read_cargo_package_version "$ROOT_DIR")"
ANDROID_DIR="$ROOT_DIR/android-java"
GRADLEW="$ANDROID_DIR/gradlew"
RELEASE_APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
AUTO_KEYSTORE_DIR="$ANDROID_DIR/.openphotos-signing"
AUTO_KEYSTORE_PATH="$AUTO_KEYSTORE_DIR/openphotos-auto-release.jks"
AUTO_KEY_ALIAS="openphotos-auto-release"
AUTO_KEY_PASSWORD="openphotos-auto-release"
AUTO_KEY_DNAME="CN=OpenPhotos,O=OpenPhotos,C=CA"

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist/android-packages}"
REBUILD="1"
BUILD_KEYSTORE_PATH=""
BUILD_KEYSTORE_PASSWORD=""
BUILD_KEY_ALIAS=""
BUILD_KEY_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --output-dir requires a value" >&2; exit 1; }
      OUTPUT_DIR="$(resolve_repo_path "$ROOT_DIR" "$2")"
      shift 2
      ;;
    --no-build)
      REBUILD="0"
      shift
      ;;
    --rebuild)
      REBUILD="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd cp
require_cmd mkdir
require_cmd sed
require_dir "$ANDROID_DIR" "Android project directory"
require_file "$GRADLEW" "Gradle wrapper"

if [[ "$REBUILD" == "1" ]]; then
  echo "Android release version: $CANONICAL_SERVER_VERSION"
  if have_any_release_signing_env; then
    validate_release_signing_env
    BUILD_KEYSTORE_PATH="$ANDROID_KEYSTORE_PATH"
    BUILD_KEYSTORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD"
    BUILD_KEY_ALIAS="$ANDROID_KEY_ALIAS"
    BUILD_KEY_PASSWORD="$ANDROID_KEY_PASSWORD"
    echo "Using provided Android release signing keystore: $BUILD_KEYSTORE_PATH"
  else
    ensure_auto_release_keystore \
      "$AUTO_KEYSTORE_DIR" \
      "$AUTO_KEYSTORE_PATH" \
      "$AUTO_KEY_ALIAS" \
      "$AUTO_KEY_PASSWORD" \
      "$AUTO_KEY_DNAME"
    BUILD_KEYSTORE_PATH="$AUTO_KEYSTORE_PATH"
    BUILD_KEYSTORE_PASSWORD="$AUTO_KEY_PASSWORD"
    BUILD_KEY_ALIAS="$AUTO_KEY_ALIAS"
    BUILD_KEY_PASSWORD="$AUTO_KEY_PASSWORD"
  fi

  if ! SDK_DIR="$(resolve_android_sdk_dir)"; then
    echo "ERROR: Android SDK location not found." >&2
    echo "Set ANDROID_HOME or ANDROID_SDK_ROOT, or create android-java/local.properties with sdk.dir=/absolute/path/to/Android/sdk." >&2
    exit 1
  fi
  ensure_android_sdk_config "$SDK_DIR"

  (
    cd "$ANDROID_DIR"
    OPENPHOTOS_SERVER_VERSION="$CANONICAL_SERVER_VERSION" \
    ANDROID_KEYSTORE_PATH="$BUILD_KEYSTORE_PATH" \
    ANDROID_KEYSTORE_PASSWORD="$BUILD_KEYSTORE_PASSWORD" \
    ANDROID_KEY_ALIAS="$BUILD_KEY_ALIAS" \
    ANDROID_KEY_PASSWORD="$BUILD_KEY_PASSWORD" \
    ./gradlew :app:assembleRelease
  )
fi

require_file "$RELEASE_APK" "release APK"

mkdir -p "$OUTPUT_DIR"
DEST_APK="$OUTPUT_DIR/openphotos-android-release.apk"
cp -f "$RELEASE_APK" "$DEST_APK"

echo "Android installer created: $DEST_APK"
