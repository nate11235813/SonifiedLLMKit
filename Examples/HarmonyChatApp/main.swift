import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
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
    @Published var bannerText: String? = nil
    @Published var bannerVisible: Bool = false
    @Published var bannerStyle: BannerStyle = .info

    private(set) var conversation = HarmonyConversation()
    private var engine: LLMEngine? = nil
    private var provider: PromptBuilder.Harmony.ChatTemplateProvider? = nil
    private(set) var toolbox: HarmonyToolbox? = nil
    @Published private(set) var allowedRoot: URL = ChatViewModel.defaultAllowedRoot()
    var allowedRootPath: String { allowedRoot.path }
    private var lastSuccess: Bool? = nil
    private var bannerTask: Task<Void, Never>? = nil
    private var lastFinalMetrics: LLMMetrics? = nil

    enum BannerStyle { case info, error }

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
                // Show selection/fallback banner (info, auto-dismiss)
                let chosenStr2 = "\(result.chosenSpec.name):\(result.chosenSpec.quant.rawValue)"
                var text = "Selected \(chosenStr2) (bundled)"
                if let fb = result.fallback {
                    text += " • Fell back from \(fb.from) → \(fb.to) (reason: \(fb.reason.rawValue))"
                }
                showBanner(text: text, style: .info, autoDismiss: true)
            } catch {
                print("Connect failed: \(error)")
                // Model load failed (both attempts)
                var reason = "unknown"
                if let e = error as? LLMError {
                    switch e {
                    case .engineInitFailed(let r, _): reason = r.rawValue
                    default: reason = e.localizedDescription
                    }
                } else {
                    reason = String(describing: error)
                }
                showBanner(text: "Model load failed: \(reason)", style: .error, autoDismiss: false)
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

    func chooseAllowedRoot() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Choose allowed folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = allowedRoot
        if panel.runModal() == .OK, let url = panel.url {
            allowedRoot = url
            if toolsEnabled {
                toolbox = HarmonyToolbox.demoTools(allowedRoot: allowedRoot)
            }
            showBanner(text: "FileInfoTool root: \(allowedRoot.path)", style: .info, autoDismiss: true)
        }
        #endif
    }

    func send() {
        guard let engine else { return }
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        currentStreamText = ""
        ttfbMs = nil
        tokPerSec = nil
        isGenerating = true
        lastSuccess = nil
        lastFinalMetrics = nil

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
                        lastSuccess = m.success
                        lastFinalMetrics = m // final metrics will overwrite; ok to set each time
                    case .token(let t):
                        currentStreamText += t
                    case .toolCall(let name, let args):
                        inlineEvents.append("[TOOL CALL] \(name) \(compactJSON(args))")
                    case .toolResult(let r):
                        let meta = r.metadata ?? [:]
                        let metaStr = meta.isEmpty ? "" : " " + compactJSON(meta)
                        inlineEvents.append("[TOOL RESULT] \(r.name): \(r.content)\(metaStr)")
                        if meta["error"] != nil {
                            showBanner(text: "Tool error: \(meta["error"]!)", style: .error, autoDismiss: true)
                        }
                    case .done:
                        isGenerating = false
                        currentStreamText = ""
                        transcript = conversation.messages
                        // Clear inline events on successful completion to avoid sticky chips; retain on cancel
                        if lastSuccess == true { inlineEvents.removeAll() }
                        // Show final metrics banner once
                        if let m = lastFinalMetrics {
                            if m.success {
                                let ttfb = m.ttfbMs
                                let rate = String(format: "%.1f", m.tokPerSec)
                                let text = "TTFB: \(ttfb) ms • tok/s: \(rate) • tokens: \(m.promptTokens)/\(m.completionTokens)"
                                showBanner(text: text, style: .info, autoDismiss: true)
                            } else {
                                showBanner(text: "Canceled.", style: .info, autoDismiss: true)
                            }
                        }
                    }
                }
            } catch {
                isGenerating = false
                print("Stream error: \(error)")
                showBanner(text: "Error: \(String(describing: error))", style: .error, autoDismiss: true)
            }
        }
        userText = ""
    }

    func cancel() {
        engine?.cancelCurrent()
    }

    func clear() {
        conversation.reset(system: systemPrompt)
        transcript = conversation.messages
        currentStreamText = ""
        inlineEvents.removeAll()
    }

    private func showBanner(text: String, style: BannerStyle, autoDismiss: Bool) {
        bannerTask?.cancel()
        bannerText = text
        bannerStyle = style
        bannerVisible = true
        if autoDismiss {
            bannerTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                bannerVisible = false
            }
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        bannerVisible = false
    }

    private static func defaultAllowedRoot() -> URL {
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dir = docs.appendingPathComponent("SonifiedLLMKit", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
            ScrollViewReader { proxy in
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
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: vm.currentStreamText) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: vm.transcript.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            // Bottom: input + send/cancel
            HStack(spacing: 8) {
                TextField("Type a message", text: $vm.userText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { vm.send() }
                    .disabled(vm.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isGenerating)
                Button("Cancel") { vm.cancel() }
                    .disabled(!vm.isGenerating)
                Button("Clear") { vm.clear() }
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
            HStack(spacing: 12) {
                Toggle("Enable tools", isOn: Binding(get: { vm.toolsEnabled }, set: { vm.setToolsEnabled($0) }))
                    .disabled(vm.isGenerating)
                Button("Choose folder…") { vm.chooseAllowedRoot() }
                    .disabled(vm.isGenerating)
            }
            if vm.toolsEnabled {
                Text("FileInfoTool is constrained to the allowed root (\(vm.allowedRootPath)); no network or path escapes.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Status banner
            if vm.bannerVisible, let text = vm.bannerText {
                HStack(spacing: 8) {
                    Image(systemName: vm.bannerStyle == .error ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundColor(vm.bannerStyle == .error ? .yellow : .blue)
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer()
                    Button(action: { vm.dismissBanner() }) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(8)
                .background(.thinMaterial)
                .cornerRadius(6)
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

