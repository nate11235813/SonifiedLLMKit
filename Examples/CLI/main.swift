import Foundation
import SonifiedLLMCore
import SonifiedLLMDownloader

// Usage: swift run CLI "your prompt here"
@main
struct App {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        guard args.count > 0 else {
            fputs("Usage: CLI \"your prompt\"\n", stderr)
            exit(2)
        }
        let prompt = args.joined(separator: " ")
        let engine = EngineFactory.makeDefaultEngine()
        let store = FileModelStore()
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        do {
            let location = try await store.ensureAvailable(spec: spec)
            try await engine.load(modelURL: location.url, spec: spec)
            let start = Date()

            var sawFirstMetrics = false
            for try await ev in engine.generate(prompt: prompt, options: .init(maxTokens: 64)) {
                switch ev {
                case .metrics(let m):
                    if !sawFirstMetrics {
                        sawFirstMetrics = true
                        fputs(String(format: "TTFB: %d ms\n", m.ttfbMs), stderr)
                    } else {
                        fputs(String(format: "tok/s: %.2f  total: %d ms  tokens: %d (p:%d c:%d)  success: %@\n", m.tokPerSec, m.totalDurationMillis, m.totalTokens, m.promptTokens, m.completionTokens, m.success ? "true" : "false"), stderr)
                    }
                case .token(let t):
                    print(t, terminator: "")
                    fflush(stdout)
                case .done:
                    print("")
                }
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            fputs("Done in \(elapsed) ms\n", stderr)
            await engine.unload()
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            if let e = error as? LocalizedError, let suggestion = e.recoverySuggestion {
                fputs("Suggestion: \(suggestion)\n", stderr)
            }
            exit(1)
        }
    }
}
