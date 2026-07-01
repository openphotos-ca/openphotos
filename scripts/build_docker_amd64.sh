#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/build_docker_image.sh" --oss --platform linux/amd64 --tag openphotos:amd64 "$@"
docker tag openphotos:amd64 ghcr.io/openphotos-ca/openphotos-amd64:oss
docker push ghcr.io/openphotos-ca/openphotos-amd64:oss
