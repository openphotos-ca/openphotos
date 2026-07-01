#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/build_docker_image.sh" --oss --platform linux/arm64 --tag openphotos:arm64 "$@"
docker tag openphotos:arm64 ghcr.io/openphotos-ca/openphotos-arm64:oss
docker push ghcr.io/openphotos-ca/openphotos-arm64:oss
