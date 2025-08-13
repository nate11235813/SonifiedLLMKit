import XCTest
@testable import HarmonyKit
@testable import SonifiedLLMCore

final class HarmonyKitTests: XCTestCase {
    func testPromptRenderingIncludesRoles() throws {
        let messages: [HarmonyMessage] = [
            .init(role: .user, content: "Hello"),
            .init(role: .assistant, content: "Hi there")
        ]
        let text = PromptBuilder.Harmony.render(system: "You are helpful.", messages: messages)
        XCTAssertTrue(text.contains("<|system|>"))
        XCTAssertTrue(text.contains("<|user|>"))
        XCTAssertTrue(text.contains("<|assistant|>"))
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

    func testRunnerIntegrationTokenToolTokenSequence() async throws {
        // Custom engine that emits text -> tool json -> text
        final class E: LLMEngine {
            var stats: LLMMetrics = .init()
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() {}
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    cont.yield(.metrics(.init()))
                    cont.yield(.token("before "))
                    cont.yield(.token("{\"tool\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}"))
                    cont.yield(.token(" after"))
                    cont.yield(.metrics(.init()))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        }
        let engine = E()
        let turn = HarmonyTurn(engine: engine, messages: [.init(role: .user, content: "hi")])
        var events: [HarmonyEvent] = []
        for try await ev in turn.stream() { events.append(ev) }
        // Expect metrics, token("before "), toolCall, token(" after"), metrics, done
        XCTAssertEqual(events.first, .metrics(.init()))
        XCTAssertEqual(events[1], .token("before "))
        guard case .toolCall(let n, let args) = events[2] else { return XCTFail("missing toolCall in stream") }
        XCTAssertEqual(n, "echo")
        XCTAssertEqual(String(describing: args["text"] ?? ""), "hi")
        XCTAssertEqual(events[3], .token(" after"))
        XCTAssertEqual(events[4], .metrics(.init()))
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


