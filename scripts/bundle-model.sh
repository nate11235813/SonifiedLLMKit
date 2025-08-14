#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   make bundle-model NAME=gpt-oss-20b QUANT=q4_K_M PATH=/abs/model.gguf
# or:
#   scripts/bundle-model.sh gpt-oss-20b q4_K_M /abs/model.gguf

if [[ $# -eq 3 ]]; then
  NAME="$1"; QUANT="$2"; SRC="$3"
else
  NAME="${NAME:-}"
  QUANT="${QUANT:-}"
  SRC="${PATH:-}"
fi

if [[ -z "${NAME}" || -z "${QUANT}" || -z "${SRC}" ]]; then
  echo "Usage: bundle-model.sh <NAME> <QUANT> </abs/path/to/model.gguf>" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${REPO_ROOT}/Models/${NAME}"
DEST_FILE="${MODELS_DIR}/${NAME}-${QUANT}.gguf"

mkdir -p "${MODELS_DIR}"
cp -f "${SRC}" "${DEST_FILE}"
echo "Copied to ${DEST_FILE}"

# Build and run the index generator
pushd "${REPO_ROOT}" >/dev/null
swift build -c release --product ModelIndexGen >/dev/null
"${REPO_ROOT}/.build/release/ModelIndexGen" --models "${REPO_ROOT}/Models" --out "${REPO_ROOT}/BundledModels/index.json" --embedded true
popd >/dev/null

echo "Updated BundledModels/index.json"


