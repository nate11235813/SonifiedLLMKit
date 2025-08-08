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
