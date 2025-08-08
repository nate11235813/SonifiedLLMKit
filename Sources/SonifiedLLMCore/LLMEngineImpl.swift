// This file intentionally only compiles when the binary runtime is available.
#if canImport(SonifiedLLMRuntime)
import Foundation
@preconcurrency import SonifiedLLMRuntime

final class LLMEngineImpl: LLMEngine, @unchecked Sendable {
    private var isLoaded: Bool = false
    private var _stats: LLMMetrics = .init()

    func load(modelURL: URL, spec: LLMModelSpec) async throws {
        // TODO: call C shim: llm_init(modelURL, spec)
        isLoaded = true
    }

    func unload() async {
        // TODO: call C shim: llm_free()
        isLoaded = false
    }

    func cancelCurrent() {
        // TODO: call C shim: llm_cancel()
    }

    func generate(prompt: String, options: GenerateOptions) -> AsyncStream<LLMEvent> {
        // TODO: call C shim: llm_eval(prompt, options)
        return AsyncStream { continuation in
            continuation.yield(.token(""))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    var stats: LLMMetrics {
        // TODO: call C shim: llm_stats()
        _stats
    }
}
#endif


