import SwiftUI
import SonifiedLLMCore
import HarmonyKit

@main
struct HarmonyChatApp: App {
    var body: some Scene {
        WindowGroup {
            HarmonyChatView()
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var systemPrompt: String = "You are helpful."
    @Published var userText: String = ""
    @Published var transcript: [HarmonyMessage] = []
    @Published var currentStreamText: String = ""
    @Published var isGenerating: Bool = false
    @Published var ttfbMs: Int? = nil
    @Published var tokPerSec: Double? = nil
    @Published var toolsEnabled: Bool = false
    @Published var inlineEvents: [String] = []

    private(set) var conversation = HarmonyConversation()
    private var engine: LLMEngine? = nil
    private var provider: PromptBuilder.Harmony.ChatTemplateProvider? = nil
    private(set) var toolbox: HarmonyToolbox? = nil
    private let allowedRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    func connect() {
        Task { @MainActor in
            // Build caps from preflight
            let caps = DeviceCaps(ramGB: Preflight.ramInGB(), arch: Preflight.currentArch())
            let requested = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)

            let engine = EngineFactory.makeDefaultEngine()
            self.engine = engine

            do {
                // Resolve & load bundled model with a single fallback attempt
                let result = try await ResilientModelLoader.loadBundled(engine: engine, requestedSpec: requested, caps: caps)

                // Selection banner
                let requestedStr = "\(requested.name):\(requested.quant.rawValue)"
                let chosenStr = "\(result.chosenSpec.name):\(result.chosenSpec.quant.rawValue)"
                print("[MODEL SELECTION] requested=\(requestedStr) caps=\(caps.arch)/\(caps.ramGB)GB chosen=\(chosenStr) source=\(result.provenance.rawValue)")
                if let fb = result.fallback {
                    print("[MODEL FALLBACK] reason=\(fb.reason.rawValue) from=\(fb.from) to=\(fb.to)")
                }

                // Provider from engine chat template (if any)
                self.provider = PromptBuilder.Harmony.GGUFChatTemplateProvider(fetchTemplate: { engineChatTemplate(engine) })

                // Reset conversation with current system prompt
                self.conversation.reset(system: self.systemPrompt)
                self.transcript = self.conversation.messages
            } catch {
                print("Connect failed: \(error)")
            }
        }
    }

    func setToolsEnabled(_ enabled: Bool) {
        guard !isGenerating else { return }
        toolsEnabled = enabled
        if enabled {
            toolbox = HarmonyToolbox.demoTools(allowedRoot: allowedRoot)
        } else {
            toolbox = nil
        }
    }

    func send() {
        guard let engine else { return }
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        currentStreamText = ""
        ttfbMs = nil
        tokPerSec = nil
        isGenerating = true

        inlineEvents.removeAll()
        let stream: AsyncThrowingStream<HarmonyEvent, Error> = {
            if let toolbox { return conversation.ask(text, using: engine, options: .init(maxTokens: 256), provider: provider, toolbox: toolbox) }
            return conversation.ask(text, using: engine, options: .init(maxTokens: 256), provider: provider)
        }()
        transcript = conversation.messages

        Task { @MainActor in
            do {
                for try await ev in stream {
                    switch ev {
                    case .metrics(let m):
                        if ttfbMs == nil { ttfbMs = m.ttfbMs }
                        tokPerSec = m.tokPerSec > 0 ? m.tokPerSec : tokPerSec
                    case .token(let t):
                        currentStreamText += t
                    case .toolCall(let name, let args):
                        inlineEvents.append("[TOOL CALL] \(name) \(compactJSON(args))")
                    case .toolResult(let r):
                        let meta = r.metadata ?? [:]
                        let metaStr = meta.isEmpty ? "" : " " + compactJSON(meta)
                        inlineEvents.append("[TOOL RESULT] \(r.name): \(r.content)\(metaStr)")
                    case .done:
                        isGenerating = false
                        currentStreamText = ""
                        transcript = conversation.messages
                    }
                }
            } catch {
                isGenerating = false
                print("Stream error: \(error)")
            }
        }
        userText = ""
    }

    func cancel() {
        engine?.cancelCurrent()
    }
}

// MARK: - View

struct HarmonyChatView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        VStack(spacing: 8) {
            // Top: system prompt + connect
            HStack(alignment: .top, spacing: 8) {
                TextEditor(text: $vm.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                VStack {
                    Button("Connect") { vm.connect() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(width: 120)
            }

            // Middle: transcript
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(vm.transcript.enumerated()), id: \.offset) { _, msg in
                        HStack(alignment: .top, spacing: 6) {
                            Text(roleLabel(msg.role))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            Text(msg.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // Inline tool events during streaming
                    ForEach(Array(vm.inlineEvents.enumerated()), id: \.offset) { _, evt in
                        HStack(alignment: .top, spacing: 6) {
                            Text("")
                                .frame(width: 80)
                            Text(evt)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(Color.gray.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !vm.currentStreamText.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Text(roleLabel(.assistant))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)
                            Text(vm.currentStreamText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Bottom: input + send/cancel
            HStack(spacing: 8) {
                TextField("Type a message", text: $vm.userText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { vm.send() }
                    .disabled(vm.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { vm.cancel() }
                    .disabled(!vm.isGenerating)
            }

            // Status strip
            HStack(spacing: 12) {
                if let t = vm.ttfbMs { Text("TTFB: \(t) ms") }
                if let r = vm.tokPerSec, r > 0 { Text(String(format: "tok/s: %.1f", r)) }
                if vm.isGenerating { ProgressView().scaleEffect(0.7) }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            // Tools toggle and note
            Toggle("Enable tools", isOn: Binding(get: { vm.toolsEnabled }, set: { vm.setToolsEnabled($0) }))
                .disabled(vm.isGenerating)
            if vm.toolsEnabled {
                Text("FileInfoTool is constrained to the app's allowed root; no network or path escapes.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .onAppear { vm.connect() }
    }

    private func roleLabel(_ role: HarmonyMessage.Role) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }
}


// MARK: - Helpers

private func compactJSON(_ value: Any) -> String {
    if let obj = value as? [String: Any], JSONSerialization.isValidJSONObject(obj),
       let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    if let arr = value as? [Any], JSONSerialization.isValidJSONObject(arr),
       let data = try? JSONSerialization.data(withJSONObject: arr, options: []),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return String(describing: value)
}

