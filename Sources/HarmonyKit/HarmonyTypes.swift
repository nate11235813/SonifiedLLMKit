import Foundation
import SonifiedLLMCore

// MARK: - Harmony domain types

public struct HarmonyMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum HarmonyEvent: Equatable { // @unchecked Sendable due to [String: Any] in associated values
    case token(String)
    case metrics(LLMMetrics)
    case toolCall(name: String, args: [String: Any])
    case toolResult(ToolResult)
    case done

    public static func == (lhs: HarmonyEvent, rhs: HarmonyEvent) -> Bool {
        switch (lhs, rhs) {
        case (.token(let a), .token(let b)):
            return a == b
        case (.metrics(let a), .metrics(let b)):
            return a == b
        case (.toolCall(let la, let largs), .toolCall(let ra, let rargs)):
            return la == ra && areJSONLikeEqual(largs, rargs)
        case (.toolResult(let lt), .toolResult(let rt)):
            return lt == rt
        case (.done, .done):
            return true
        default:
            return false
        }
    }
}

// HarmonyEvent cannot safely conform to Sendable due to [String: Any] arguments; mark unchecked.
extension HarmonyEvent: @unchecked Sendable {}

@inline(__always)
private func areJSONLikeEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    if JSONSerialization.isValidJSONObject(a), JSONSerialization.isValidJSONObject(b) {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: opts),
              let db = try? JSONSerialization.data(withJSONObject: b, options: opts) else {
            return NSDictionary(dictionary: a).isEqual(to: b)
        }
        return da == db
    }
    return NSDictionary(dictionary: a).isEqual(to: b)
}

// MARK: - Prompt rendering

// Note: Default chat template is provided as PromptBuilder.Harmony in PromptBuilder+Harmony.swift

// MARK: - Turn adapter

public final class HarmonyTurn: @unchecked Sendable {
    private let engine: LLMEngine
    private let messages: [HarmonyMessage]
    private let systemPrompt: String?
    private let options: GenerateOptions
    public let toolbox: HarmonyToolbox?

    public init(engine: LLMEngine,
                systemPrompt: String? = "You are a helpful assistant.",
                messages: [HarmonyMessage],
                options: GenerateOptions = .init(),
                toolbox: HarmonyToolbox? = nil) {
        self.engine = engine
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.options = options
        self.toolbox = toolbox
    }

    /// Streams HarmonyEvents by adapting the base engine's streaming contract.
    public func stream() -> AsyncThrowingStream<HarmonyEvent, Error> {
        let prompt = PromptBuilder.Harmony.render(system: systemPrompt, messages: messages)
        let baseStream = engine.generate(prompt: prompt, options: options)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await ev in baseStream {
                        switch ev {
                        case .token(let t):
                            continuation.yield(.token(t))
                        case .metrics(let m):
                            continuation.yield(.metrics(m))
                        case .done:
                            continuation.yield(.done)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel() {
        engine.cancelCurrent()
    }
}


