import Foundation
import SonifiedLLMCore
import SonifiedLLMDownloader

// Usage: swift run CLI "your prompt here"
@main
struct App {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var modelPath: String? = nil
        var ctxOverride: Int? = nil
        var opts = GenerateOptions()
        var greedy = false

        // Parse flags
        var positionals: [String] = []
        func popNext(_ i: inout Int) -> String? { guard i + 1 < args.count else { return nil }; i += 1; return args[i] }
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--model": modelPath = popNext(&i)
            case "--ctx": if let v = popNext(&i), let n = Int(v) { ctxOverride = n }
            case "--max-tokens": if let v = popNext(&i), let n = Int(v) { opts.maxTokens = n }
            case "--temp": if let v = popNext(&i), let d = Double(v) { opts.temperature = d }
            case "--top-p": if let v = popNext(&i), let d = Double(v) { opts.topP = d }
            case "--top-k": if let v = popNext(&i), let n = Int(v) { opts.topK = n }
            case "--repeat-penalty": if let v = popNext(&i), let d = Double(v) { opts.repeatPenalty = d }
            case "--seed": if let v = popNext(&i), let n = Int(v) { opts.seed = n }
            case "--greedy": greedy = true
            default:
                positionals.append(a)
            }
            i += 1
        }
        if greedy { opts.greedy = true; opts.temperature = 0 }
        guard positionals.isEmpty == false else {
            fputs("Usage: CLI [--model <path>] [--ctx <int>] [--max-tokens <int>] [--temp <float>] [--top-p <float>] [--top-k <int>] [--repeat-penalty <float>] [--seed <int>] [--greedy] \"your prompt\"\n", stderr)
            exit(2)
        }
        let prompt = positionals.joined(separator: " ")
        let engine = EngineFactory.makeDefaultEngine()
        let store = FileModelStore()
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: ctxOverride ?? 4096)
        do {
            // Env override must be set before runtime init
            if let ctxOverride { setenv("SONIFIED_CTX", String(ctxOverride), 1) }

            let location: ModelLocation
            if let modelPath {
                location = ModelLocation(url: URL(fileURLWithPath: modelPath), source: .downloaded)
            } else {
                location = try await store.ensureAvailable(spec: spec)
            }
            try await engine.load(modelURL: location.url, spec: spec)
            let start = Date()

            var sawFirstMetrics = false
            for try await ev in engine.generate(prompt: prompt, options: opts) {
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
