# SonifiedLLMKit (bootstrap)

A Swift Package skeleton for a **local LLM SDK for macOS**. It compiles today using a mock engine so you can set up CI and iterate before the Metal runtime is ready.

## Targets
- `SonifiedLLMCore` – Public API, PromptBuilder, MockLLMEngine, EngineFactory
- `SonifiedLLMDownloader` – `ModelStore` stub (resumable/background download to be implemented)
- `SonifiedLLMUI` – Optional SwiftUI PreflightView placeholder
- `CLI` – Minimal async streaming demo

## Quick start

```bash
swift build
swift test
swift run CLI "Write one sentence about local LLMs on macOS."
```

## Next steps
- Replace `MockLLMEngine` with your Metal `LLMEngineImpl` backed by a `SonifiedLLMRuntime.xcframework` (binary target).
- Implement background downloads + SHA256 verification in `SonifiedLLMDownloader`.
- Add DocC, App Store notes, and Troubleshooting.

## Submodules

We vendor `llama.cpp` as a git submodule pinned to a specific commit for reproducible builds.

Clone and initialize submodules:

```bash
git submodule update --init --recursive
```

To add or update the submodule locally (do not run in CI; documented here for contributors):

```bash
git submodule add https://github.com/ggerganov/llama.cpp.git vendor/llama.cpp
(cd vendor/llama.cpp && git checkout <PINNED_COMMIT>)
git commit -m "chore(vendor): add llama.cpp submodule @ <PINNED_COMMIT>"
```

We intentionally pin the commit to ensure the native runtime builds are reproducible across machines.

## Building the native runtime (static libs)

Build Metal-enabled static libraries for `llama.cpp` for both `arm64` and `x86_64`:

```bash
bash scripts/build_runtime_static.sh
```

Outputs:
- `build/runtime/arm64` – arm64 Release static libs
- `build/runtime/x86_64` – x86_64 Release static libs

Troubleshooting:
- Ensure Xcode + Command Line Tools are installed (`xcode-select -p`)
- If CMake cannot find the SDK, set: `export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"`
- On Apple Silicon, cross-building x86_64 is supported via `CMAKE_OSX_ARCHITECTURES`

## Packaging the XCFramework

Create a universal `SonifiedLLMRuntime.xcframework` from the static libs and headers in `RuntimeShim/include`:

```bash
bash scripts/make_runtime_xcframework.sh
```

Outputs under `dist/`:
- `SonifiedLLMRuntime.xcframework`
- `SonifiedLLMRuntime.xcframework.zip`
- `SonifiedLLMRuntime.checksum.txt` (for SwiftPM binary target)
