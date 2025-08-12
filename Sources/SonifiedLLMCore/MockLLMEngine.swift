import Foundation

final class MockLLMEngine: LLMEngine {
    private var isLoaded = false
    private var currentTask: Task<Void, Never>?
    private var _stats = LLMMetrics()
    private var isCancelledFlag = false

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
        isCancelledFlag = true
        currentTask?.cancel()
    }

    func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            guard isLoaded else {
                continuation.finish(throwing: LLMError.notLoaded)
                return
            }

            let start = DispatchTime.now().uptimeNanoseconds
            self.isCancelledFlag = false
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
                    if Task.isCancelled || isCancelledFlag { break }
                    continuation.yield(.token(w + " "))
                    tokensEmitted += 1
                    try? await Task.sleep(nanoseconds: tokenDelayNs)
                    if tokensEmitted >= options.maxTokens { break }
                }

                let total = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                let tps = tokensEmitted > 0 && total > ttfb ? Double(tokensEmitted) / (Double(total - ttfb) / 1000.0) : 0

                // final metrics (success reflects cancellation)
                let finalMetrics = LLMMetrics(ttfbMillis: ttfb, tokPerSec: tps, totalDurationMillis: total, success: !isCancelledFlag)
                _stats = finalMetrics
                continuation.yield(.metrics(finalMetrics))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }
}
