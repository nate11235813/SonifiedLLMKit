import Foundation
import HarmonyKit
import SonifiedLLMCore
import SonifiedLLMDownloader

// Usage: swift run HarmonyCLI "your message here"
@main
struct HarmonyApp {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var opts = GenerateOptions()
        var useHarmony = false
        var inputPath: String?
        var modelPath: String?
        var positionals: [String] = []
        func popNext(_ i: inout Int) -> String? { guard i + 1 < args.count else { return nil }; i += 1; return args[i] }
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--max-tokens": if let v = popNext(&i), let n = Int(v) { opts.maxTokens = n }
            case "--harmony": useHarmony = true
            case "--input": inputPath = popNext(&i)
            case "--model": modelPath = popNext(&i)
            default: positionals.append(a)
            }
            i += 1
        }
        if useHarmony && inputPath == nil {
            fputs("Usage: HarmonyCLI --harmony --input <path(.json|.md)> [--model <path|stub>]\n", stderr)
            exit(2)
        }
        if !useHarmony && positionals.isEmpty {
            fputs("Usage: HarmonyCLI [--max-tokens <int>] [--model <path|stub>] \"your message\"\n" +
                  "       HarmonyCLI --harmony --input <path(.json|.md)> [--model <path|stub>]\n", stderr)
            exit(2)
        }

        let engine = EngineFactory.makeDefaultEngine()
        let store = FileModelStore()
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        do {
            let location: ModelLocation
            if let modelPath {
                if modelPath == "stub" {
                    location = ModelLocation(url: URL(fileURLWithPath: "stub"), source: .bundled)
                } else {
                    location = ModelLocation(url: URL(fileURLWithPath: modelPath), source: .downloaded)
                }
            } else {
                location = try await store.ensureAvailable(spec: spec)
            }
            try await engine.load(modelURL: location.url, spec: spec)
            defer { Task { await engine.unload() } }

            // Build provider to prefer GGUF chat template
            let provider = PromptBuilder.Harmony.GGUFChatTemplateProvider(fetchTemplate: { engineChatTemplate(engine) })

            if useHarmony {
                guard let inputPath else { fputs("missing --input path\n", stderr); exit(2) }
                let inputURL = URL(fileURLWithPath: inputPath)
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let allowedRoot = cwd
                // Build demo toolbox
                let box = HarmonyToolbox.demoTools(allowedRoot: allowedRoot)

                // Parse input
                let (systemPrompt, messages, requestedTools) = try parseHarmonyInput(at: inputURL)

                // Warn on unknown tool names
                for name in requestedTools {
                    if box.tool(named: name) == nil {
                        fputs("[warn] unknown tool: \(name)\n", stderr)
                    }
                }

                let turn = HarmonyTurn(engine: engine, systemPrompt: systemPrompt, messages: messages, options: opts, toolbox: box, chatTemplateProvider: provider)
                var sawEarlyMetrics = false
                var lastFinalMetrics: LLMMetrics?
                for try await ev in turn.stream() {
                    switch ev {
                    case .metrics(let m):
                        if !sawEarlyMetrics { print(String(format: "TTFB %dms", m.ttfbMs)); sawEarlyMetrics = true }
                        lastFinalMetrics = m
                    case .token(let t):
                        print(t, terminator: "")
                        fflush(stdout)
                    case .toolCall(let name, let args):
                        let argsJSON = compactJSONString(args) ?? "{}"
                        print("\n[TOOL CALL] \(name) args=\(argsJSON)")
                    case .toolResult(let tr):
                        let metaJSON = compactJSONString(tr.metadata ?? [:]) ?? "{}"
                        print("\n[TOOL RESULT] \(tr.name) content=\(tr.content) meta=\(metaJSON)")
                    case .done:
                        if let m = lastFinalMetrics {
                            print(String(format: "\nSUMMARY ttfb=%dms tok/s=%.2f total_ms=%d tokens=p:%d c:%d t:%d", m.ttfbMs, m.tokPerSec, m.totalDurationMillis, m.promptTokens, m.completionTokens, m.totalTokens))
                        }
                        print("DONE")
                    }
                }
            } else {
                // Simple one-off message mode
                let userText = positionals.joined(separator: " ")
                let messages = [HarmonyMessage(role: .user, content: userText)]
                let turn = HarmonyTurn(engine: engine, messages: messages, options: opts, toolbox: nil, chatTemplateProvider: provider)
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
                        break
                    case .toolResult:
                        break
                    case .done:
                        print("")
                    }
                }
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - Input parsing

private func parseHarmonyInput(at url: URL) throws -> (system: String?, messages: [HarmonyMessage], tools: [String]) {
    let data = try Data(contentsOf: url)
    let ext = url.pathExtension.lowercased()
    if ext == "json" {
        struct J: Decodable { let system: String?; let messages: [M]; let tools: [String]?; struct M: Decodable { let role: String; let content: String; let name: String? } }
        let j = try JSONDecoder().decode(J.self, from: data)
        let msgs: [HarmonyMessage] = j.messages.map { m in
            let role = HarmonyMessage.Role(rawValue: m.role) ?? .user
            return HarmonyMessage(role: role, content: m.content, name: m.name)
        }
        return (j.system, msgs, j.tools ?? [])
    } else if ext == "md" || ext == "markdown" || ext == "txt" {
        guard let s = String(data: data, encoding: .utf8) else { throw NSError(domain: "io", code: 1) }
        return parseMarkdownConversation(s)
    } else {
        // Try JSON first, fallback to markdown
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Re-encode to Data for decoding into struct
            let jd = try JSONSerialization.data(withJSONObject: j)
            return try parseHarmonyInput(fromJSONData: jd)
        }
        guard let s = String(data: data, encoding: .utf8) else { throw NSError(domain: "parse", code: 2) }
        return parseMarkdownConversation(s)
    }
}

private func parseHarmonyInput(fromJSONData data: Data) throws -> (system: String?, messages: [HarmonyMessage], tools: [String]) {
    struct J: Decodable { let system: String?; let messages: [M]; let tools: [String]?; struct M: Decodable { let role: String; let content: String; let name: String? } }
    let j = try JSONDecoder().decode(J.self, from: data)
    let msgs: [HarmonyMessage] = j.messages.map { m in
        let role = HarmonyMessage.Role(rawValue: m.role) ?? .user
        return HarmonyMessage(role: role, content: m.content, name: m.name)
    }
    return (j.system, msgs, j.tools ?? [])
}

private func parseMarkdownConversation(_ text: String) -> (system: String?, messages: [HarmonyMessage], tools: [String]) {
    var system: String?
    var tools: [String] = []
    var messages: [HarmonyMessage] = []
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var i = 0
    // Frontmatter: look for a 'tools:' line before first section
    while i < lines.count {
        let line = lines[i]
        if line.trimmingCharacters(in: CharacterSet.whitespaces).hasPrefix("### ") { break }
        if line.lowercased().hasPrefix("tools:") {
            let list = line.drop(while: { $0 != ":" }).dropFirst().split(separator: ",")
            tools = list.map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }.filter { !$0.isEmpty }
        }
        i += 1
    }
    func readBlockBody(start: inout Int) -> String {
        var body: [String] = []
        start += 1
        while start < lines.count {
            let l = lines[start]
            if l.trimmingCharacters(in: CharacterSet.whitespaces).hasPrefix("### ") { break }
            body.append(l)
            start += 1
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while i < lines.count {
        let line = lines[i].trimmingCharacters(in: CharacterSet.whitespaces)
        guard line.hasPrefix("### ") else { i += 1; continue }
        let header = String(line.dropFirst(4))
        if header.lowercased() == "system" {
            let body = readBlockBody(start: &i)
            system = body
            continue
        }
        if header.lowercased().hasPrefix("user") {
            let body = readBlockBody(start: &i)
            messages.append(HarmonyMessage(role: .user, content: body))
            continue
        }
        if header.lowercased().hasPrefix("assistant") {
            let body = readBlockBody(start: &i)
            messages.append(HarmonyMessage(role: .assistant, content: body))
            continue
        }
        if header.lowercased().hasPrefix("tool") {
            // Optional tool name after 'tool:'
            var toolName: String?
            if let idx = header.firstIndex(of: ":") {
                let n = header[header.index(after: idx)...].trimmingCharacters(in: CharacterSet.whitespaces)
                if !n.isEmpty { toolName = n }
            }
            let body = readBlockBody(start: &i)
            messages.append(HarmonyMessage(role: .tool, content: body, name: toolName))
            continue
        }
        // Unknown header: skip
        _ = readBlockBody(start: &i)
    }
    return (system, messages, tools)
}

private func compactJSONString(_ obj: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(obj) else { return nil }
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
    return String(data: d, encoding: .utf8)
}


