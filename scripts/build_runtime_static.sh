#!/usr/bin/env bash
set -euo pipefail

# Builds Release static libraries for llama.cpp with Metal enabled
# - Requires: Xcode + Command Line Tools (xcode-select -p)
# - If CMake cannot find the macOS SDK, try:
#     export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
# - On Apple Silicon, cross-building x86_64 is supported via CMAKE_OSX_ARCHITECTURES
# - If llama.cpp produces multiple static libs (e.g., ggml, ggml-metal), that's expected.

LLAMA_DIR="${LLAMA_DIR:-vendor/llama.cpp}"
BUILD_DIR="${BUILD_DIR:-build/runtime}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"

if ! command -v cmake >/dev/null 2>&1; then
  echo "error: cmake not found. Install via Xcode command line tools or Homebrew." >&2
  exit 1
fi

if [[ ! -d "$LLAMA_DIR" || ! -f "$LLAMA_DIR/CMakeLists.txt" ]]; then
  echo "error: $LLAMA_DIR not found or missing CMakeLists.txt." >&2
  echo "hint: Initialize submodules: git submodule update --init --recursive" >&2
  exit 1
fi

echo "==> Cleaning build directories"
rm -rf "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64"
mkdir -p "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64"

echo "==> Configuring (arm64)"
cmake -S "$LLAMA_DIR" -B "$BUILD_DIR/arm64" \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_METAL=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

echo "==> Building (arm64)"
cmake --build "$BUILD_DIR/arm64" --config Release

echo "==> Configuring (x86_64)"
 cmake -S "$LLAMA_DIR" -B "$BUILD_DIR/x86_64" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
  -DGGML_NATIVE=OFF -DGGML_CPU_TARGET=x86-64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

echo "==> Building (x86_64)"
cmake --build "$BUILD_DIR/x86_64" --config Release

echo "\n==> Static libraries (arm64):"
find "$BUILD_DIR/arm64" -type f -name "lib*.a" -print | sort || true

echo "\n==> Static libraries (x86_64):"
find "$BUILD_DIR/x86_64" -type f -name "lib*.a" -print | sort || true

echo "\nDone. Outputs are under:"
echo "  $BUILD_DIR/arm64"
echo "  $BUILD_DIR/x86_64"


