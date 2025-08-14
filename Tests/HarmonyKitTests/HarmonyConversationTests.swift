import XCTest
@testable import HarmonyKit
@testable import SonifiedLLMCore

final class HarmonyConversationTests: XCTestCase {
    func testMultiTurnHappyPathStoresAssistantHistory() async throws {
        let engine = MockLLMEngine()
        try await engine.load(modelURL: URL(fileURLWithPath: "stub"), spec: .init(name: "x", quant: .q4_K_M, contextTokens: 128))
        defer { Task { await engine.unload() } }

        let provider = PromptBuilder.Harmony.GGUFChatTemplateProvider(fetchTemplate: { "{{bos}}\n{{content}}\n{{eos}}" })

        let convo = HarmonyConversation(system: "You are helpful.")

        // Turn 1
        var collected1: String = ""
        for try await ev in convo.ask("Hello", using: engine, options: .init(maxTokens: 3), provider: provider) {
            if case .token(let t) = ev { collected1 += t }
        }
        XCTAssertFalse(collected1.isEmpty)
        XCTAssertTrue(convo.messages.last?.role == .assistant)

        // Turn 2 - ensure the rendered prompt includes assistant history
        let firstAssistant = convo.messages.last?.content ?? ""
        final class CapturingEngine: LLMEngine {
            var stats: LLMMetrics = .init()
            var lastPrompt: String = ""
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() {}
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                lastPrompt = prompt
                return AsyncThrowingStream { cont in
                    cont.yield(.metrics(.init(ttfbMs: 1)))
                    cont.yield(.token("ok"))
                    cont.yield(.metrics(.init()))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        }
        let engine2 = CapturingEngine()
        for try await _ in convo.ask("What did I just say?", using: engine2, options: .init(maxTokens: 3), provider: provider) {}
        let normalizedAssistant = firstAssistant.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(engine2.lastPrompt.contains(normalizedAssistant))
        XCTAssertTrue(convo.messages.last?.role == .assistant)
        // History should be: [system, user(Hello), assistant(hi...), user(What...), assistant(...)]
        XCTAssertGreaterThanOrEqual(convo.messages.count, 5)
    }

    func testCancellationDoesNotAppendAssistant() async throws {
        // Engine that emits many tokens until cancelled
        final class E: LLMEngine {
            private var cancelled = false
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() { cancelled = true }
            var stats: LLMMetrics = .init()
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    Task {
                        cont.yield(.metrics(.init(ttfbMs: 1)))
                        for _ in 0..<1000 {
                            if self.cancelled { break }
                            cont.yield(.token("x"))
                            try? await Task.sleep(nanoseconds: 1_000_000)
                        }
                        cont.yield(.metrics(.init(success: false)))
                        cont.yield(.done)
                        cont.finish()
                    }
                }
            }
        }

        let engine = E()
        let convo = HarmonyConversation(system: "You are helpful.")
        let stream = convo.ask("Hello", using: engine)
        var sawEarly = false
        var sawFinal = false
        Task { try? await Task.sleep(nanoseconds: 5_000_000); engine.cancelCurrent() }
        for try await ev in stream {
            switch ev {
            case .metrics(let m):
                if !sawEarly { XCTAssertEqual(m.ttfbMs, 1); sawEarly = true }
                else { XCTAssertFalse(m.success); sawFinal = true }
            case .done:
                break
            default:
                break
            }
        }
        XCTAssertTrue(sawFinal)
        // Only system + user should be present since assistant was cancelled
        XCTAssertEqual(convo.messages.count, 2)
        XCTAssertEqual(convo.messages[0].role, .system)
        XCTAssertEqual(convo.messages[1].role, .user)
    }

    func testToolDisabledTreatsToolJSONAsText() async throws {
        // Engine that emits a tool JSON token as plain text
        final class E: LLMEngine {
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() {}
            var stats: LLMMetrics = .init()
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    Task {
                        cont.yield(.metrics(.init(ttfbMs: 1)))
                        cont.yield(.token("{"))
                        cont.yield(.token("\"tool\":"))
                        cont.yield(.token("{"))
                        cont.yield(.token("\"name\":\"math\","))
                        cont.yield(.token("\"arguments\":{\"expression\":\"2^8\"}}}"))
                        cont.yield(.metrics(.init(success: true)))
                        cont.yield(.done)
                        cont.finish()
                    }
                }
            }
        }
        let engine = E()
        let convo = HarmonyConversation(system: "You are helpful.")
        var collected: String = ""
        for try await ev in convo.ask("Hello", using: engine) {
            if case .token(let t) = ev { collected += t }
        }
        // The collected text should contain a JSON-looking sequence; since toolbox was not provided, it is not parsed as a tool call
        XCTAssertTrue(collected.contains("\"tool\""))
        XCTAssertTrue(convo.messages.last?.role == .assistant)
    }
}


