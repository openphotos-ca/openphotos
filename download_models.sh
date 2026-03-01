#!/usr/bin/env bash
set -euo pipefail

# Download runtime models that are too large for GitHub source uploads.
# Usage:
#   ./download_models.sh
#   ./download_models.sh /path/to/models
# Optional:
#   DOWNLOAD_FACE=0 ./download_models.sh   # skip face models

MODEL_DIR="${1:-models}"
CLIP_MODEL_DIR="${MODEL_DIR}/ViT-B-32__openai"
FACE_MODEL_DIR="${MODEL_DIR}/face"
DOWNLOAD_FACE="${DOWNLOAD_FACE:-1}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

download_if_missing() {
  local url="$1"
  local dst="$2"
  local label="$3"

  mkdir -p "$(dirname "$dst")"

  if [[ -s "$dst" ]]; then
    echo "✓ ${label} already exists: $dst"
    return 0
  fi

  local tmp="${dst}.tmp.$$"
  rm -f "$tmp"
  echo "↓ Downloading ${label}..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar "$url" -o "$tmp"
  mv "$tmp" "$dst"
  echo "✓ Saved ${label}: $dst"
}

require_cmd curl

mkdir -p "$CLIP_MODEL_DIR"
mkdir -p "$FACE_MODEL_DIR"

echo "Downloading OpenPhotos runtime models into: $MODEL_DIR"
echo

download_if_missing \
  "https://huggingface.co/SpotLab/YOLOv8Detection/resolve/3005c6751fb19cdeb6b10c066185908faf66a097/yolov8n.onnx" \
  "${MODEL_DIR}/yolov8n.onnx" \
  "yolov8n.onnx"
download_if_missing \
  "https://github.com/CVHub520/X-AnyLabeling/releases/download/v2.3.7/yolov8m-oiv7.onnx" \
  "${MODEL_DIR}/yolov8m-oiv7.onnx" \
  "yolov8m-oiv7.onnx"


# Required CLIP model files
download_if_missing \
  "https://huggingface.co/immich-app/ViT-B-32__openai/resolve/main/textual/model.onnx" \
  "${CLIP_MODEL_DIR}/textual.onnx" \
  "CLIP textual.onnx"

download_if_missing \
  "https://huggingface.co/immich-app/ViT-B-32__openai/resolve/main/visual/model.onnx" \
  "${CLIP_MODEL_DIR}/visual.onnx" \
  "CLIP visual.onnx"

download_if_missing \
  "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main/tokenizer.json" \
  "${CLIP_MODEL_DIR}/tokenizer.json" \
  "CLIP tokenizer.json"

if [[ "$DOWNLOAD_FACE" == "1" ]]; then
  download_if_missing \
    "https://huggingface.co/maze/faceX/resolve/main/det_10g.onnx" \
    "${FACE_MODEL_DIR}/det_10g.onnx" \
    "Face det_10g.onnx"

  download_if_missing \
    "https://huggingface.co/maze/faceX/resolve/e010b5098c3685fd00b22dd2aec6f37320e3d850/w600k_r50.onnx" \
    "${FACE_MODEL_DIR}/w600k_r50.onnx" \
    "Face w600k_r50.onnx"
else
  echo "Skipping face model download (DOWNLOAD_FACE=0)."
fi

echo
echo "Model download complete."
echo "Downloaded files:"
find "$MODEL_DIR" -type f \( -name "*.onnx" -o -name "tokenizer.json" \) -print | sed 's#^#  - #'
