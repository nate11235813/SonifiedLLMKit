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
                let approximatePromptTokens = max(0, prompt.split { $0.isWhitespace || $0.isNewline }.count)

                // Emit a canned response deterministically based on prompt hash.
                let base = "Local LLMs on macOS can stream tokens with low latency using Metal-accelerated runtimes."
                let words = base.split(separator: " ").map(String.init)

                continuation.yield(.metrics(LLMMetrics(ttfbMs: ttfb, promptTokens: approximatePromptTokens, completionTokens: 0, totalTokens: approximatePromptTokens)))

                // Optional simulated tool-call, gated strictly by marker [[tool:...]] or demo env flag
                // Supported shape: [[tool:math:EXPR]]
                let demoToolEnv = ProcessInfo.processInfo.environment["SONIFIED_DEMO_TOOLCALL"] == "1"
                var shouldEmitTool = false
                var toolName = ""
                var toolExpr = ""
                if let startRange = prompt.range(of: "[[tool:"), let endRange = prompt.range(of: "]]", range: startRange.upperBound..<prompt.endIndex) {
                    let inner = String(prompt[startRange.upperBound..<endRange.lowerBound]) // e.g., "math:2^8"
                    if let sep = inner.firstIndex(of: ":") {
                        toolName = String(inner[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
                        toolExpr = String(inner[inner.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        shouldEmitTool = !toolName.isEmpty && !toolExpr.isEmpty
                    }
                } else if demoToolEnv {
                    toolName = "math"
                    toolExpr = "2^8"
                    shouldEmitTool = true
                }
                if shouldEmitTool && toolName == "math" {
                    let json = "{\"tool\":{\"name\":\"math\",\"arguments\":{\"expression\":\"\(toolExpr)\"}}}"
                    if !Task.isCancelled && !isCancelledFlag {
                        continuation.yield(.token(json))
                        tokensEmitted += 1
                        // Give the orchestrator a moment to cancel leg1 after detecting the tool call
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }

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
                let finalMetrics = LLMMetrics(
                    ttfbMs: ttfb,
                    promptTokens: approximatePromptTokens,
                    completionTokens: tokensEmitted,
                    totalTokens: approximatePromptTokens + tokensEmitted,
                    tokPerSec: tps,
                    totalDurationMillis: total,
                    success: !isCancelledFlag
                )
                _stats = finalMetrics
                continuation.yield(.metrics(finalMetrics))
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }
}
