#!/usr/bin/env bash
set -euo pipefail

# Builds Release static libraries for llama.cpp (GGUF) for macOS:
# - arm64: Metal GPU acceleration enabled, ensure Accelerate is linked
# - x86_64: CPU-only fallback, disable native CPU optimizations
#
# Requirements:
# - Xcode + Command Line Tools (xcode-select -p)
# - If CMake cannot find the macOS SDK, try:
#     export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
# - On Apple Silicon, cross-building x86_64 is supported via CMAKE_OSX_ARCHITECTURES
# - llama.cpp may produce multiple static libs (ggml, ggml-cpu, ggml-metal, ggml-blas, common, etc.) — expected.

LLAMA_DIR="${LLAMA_DIR:-vendor/llama.cpp}"
BUILD_DIR="${BUILD_DIR:-build/runtime}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.3}"

# Toolchain helpers
CLANG="$(xcrun -f clang)"
LIBTOOL="$(xcrun -f libtool)"
HEADERS="RuntimeShim/include"

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
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_COMMON=OFF \
  -DLLAMA_CURL=OFF \
  -DLLAMA_LLGUIDANCE=OFF \
  -DGGML_METAL=ON \
  -DGGML_ACCELERATE=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_NDEBUG=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# Verify arm64 configuration
cache="$BUILD_DIR/arm64/CMakeCache.txt"
get() { grep -E "^$1(:[A-Z]+)?=" "$cache" | head -1 | cut -d= -f2; }
if [[ "$(get GGML_METAL)" != "ON" ]]; then
  echo "error: arm64 build expected GGML_METAL=ON but found '$(get GGML_METAL)'" >&2
  exit 1
fi

echo "==> Building (arm64)"
cmake --build "$BUILD_DIR/arm64" --config Release

# Create per-arch unified static lib for verification
echo "==> Preparing arm64 unified static lib for verification"
mkdir -p "$BUILD_DIR/arm64"
"$CLANG" -arch arm64 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -mmacosx-version-min="$DEPLOYMENT_TARGET" -I "$HEADERS" -std=c11 -O2 \
  -c RuntimeShim/src/sonified_llama_stub.c -o "$BUILD_DIR/arm64/sonified_llama_stub.o"
"$LIBTOOL" -static -o "$BUILD_DIR/arm64/libsonified_llama.a" \
  "$BUILD_DIR/arm64/sonified_llama_stub.o" \
  "$BUILD_DIR/arm64/src/libllama.a" \
  "$BUILD_DIR/arm64/ggml/src/libggml.a" \
  "$BUILD_DIR/arm64/ggml/src/libggml-cpu.a" \
  "$BUILD_DIR/arm64/ggml/src/ggml-metal/libggml-metal.a" \
  "$BUILD_DIR/arm64/ggml/src/ggml-blas/libggml-blas.a" \
  "$BUILD_DIR/arm64/ggml/src/libggml-base.a"

echo "==> Verify arm64 includes embedded metallib"
if ! nm -g "$BUILD_DIR/arm64/libsonified_llama.a" | grep -q _ggml_metallib_start; then
  if nm -g "$BUILD_DIR/arm64/ggml/src/ggml-metal/libggml-metal.a" | grep -q _ggml_metallib_start; then
    echo "warn: metallib symbol found in ggml-metal.a but not detected in unified lib; continuing"
  else
    echo "error: arm64 metallib not embedded" >&2
    exit 1
  fi
fi

echo "==> Configuring (x86_64)"
cmake -S "$LLAMA_DIR" -B "$BUILD_DIR/x86_64" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_COMMON=OFF \
  -DLLAMA_CURL=OFF \
  -DLLAMA_LLGUIDANCE=OFF \
  -DGGML_METAL=OFF \
  -DGGML_BLAS=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_CPU_TARGET=x86-64 \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# Verify x86_64 configuration
cache="$BUILD_DIR/x86_64/CMakeCache.txt"
get() { grep -E "^$1(:[A-Z]+)?=" "$cache" | head -1 | cut -d= -f2; }
if [[ "$(get GGML_METAL)" == "ON" ]]; then
  echo "error: x86_64 build expected GGML_METAL=OFF but found ON" >&2
  exit 1
fi
if [[ "$(get GGML_NATIVE)" == "ON" ]]; then
  echo "error: x86_64 build expected GGML_NATIVE=OFF but found ON" >&2
  exit 1
fi

echo "==> Building (x86_64)"
cmake --build "$BUILD_DIR/x86_64" --config Release

# Create per-arch unified static lib for verification
echo "==> Preparing x86_64 unified static lib for verification"
mkdir -p "$BUILD_DIR/x86_64"
"$CLANG" -arch x86_64 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -mmacosx-version-min="$DEPLOYMENT_TARGET" -I "$HEADERS" -std=c11 -O2 \
  -c RuntimeShim/src/sonified_llama_stub.c -o "$BUILD_DIR/x86_64/sonified_llama_stub.o"
"$LIBTOOL" -static -o "$BUILD_DIR/x86_64/libsonified_llama.a" \
  "$BUILD_DIR/x86_64/sonified_llama_stub.o" \
  "$BUILD_DIR/x86_64/src/libllama.a" \
  "$BUILD_DIR/x86_64/ggml/src/libggml.a" \
  "$BUILD_DIR/x86_64/ggml/src/libggml-cpu.a" \
  "$BUILD_DIR/x86_64/ggml/src/ggml-blas/libggml-blas.a" \
  "$BUILD_DIR/x86_64/ggml/src/libggml-base.a"

echo "==> Verify x86_64 has no Metal symbols"
nm -gU "$BUILD_DIR/x86_64/libsonified_llama.a" | egrep -i 'metal|ggml_metallib' && { echo "error: x86_64 contains metal symbols" >&2; exit 1; } || echo "ok: no metal symbols"

# Additional strict metal check on x86_64 unified archive
UNIFIED_X86="$BUILD_DIR/x86_64/libsonified_llama.a"
nm -g "$UNIFIED_X86" | egrep -i 'ggml_metallib|metal' && { echo "error: metal symbols found in x86_64 build" >&2; exit 1; } || true

echo "\n==> Static libraries (arm64):"
find "$BUILD_DIR/arm64" -type f -name "lib*.a" -print | sort || true

echo "\n==> Static libraries (x86_64):"
find "$BUILD_DIR/x86_64" -type f -name "lib*.a" -print | sort || true

echo "\nDone. Outputs are under:"
echo "  $BUILD_DIR/arm64"
echo "  $BUILD_DIR/x86_64"

# Final summary
cache="$BUILD_DIR/arm64/CMakeCache.txt"
get() { grep -E "^$1(:[A-Z]+)?=" "$cache" | head -1 | cut -d= -f2; }
echo "\nSummary:"
echo "arm64: $(get GGML_METAL) metal, $(get GGML_BLAS) blas"
cache="$BUILD_DIR/x86_64/CMakeCache.txt"
get() { grep -E "^$1(:[A-Z]+)?=" "$cache" | head -1 | cut -d= -f2; }
echo "x86_64: metal=$(get GGML_METAL), native=$(get GGML_NATIVE), cpu_target=$(get GGML_CPU_TARGET)"


