import Foundation
import SonifiedLLMCore

// MARK: - Harmony domain types

public struct HarmonyMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let name: String?

    public init(role: Role, content: String, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
}

public enum HarmonyEvent: Equatable { // @unchecked Sendable due to [String: Any] in associated values
    case token(String)
    case metrics(LLMMetrics)
    case toolCall(name: String, args: [String: Any])
    case toolResult(ToolResult)
    case done

    /// Semantics:
    /// - The FIRST `.metrics` emitted in a turn corresponds to TTFB (time-to-first-token).
    /// - A FINAL `.metrics` is emitted at the end with totals (tok/s, duration, token counts, success flag).
    /// These semantics mirror `LLMEvent` from `SonifiedLLMCore` for parity with the CLI checklist.
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
    private let chatTemplateProvider: PromptBuilder.Harmony.ChatTemplateProvider?

    public init(engine: LLMEngine,
                systemPrompt: String? = "You are a helpful assistant.",
                messages: [HarmonyMessage],
                options: GenerateOptions = .init(),
                toolbox: HarmonyToolbox? = nil,
                chatTemplateProvider: PromptBuilder.Harmony.ChatTemplateProvider? = nil) {
        self.engine = engine
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.options = options
        self.toolbox = toolbox
        self.chatTemplateProvider = chatTemplateProvider
    }

    /// Streams HarmonyEvents by adapting the base engine's streaming contract.
    public func stream() -> AsyncThrowingStream<HarmonyEvent, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // First leg
                    let prompt1 = PromptBuilder.Harmony.render(system: systemPrompt, messages: messages, provider: chatTemplateProvider)
                    let stream1 = engine.generate(prompt: prompt1, options: options)

                    var detector = ToolCallDetector()
                    var capturedTool: (name: String, args: [String: Any])?

                    leg1: for try await ev in stream1 {
                        switch ev {
                        case .token(let t):
                            // Parse tokens for tool-call JSON; stop at the first tool call
                            let detected = detector.ingest(t)
                            for d in detected {
                                switch d {
                                case .text(let s):
                                    if capturedTool == nil, !s.isEmpty { continuation.yield(.token(s)) }
                                case .toolCall(let name, let args):
                                    capturedTool = (name, args)
                                    continuation.yield(.toolCall(name: name, args: args))
                                    break leg1
                                }
                            }
                        case .metrics(let m):
                            continuation.yield(.metrics(m))
                        case .done:
                            // No tool call detected; flush trailing text and finish
                            let tail = detector.finish()
                            for d in tail {
                                if case .text(let s) = d, !s.isEmpty { continuation.yield(.token(s)) }
                            }
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }

                    // If we get here, a tool call was captured in leg1. Stop the first leg promptly.
                    self.engine.cancelCurrent()

                    // Resolve and invoke the tool once
                    let (toolName, rawArgs) = capturedTool!
                    var toolResult = ToolResult(name: toolName, content: "")
                    if let toolbox = self.toolbox {
                        do {
                            let tool = try toolbox.getToolOrThrow(named: toolName)
                            do {
                                let validated = try toolbox.validateArgsStrict(args: rawArgs, schemaJSON: tool.parametersJSONSchema)
                                let result = try tool.invoke(args: validated)
                                toolResult = result
                            } catch {
                                toolResult = ToolResult(name: toolName, content: "error: invalid arguments", metadata: ["error": String(describing: error)])
                            }
                        } catch {
                            toolResult = ToolResult(name: toolName, content: "error: unknown tool", metadata: ["error": String(describing: error)])
                        }
                    } else {
                        toolResult = ToolResult(name: toolName, content: "error: no toolbox configured", metadata: ["error": "missingToolbox"]) 
                    }

                    // Emit tool result immediately
                    continuation.yield(.toolResult(toolResult))

                    // If cancelled during or right after tool execution, finish gracefully
                    if Task.isCancelled {
                        // Emit final metrics(cancelled) and done
                        continuation.yield(.metrics(LLMMetrics(success: false)))
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    // Second leg: append tool message and resume generation
                    var followupMessages = self.messages
                    followupMessages.append(HarmonyMessage(role: .tool, content: toolResult.content, name: toolResult.name))
                    let prompt2 = PromptBuilder.Harmony.render(system: self.systemPrompt, messages: followupMessages, provider: self.chatTemplateProvider)
                    let stream2 = self.engine.generate(prompt: prompt2, options: self.options)

                    var detector2 = ToolCallDetector()
                    for try await ev in stream2 {
                        switch ev {
                        case .token(let t):
                            // Ignore any further tool-call JSON in second leg; pass only text
                            let detected = detector2.ingest(t)
                            for d in detected {
                                switch d {
                                case .text(let s):
                                    if !s.isEmpty { continuation.yield(.token(s)) }
                                case .toolCall:
                                    // Ignore further tool calls in this step
                                    break
                                }
                            }
                        case .metrics(let m):
                            continuation.yield(.metrics(m))
                        case .done:
                            // Flush any trailing buffered text as normal tokens
                            let tail = detector2.finish()
                            for d in tail {
                                if case .text(let s) = d, !s.isEmpty { continuation.yield(.token(s)) }
                            }
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


