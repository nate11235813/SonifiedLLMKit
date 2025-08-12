#!/usr/bin/env bash
set -euo pipefail

# Combines per-arch static libraries from llama.cpp into a unified archive per arch
# and creates SonifiedLLMRuntime.xcframework using public headers in RuntimeShim/include.
#
# Prereqs:
# - Run scripts/build_runtime_static.sh first (to produce static libs under build/runtime/...)
# - Xcode + Command Line Tools installed (xcode-select -p)
# - If SDK not found, set: export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

OUT_DIR="${OUT_DIR:-dist}"
BUILD_DIR="${BUILD_DIR:-build/runtime}"
FRAME="${FRAME:-SonifiedLLMRuntime}"
HEADERS="${HEADERS:-RuntimeShim/include}"

# Toolchain binaries (use Xcode tools)
CLANG="$(xcrun -f clang)"
LIBTOOL="$(xcrun -f libtool)"
XCODEBUILD="$(xcrun -f xcodebuild)"
LIPO="$(xcrun -f lipo)"

mkdir -p "$OUT_DIR"

export MACOSX_DEPLOYMENT_TARGET=13.0

# Prerequisite checks
if [[ ! -d vendor/llama.cpp || ! -f vendor/llama.cpp/CMakeLists.txt ]]; then
  echo "error: vendor/llama.cpp not found or missing CMakeLists.txt." >&2
  echo "hint: Initialize submodules: git submodule update --init --recursive" >&2
  exit 1
fi

if [[ ! -f "$BUILD_DIR/arm64/src/libllama.a" || ! -f "$BUILD_DIR/x86_64/src/libllama.a" ]]; then
  echo "error: Missing built static libs. Expected:" >&2
  echo "  $BUILD_DIR/arm64/src/libllama.a" >&2
  echo "  $BUILD_DIR/x86_64/src/libllama.a" >&2
  echo "hint: Run scripts/build_runtime_static.sh first" >&2
  exit 1
fi

function compile_stub() {
  local arch="$1"
  local sysroot="$(xcrun --sdk macosx --show-sdk-path)"
  local out_o="$BUILD_DIR/$arch/sonified_llama_stub.o"
  mkdir -p "$BUILD_DIR/$arch"
  echo "==> Compiling shim stub ($arch)"
  "$CLANG" -arch "$arch" -isysroot "$sysroot" -mmacosx-version-min=13.0 -I "$HEADERS" -I "vendor/llama.cpp/include" -I "vendor/llama.cpp/ggml/include" -std=c11 -O2 \
    -c RuntimeShim/src/sonified_llama_stub.c -o "$out_o"
}

function combine() {
  local arch="$1"
  local outlib="$BUILD_DIR/$arch/libsonified_llama.a"
  local root="$BUILD_DIR/$arch"

  # Candidate libs to include if present
  local libs=(
    "$root/sonified_llama_stub.o"
    "$root/src/libllama.a"
    "$root/ggml/src/libggml.a"
    "$root/ggml/src/libggml-cpu.a"
    "$root/ggml/src/ggml-metal/libggml-metal.a"
    "$root/ggml/src/ggml-blas/libggml-blas.a"
    "$root/ggml/src/libggml-base.a"
    "$root/common/libcommon.a"
  )

  local existing=()
  for f in "${libs[@]}"; do
    if [[ -f "$f" ]]; then existing+=("$f"); fi
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    echo "error: No static libs found under $root. Did you run scripts/build_runtime_static.sh?" >&2
    exit 1
  fi

  echo "==> Creating unified static lib ($arch): $outlib"
  "$LIBTOOL" -static -o "$outlib" "${existing[@]}"
  echo "    included $((${#existing[@]})) objects"
}

compile_stub arm64
compile_stub x86_64
combine arm64
combine x86_64

echo "==> Creating universal static lib via lipo"
mkdir -p "$BUILD_DIR/universal"
"$LIPO" -create \
  "$BUILD_DIR/arm64/libsonified_llama.a" \
  "$BUILD_DIR/x86_64/libsonified_llama.a" \
  -output "$BUILD_DIR/universal/libsonified_llama.a"

echo "==> Building XCFramework: $OUT_DIR/$FRAME.xcframework"
# Clean stale artifacts
rm -rf "$OUT_DIR/$FRAME.xcframework"
rm -f "$OUT_DIR/$FRAME.xcframework.zip" "$OUT_DIR/$FRAME.checksum.txt"
"$XCODEBUILD" -create-xcframework \
  -library "$BUILD_DIR/universal/libsonified_llama.a" -headers "$HEADERS" \
  -output "$OUT_DIR/$FRAME.xcframework"

echo "==> Zipping XCFramework"
(cd "$OUT_DIR" && zip -r "$FRAME.xcframework.zip" "$FRAME.xcframework" >/dev/null)

echo "==> Computing checksum"
swift package compute-checksum "$OUT_DIR/$FRAME.xcframework.zip" | tee "$OUT_DIR/$FRAME.checksum.txt"

echo "\n==> Universal lib: $BUILD_DIR/universal/libsonified_llama.a"
echo "==> XCFramework: $OUT_DIR/$FRAME.xcframework"
echo "==> ZIP:        $OUT_DIR/$FRAME.xcframework.zip"
echo "==> Checksum:   $(cat "$OUT_DIR/$FRAME.checksum.txt")"


