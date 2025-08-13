import XCTest
@testable import HarmonyKit
@testable import SonifiedLLMCore

final class HarmonyKitTests: XCTestCase {
    func testPromptRenderingIncludesRoles() throws {
        // Golden test: fallback path without provider
        let messages: [HarmonyMessage] = [
            .init(role: .user, content: "Hello"),
            .init(role: .assistant, content: "Hi there"),
            .init(role: .tool, content: "done", name: "echo")
        ]
        let rendered = PromptBuilder.Harmony.render(system: "You are helpful.", messages: messages, provider: nil)
        print("[FALLBACK RENDERED]\n\(rendered)")
        assertMatchesGoldenTxt(named: "fallback_default", actual: rendered)
    }

    func testToolRegistryRegisterRetrieveAndInvoke() throws {
        struct EchoTool: HarmonyTool {
            let name = "echo"
            let description = "Echo back the provided 'text' argument."
            let parametersJSONSchema = "{" +
            "\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]" +
            "}"
            func invoke(args: [String : Any]) throws -> ToolResult {
                let content = String(describing: args["text"] ?? "")
                return ToolResult(name: name, content: content, metadata: ["length": content.count])
            }
        }
        let box = HarmonyToolbox()
        try box.register(tool: EchoTool())
        XCTAssertNotNil(box.tool(named: "echo"))
        XCTAssertEqual(box.allTools().count, 1)
        let result = try box.tool(named: "echo")!.invoke(args: ["text": "hi"]) // swiftlint:disable:this force_unwrapping
        XCTAssertEqual(result, ToolResult(name: "echo", content: "hi", metadata: ["length": 2]))
    }

    func testToolRegistryRejectsDuplicates() throws {
        struct T: HarmonyTool { let name = "dup"; let description = ""; let parametersJSONSchema = "{}"; func invoke(args: [String : Any]) throws -> ToolResult { ToolResult(name: "dup", content: "") } }
        let box = HarmonyToolbox()
        try box.register(tool: T())
        XCTAssertThrowsError(try box.register(tool: T())) { error in
            guard case HarmonyToolboxError.duplicateToolName("dup") = error else {
                return XCTFail("expected duplicateToolName")
            }
        }
    }

    func testStreamingEventOrderingAdaptersContract() async throws {
        let engine = MockLLMEngine()
        try await engine.load(modelURL: URL(fileURLWithPath: "/dev/null"), spec: .init(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096))
        let turn = HarmonyTurn(engine: engine, messages: [.init(role: .user, content: "Hi")], options: .init(maxTokens: 8))
        var events: [HarmonyEvent] = []
        do {
            for try await ev in turn.stream() { events.append(ev) }
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        await engine.unload()

        // Must end with .done and have at least one .metrics before it
        guard let last = events.last else { return XCTFail("no events") }
        XCTAssertEqual(last, .done)
        let metricsIndices = events.enumerated().compactMap { (i, ev) -> Int? in if case .metrics = ev { return i } else { return nil } }
        XCTAssertGreaterThan(metricsIndices.count, 0)
        XCTAssertTrue(metricsIndices.last! < events.count - 1)
    }

    func testToolCallDetectorHappyPathSplitTokens() {
        var d = ToolCallDetector()
        let input = [
            "Hello {\"tool\":" , " {\"name\":\"echo\",\"arguments\":{" , "\"text\":\"hi\"}}}", " and more"
        ]
        var out: [DetectedEvent] = []
        for t in input { out.append(contentsOf: d.ingest(t)) }
        out.append(contentsOf: d.finish())

        // Expect: text("Hello "), toolCall(name:echo,args:{text:hi}), text(" and more")
        XCTAssertEqual(out.count, 3)
        guard case .text(let a0) = out[0], a0 == "Hello " else { return XCTFail("bad text prefix") }
        guard case .toolCall(let name, let args) = out[1] else { return XCTFail("missing toolCall") }
        XCTAssertEqual(name, "echo")
        XCTAssertEqual(String(describing: args["text"] ?? ""), "hi")
        guard case .text(let a2) = out[2], a2 == " and more" else { return XCTFail("bad text suffix") }
    }

    func testToolCallDetectorNestedBraces() {
        var d = ToolCallDetector()
        let json = "{\"tool\":{\"name\":\"calc\",\"arguments\":{\"a\":{\"b\":[1,{\"c\":3}]}}}}"
        let out = d.ingest(json) + d.finish()
        XCTAssertEqual(out.count, 1)
        guard case .toolCall(let name, let args) = out[0] else { return XCTFail("expected toolCall") }
        XCTAssertEqual(name, "calc")
        XCTAssertNotNil(args["a"]) // nested structure present
    }

    func testToolCallDetectorGarbageIncompleteJSON() {
        var d = ToolCallDetector()
        let outs = d.ingest("start {\"tool\": \"oops") + d.finish()
        XCTAssertEqual(outs.count, 1)
        guard case .text = outs[0] else { return XCTFail("should be text only") }
    }

    func testToolCallDetectorSizeCapFallback() {
        var d = ToolCallDetector()
        // Construct a very large unclosed object after the marker
        let start = "{\"tool\":{\"name\":\"x\",\"arguments\":{"
        let big = String(repeating: "x", count: 40_000)
        let outs = d.ingest(start + big)
        // Since cap is 32k, capture should be abandoned and emitted as text
        XCTAssertEqual(outs.count, 1)
        guard case .text(let s) = outs[0] else { return XCTFail("expected text fallback") }
        XCTAssertTrue(s.hasPrefix("{\"tool\":"))
    }

    func testRoundTripHappyPathSingleTool() async throws {
        // Engine that emits a single tool call in first leg, and then streams continuation in second leg
        final class E: LLMEngine {
            var stats: LLMMetrics = .init()
            private var cancelled = false
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() { cancelled = true }
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    // If prompt contains tool message, act as second leg
                    if prompt.contains("<|tool|>") {
                        cont.yield(.metrics(.init()))
                        cont.yield(.token("followup "))
                        cont.yield(.metrics(.init()))
                        cont.yield(.done)
                        cont.finish()
                        return
                    }
                    // First leg: token then toolCall json, then would have more but will be cancelled by turn
                    cont.yield(.metrics(.init()))
                    cont.yield(.token("before "))
                    cont.yield(.token("{\"tool\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}"))
                    // Simulate some trailing text that should be ignored after cancel
                    cont.yield(.token(" trailing"))
                    cont.yield(.metrics(.init()))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        }
        struct EchoTool: HarmonyTool {
            let name = "echo"
            let description = "Echo"
            let parametersJSONSchema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"
            func invoke(args: [String : Any]) throws -> ToolResult { ToolResult(name: name, content: String(describing: args["text"] ?? "")) }
        }
        let box = HarmonyToolbox(); try box.register(tool: EchoTool())
        let engine = E()
        let turn = HarmonyTurn(engine: engine, messages: [.init(role: .user, content: "hi")], toolbox: box)
        var events: [HarmonyEvent] = []
        for try await ev in turn.stream() { events.append(ev) }

        // Verify ordering allowing an early metrics in second leg
        XCTAssertEqual(events[0], .metrics(.init()))
        XCTAssertEqual(events[1], .token("before "))
        guard case .toolCall(let n, let args) = events[2] else { return XCTFail("missing toolCall") }
        XCTAssertEqual(n, "echo")
        XCTAssertEqual(String(describing: args["text"] ?? ""), "hi")
        guard case .toolResult(let tr) = events[3] else { return XCTFail("missing toolResult") }
        XCTAssertEqual(tr, ToolResult(name: "echo", content: "hi"))

        // After toolResult, either metrics (TTFB2) or token may come first
        var idx = 4
        if case .metrics = events[idx] { idx += 1 }
        XCTAssertEqual(events[idx], .token("followup "))
        // There must be at least one more metrics before done
        let lastMetrics = events.enumerated().compactMap { (i, e) -> Int? in if case .metrics = e { return i } else { return nil } }.last
        XCTAssertNotNil(lastMetrics)
        XCTAssertTrue(lastMetrics! < events.count - 1)
        XCTAssertEqual(events.last, .done)
    }

    func testUnknownToolEmitsErrorAndContinues() async throws {
        final class E: LLMEngine {
            var stats: LLMMetrics = .init()
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() {}
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    if prompt.contains("<|tool|>") {
                        cont.yield(.metrics(.init()))
                        cont.yield(.token("resume "))
                        cont.yield(.metrics(.init()))
                        cont.yield(.done)
                        cont.finish(); return
                    }
                    cont.yield(.metrics(.init()))
                    cont.yield(.token("{\"tool\":{\"name\":\"missing\",\"arguments\":{}}}"))
                    cont.yield(.metrics(.init()))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        }
        let engine = E()
        let turn = HarmonyTurn(engine: engine, messages: [.init(role: .user, content: "x")])
        var events: [HarmonyEvent] = []
        for try await ev in turn.stream() { events.append(ev) }
        guard case .toolResult(let tr) = events[2] else { return XCTFail("expected toolResult at index 2") }
        XCTAssertEqual(tr.name, "missing")
        XCTAssertTrue(tr.content.contains("error"))
        // Allow early metrics in second leg
        var idx = 3
        if case .metrics = events[idx] { idx += 1 }
        XCTAssertEqual(events[idx], .token("resume "))
        XCTAssertEqual(events.last, .done)
    }

    func testArgsValidatorRejectsUnexpectedKey() throws {
        struct T: HarmonyTool { let name = "t"; let description = ""; let parametersJSONSchema = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":[\"a\"]}"; func invoke(args: [String : Any]) throws -> ToolResult { ToolResult(name: "t", content: "") } }
        let box = HarmonyToolbox(); try box.register(tool: T())
        let tool = try box.getToolOrThrow(named: "t")
        XCTAssertThrowsError(try box.validateArgsStrict(args: ["a": "ok", "extra": 1], schemaJSON: tool.parametersJSONSchema))
    }

    func testCancellationMidSecondLegEmitsFinalMetricsAndDone() async throws {
        final actor CancelLatch { var shouldCancel = false }
        let latch = CancelLatch()

        final class E: LLMEngine {
            var stats: LLMMetrics = .init()
            var onSecondLeg: (() -> Void)?
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() {}
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    if prompt.contains("<|tool|>") {
                        cont.yield(.metrics(.init()))
                        cont.yield(.token("continuing "))
                        cont.yield(.metrics(.init(success: false)))
                        cont.yield(.done)
                        cont.finish(); return
                    }
                    cont.yield(.metrics(.init()))
                    cont.yield(.token("{\"tool\":{\"name\":\"noop\",\"arguments\":{}}}"))
                    cont.yield(.metrics(.init()))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        }
        struct Noop: HarmonyTool { let name = "noop"; let description = ""; let parametersJSONSchema = "{\"type\":\"object\"}"; func invoke(args: [String : Any]) throws -> ToolResult { ToolResult(name: "noop", content: "ok") } }
        let box = HarmonyToolbox(); try box.register(tool: Noop())
        let engine = E()
        let turn = HarmonyTurn(engine: engine, messages: [.init(role: .user, content: "x")], toolbox: box)
        var events: [HarmonyEvent] = []
        for try await ev in turn.stream() {
            events.append(ev)
            if events.contains(where: { if case .toolResult = $0 { return true } else { return false } }) {
                // Request cancellation mid-second-leg
                turn.cancel()
            }
        }
        // Ensure final metrics(success=false) then done exist in order
        guard let lastMetricsIdx = events.enumerated().compactMap({ (i, e) -> Int? in if case .metrics(let m) = e, !m.success { return i } else { return nil } }).last else { return XCTFail("no final metrics with success=false") }
        XCTAssertTrue(lastMetricsIdx < events.count - 1)
        XCTAssertEqual(events.last, .done)
    }

    func testToolSchemasExposeMetadata() throws {
        struct A: HarmonyTool { let name = "a"; let description = "da"; let parametersJSONSchema = "{\"type\":\"object\"}"; func invoke(args: [String : Any]) throws -> ToolResult { ToolResult(name: "a", content: "") } }
        struct B: HarmonyTool { let name = "b"; let description = "db"; let parametersJSONSchema = "{\"type\":\"object\"}"; func invoke(args: [String : Any]) throws -> ToolResult { ToolResult(name: "b", content: "") } }
        let box = HarmonyToolbox()
        try box.register(tool: A())
        try box.register(tool: B())
        let schemas = box.toolSchemas()
        XCTAssertEqual(schemas.count, 2)
        let names = Set(schemas.map { $0.name })
        XCTAssertEqual(names, ["a", "b"])
        XCTAssertTrue(schemas.allSatisfy { !$0.description.isEmpty && !$0.parametersJSONSchema.isEmpty })
    }

    func testHarmonyEventEquatableWithToolCases() throws {
        let args1: [String: Any] = ["x": 1, "y": "z"]
        let args2: [String: Any] = ["y": "z", "x": 1] // different order
        let e1: HarmonyEvent = .toolCall(name: "calc", args: args1)
        let e2: HarmonyEvent = .toolCall(name: "calc", args: args2)
        XCTAssertEqual(e1, e2)

        let trA = ToolResult(name: "calc", content: "42", metadata: ["units": "N"])
        let trB = ToolResult(name: "calc", content: "42", metadata: ["units": "N"])
        XCTAssertEqual(HarmonyEvent.toolResult(trA), HarmonyEvent.toolResult(trB))

        let seq1: [HarmonyEvent] = [.token("a"), e1, .toolResult(trA), .metrics(.init()), .done]
        let seq2: [HarmonyEvent] = [.token("a"), e2, .toolResult(trB), .metrics(.init()), .done]
        XCTAssertEqual(seq1, seq2)
    }
}

// MARK: - Golden helpers and provider stub

private struct StubTemplateProvider: PromptBuilder.Harmony.ChatTemplateProvider {
    var template: String? = "{{bos}}\n{{content}}\n{{eos}}"
    var bosToken: String = "<s>"
    var eosToken: String = "</s>"
}

extension HarmonyKitTests {
    func testTemplateProviderGolden() throws {
        let provider = StubTemplateProvider()
        let messages: [HarmonyMessage] = [
            .init(role: .user, content: "Hello"),
            .init(role: .assistant, content: "Hi"),
            .init(role: .tool, content: "ok", name: "echo")
        ]
        let rendered = PromptBuilder.Harmony.render(system: "You are helpful.", messages: messages, provider: provider) + "\n"
        print("[TEMPLATE RENDERED]\n\(rendered)")
        assertMatchesGoldenTxt(named: "with_template", actual: rendered)
    }

    // Simple file-based golden assertion
    func assertMatchesGoldenTxt(named: String, actual: String, file: StaticString = #filePath, line: UInt = #line) {
        var loaded: String?
        if let url = Bundle.module.url(forResource: named, withExtension: "txt", subdirectory: "Goldens"),
           let s = try? String(contentsOf: url) {
            loaded = s
        } else {
            // Fallback to filesystem relative to this test file when run in environments that strip resources
            let base = URL(fileURLWithPath: String(describing: file)).deletingLastPathComponent()
            let url = base.appendingPathComponent("Goldens").appendingPathComponent(named + ".txt")
            loaded = try? String(contentsOf: url)
        }
        guard let expected = loaded else { return XCTFail("missing golden: \(named).txt") }
        print("[GOLDEN \(named)]\n\(expected)")
        print("[COMPARE suffixNL] actual=\(actual.hasSuffix("\n")) expected=\(expected.hasSuffix("\n"))")
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}


