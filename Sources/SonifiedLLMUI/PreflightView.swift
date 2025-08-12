import SwiftUI
import Foundation
import SonifiedLLMCore
import SonifiedLLMDownloader

public struct PreflightView: View {
    @State private var text: String = ""
    @State private var output: String = ""
    @State private var ttfb: Int = 0
    @State private var system: SystemPreflightResult? = nil
    @State private var smokeMetrics: LLMMetrics? = nil

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local LLM Preflight (Mock)").font(.headline)
            GroupBox("System") {
                if let s = system {
                    HStack { Text("Metal"); Spacer(); Text(s.metalAvailable ? "✓" : "✗") }
                    HStack { Text("RAM"); Spacer(); Text("\(s.ramGB) GB") }
                    HStack { Text("Free disk"); Spacer(); Text("\(s.freeDiskGB) GB") }
                } else {
                    Text("No preflight run yet.")
                }
            }
            GroupBox("Recommendation") {
                if let s = system {
                    if let spec = s.recommendedSpec {
                        Text("Model: \(spec.name) / \(spec.quant) / ctx \(spec.context)")
                    } else {
                        Text("No recommendation — see notes.")
                    }
                    if !s.notes.isEmpty {
                        ForEach(s.notes, id: \.self) { n in Text(n) }
                    }
                }
            }
            HStack {
                Button("Run Preflight") { runPreflight() }
                if let s = system, let spec = s.recommendedSpec {
                    Button("Smoke Test") { runSmoke(spec: spec) }
                }
            }
            TextField("Prompt", text: $text)
            HStack {
                Button("Run") { run() }
                if ttfb > 0 {
                    Text("TTFB: \(ttfb) ms")
                }
            }
            ScrollView { Text(output).frame(maxWidth: .infinity, alignment: .leading) }
                .border(.gray.opacity(0.2))
            if let m = smokeMetrics {
                GroupBox("Smoke Metrics") {
                    Text("TTFB: \(m.ttfbMillis) ms")
                    Text("tok/s: \(String(format: "%.2f", m.tokPerSec))")
                    Text("total: \(m.totalDurationMillis) ms")
                }
            }
        }.padding()
    }

    private func runPreflight() {
        Task {
            let result = await Preflight.runAll()
            await MainActor.run { self.system = result }
        }
    }

    private func runSmoke(spec: LLMModelSpec) {
        Task {
            let engine = EngineFactory.makeDefaultEngine()
            let store = FileModelStore()
            let metrics = await Preflight.runSmoke(engine: engine, store: store, spec: spec)
            await MainActor.run { self.smokeMetrics = metrics }
        }
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
            do {
                for try await ev in stream {
                    switch ev {
                    case .token(let t): output.append(t)
                    case .metrics(let m): ttfb = m.ttfbMillis
                    case .done: break
                    }
                }
            } catch {
                output.append("\nError: \(error.localizedDescription)\n")
            }
            await engine.unload()
        }
    }
}
