import Foundation

final class MockLLMEngine: LLMEngine {
    private var isLoaded = false
    private var currentTask: Task<Void, Never>?
    private var _stats = LLMMetrics()

    public var stats: LLMMetrics { _stats }

    func load(modelURL: URL, spec: LLMModelSpec) async throws {
        // In the mock, just simulate a load delay.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        isLoaded = true
    }

    func unload() async {
        cancelCurrent()
        isLoaded = false
    }

    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }

    func generate(prompt: String, options: GenerateOptions) -> AsyncStream<LLMEvent> {
        guard isLoaded else {
            return AsyncStream { cont in
                cont.yield(.metrics(LLMMetrics(success: false)))
                cont.finish()
            }
        }

        let start = DispatchTime.now().uptimeNanoseconds
        return AsyncStream { continuation in
            currentTask = Task {
                // Simulate TTFB
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

                let ttfb = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                var tokensEmitted = 0

                // Emit a canned response deterministically based on prompt hash.
                let base = "Local LLMs on macOS can stream tokens with low latency using Metal-accelerated runtimes."
                let words = base.split(separator: " ").map(String.init)

                continuation.yield(.metrics(LLMMetrics(ttfbMillis: ttfb)))

                let tokenDelayNs: UInt64 = 40_000_000 // 25 tok/s
                for w in words {
                    if Task.isCancelled { break }
                    continuation.yield(.token(w + " "))
                    tokensEmitted += 1
                    try? await Task.sleep(nanoseconds: tokenDelayNs)
                    if tokensEmitted >= options.maxTokens { break }
                }

                let total = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                let tps = tokensEmitted > 0 ? Double(tokensEmitted) / (Double(total - ttfb) / 1000.0) : 0

                _stats = LLMMetrics(ttfbMillis: ttfb, tokPerSec: tps, totalDurationMillis: total, success: true)
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }
}
