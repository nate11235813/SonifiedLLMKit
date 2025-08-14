import Foundation
import SonifiedLLMCore

public final class HarmonyConversation: @unchecked Sendable {
    public private(set) var messages: [HarmonyMessage]

    public init(system: String? = nil) {
        var initial: [HarmonyMessage] = []
        if let s = system, !s.isEmpty {
            initial.append(HarmonyMessage(role: .system, content: s))
        }
        self.messages = initial
    }

    public func reset(system: String? = nil) {
        messages.removeAll(keepingCapacity: false)
        if let s = system, !s.isEmpty {
            messages.append(HarmonyMessage(role: .system, content: s))
        }
    }

    public func append(_ message: HarmonyMessage) {
        messages.append(message)
    }

    /// Ask a question as the user and stream HarmonyEvents.
    /// - Note: Tool-calling is optional. Pass a `toolbox` to enable it; otherwise tool-call JSON text will be treated as plain tokens.
    public func ask(
        _ userText: String,
        using engine: LLMEngine,
        options: GenerateOptions = .init(),
        provider: PromptBuilder.Harmony.ChatTemplateProvider? = nil,
        toolbox: HarmonyToolbox? = nil
    ) -> AsyncThrowingStream<HarmonyEvent, Error> {
        // Append the user message to the conversation history immediately
        let userMessage = HarmonyMessage(role: .user, content: userText)
        self.messages.append(userMessage)

        // Split out system prompt from message history to avoid duplicate system sections
        let systemText: String? = messages.first(where: { $0.role == .system })?.content
        let historyExcludingSystem = messages.filter { $0.role != .system }

        if let toolbox {
            // Use HarmonyTurn for tool orchestration
            let turn = HarmonyTurn(
                engine: engine,
                systemPrompt: systemText,
                messages: historyExcludingSystem,
                options: options,
                toolbox: toolbox,
                chatTemplateProvider: provider
            )
            var bufferedAssistant = ""
            var lastMetrics: LLMMetrics? = nil
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await ev in turn.stream() {
                            switch ev {
                            case .token(let t):
                                bufferedAssistant += t
                                continuation.yield(.token(t))
                            case .metrics(let m):
                                lastMetrics = m
                                continuation.yield(.metrics(m))
                            case .toolCall(let name, let args):
                                continuation.yield(.toolCall(name: name, args: args))
                            case .toolResult(let r):
                                continuation.yield(.toolResult(r))
                            case .done:
                                // Append assistant message only on success
                                if (lastMetrics?.success ?? true) && bufferedAssistant.isEmpty == false {
                                    self.messages.append(HarmonyMessage(role: .assistant, content: bufferedAssistant))
                                }
                                continuation.yield(.done)
                                continuation.finish()
                            }
                        }
                    } catch {
                        // On error, do not append partial assistant message
                        continuation.finish(throwing: error)
                    }
                }
            }
        } else {
            // Tool-disabled mode: render prompt and stream directly from engine; treat tool JSON as plain text
            let prompt = PromptBuilder.Harmony.render(system: systemText, messages: historyExcludingSystem, provider: provider)
            var bufferedAssistant = ""
            var lastMetrics: LLMMetrics? = nil
            let stream = engine.generate(prompt: prompt, options: options)
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await ev in stream {
                            switch ev {
                            case .token(let t):
                                bufferedAssistant += t
                                continuation.yield(.token(t))
                            case .metrics(let m):
                                lastMetrics = m
                                continuation.yield(.metrics(m))
                            case .done:
                                if (lastMetrics?.success ?? true) && bufferedAssistant.isEmpty == false {
                                    self.messages.append(HarmonyMessage(role: .assistant, content: bufferedAssistant))
                                }
                                continuation.yield(.done)
                                continuation.finish()
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}


