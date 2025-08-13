import Foundation
import HarmonyKit
import SonifiedLLMCore
import SonifiedLLMDownloader

// Usage: swift run HarmonyCLI "your message here"
@main
struct HarmonyApp {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.isEmpty == false else {
            fputs("Usage: HarmonyCLI [--max-tokens <int>] \"your message\"\n", stderr)
            exit(2)
        }

        var opts = GenerateOptions()
        var positionals: [String] = []
        func popNext(_ i: inout Int) -> String? { guard i + 1 < args.count else { return nil }; i += 1; return args[i] }
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--max-tokens": if let v = popNext(&i), let n = Int(v) { opts.maxTokens = n }
            default: positionals.append(a)
            }
            i += 1
        }
        let userText = positionals.joined(separator: " ")

        let engine = EngineFactory.makeDefaultEngine()
        let store = FileModelStore()
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        do {
            let location = try await store.ensureAvailable(spec: spec)
            try await engine.load(modelURL: location.url, spec: spec)
            defer { Task { await engine.unload() } }

            let messages = [HarmonyMessage(role: .user, content: userText)]
            let turn = HarmonyTurn(engine: engine, messages: messages, options: opts)

            var sawFirst = false
            for try await ev in turn.stream() {
                switch ev {
                case .token(let t):
                    print(t, terminator: "")
                    fflush(stdout)
                case .metrics(let m):
                    if !sawFirst { fputs(String(format: "TTFB: %d ms\n", m.ttfbMs), stderr); sawFirst = true }
                    else { fputs(String(format: "tok/s: %.2f  total: %d ms  tokens: %d (p:%d c:%d)\n", m.tokPerSec, m.totalDurationMillis, m.totalTokens, m.promptTokens, m.completionTokens), stderr) }
                case .toolCall:
                    // Not emitted in this step; reserved for future wiring
                    break
                case .toolResult:
                    // Not emitted in this step; reserved for future wiring
                    break
                case .done:
                    print("")
                }
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}


