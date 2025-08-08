import SwiftUI
import Foundation

public struct PreflightView: View {
    @State private var text: String = ""
    @State private var output: String = ""
    @State private var ttfb: Int = 0

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local LLM Preflight (Mock)").font(.headline)
            TextField("Prompt", text: $text)
            HStack {
                Button("Run") { run() }
                if ttfb > 0 {
                    Text("TTFB: \(ttfb) ms")
                }
            }
            ScrollView { Text(output).frame(maxWidth: .infinity, alignment: .leading) }
                .border(.gray.opacity(0.2))
        }.padding()
    }

    private func run() {
        Task {
            output = ""
            let engine = EngineFactory.makeDefaultEngine()
            let store = FileModelStore()
            let spec = LLMModelSpec(name: "gpt-oss-20b", quant: "Q4_K_M", context: 4096)
            let url = try? await store.ensureAvailable(spec: spec)
            try? await engine.load(modelURL: url ?? URL(fileURLWithPath: "/dev/null"), spec: spec)
            let stream = engine.generate(prompt: text, options: .init(maxTokens: 64))
            for await ev in stream {
                switch ev {
                case .token(let t): output.append(t)
                case .metrics(let m): ttfb = m.ttfbMillis
                case .done: break
                }
            }
            await engine.unload()
        }
    }
}
