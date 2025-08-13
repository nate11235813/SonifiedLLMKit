import XCTest
@testable import HarmonyKit
@testable import SonifiedLLMCore

final class DemoToolsTests: XCTestCase {
    func testTimeToolSchemaAndInvocation() throws {
        let box = HarmonyToolbox.demoTools(allowedRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        guard let tool = box.tool(named: "time") else { return XCTFail("missing time tool") }
        // Schema should reject unknown keys
        XCTAssertThrowsError(try box.validateArgsStrict(args: ["x":1], schemaJSON: tool.parametersJSONSchema))
        let validated = try box.validateArgsStrict(args: [:], schemaJSON: tool.parametersJSONSchema)
        let result = try tool.invoke(args: validated)
        // ISO-8601 parseable
        let fmt = ISO8601DateFormatter(); fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let parsed = fmt.date(from: result.content)
        XCTAssertNotNil(parsed, "time not ISO-8601")
        // Metadata timestamp numeric
        XCTAssertNotNil(result.metadata?["timestamp"] as? Int)
    }

    func testMathToolSchemaAndEvaluation() throws {
        let box = HarmonyToolbox.demoTools(allowedRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        guard let tool = box.tool(named: "math") else { return XCTFail("missing math tool") }
        // Schema checks
        XCTAssertThrowsError(try box.validateArgsStrict(args: [:], schemaJSON: tool.parametersJSONSchema))
        XCTAssertThrowsError(try box.validateArgsStrict(args: ["expression":"1+2", "x":1], schemaJSON: tool.parametersJSONSchema))
        let args = try box.validateArgsStrict(args: ["expression": "(2 + 3) * 4.5 - 1"], schemaJSON: tool.parametersJSONSchema)
        let result = try tool.invoke(args: args)
        // Define exact shape: content is string; metadata.value is Double 21.5
        XCTAssertEqual(result.content, "21.5")
        if let value = result.metadata?["value"] as? Double {
            XCTAssertEqual(value, 21.5, accuracy: 1e-9)
        } else {
            XCTFail("missing numeric value in metadata")
        }

        // Negative test
        let bad = try box.validateArgsStrict(args: ["expression": "2 + bad"], schemaJSON: tool.parametersJSONSchema)
        let badResult = try tool.invoke(args: bad)
        XCTAssertTrue(badResult.content.contains("error"))
        XCTAssertNotNil(badResult.metadata?["error"] as? String)
    }

    func testFileInfoToolSchemaAndFileOps() throws {
        // Create a temp file
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let data = Data("hello".utf8)
        let fileURL = tmpDir.appendingPathComponent("a.txt")
        try data.write(to: fileURL)

        let box = HarmonyToolbox.demoTools(allowedRoot: tmpDir)
        guard let tool = box.tool(named: "fileInfo") else { return XCTFail("missing fileInfo tool") }

        // Happy path
        let args = try box.validateArgsStrict(args: ["relativePath": "a.txt"], schemaJSON: tool.parametersJSONSchema)
        let result = try tool.invoke(args: args)
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(result.metadata?["size"] as? Int, data.count)
        XCTAssertEqual(result.metadata?["sha256"] as? String, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertNotNil(result.metadata?["lastModified"] as? String)

        // Escape rejection
        let escapeArgs = try box.validateArgsStrict(args: ["relativePath": "../secret"], schemaJSON: tool.parametersJSONSchema)
        let escapeResult = try tool.invoke(args: escapeArgs)
        XCTAssertTrue(escapeResult.content.contains("error"))
    }

    func testRoundTripWithMathTool() async throws {
        // Engine simulating a full round trip with math tool
        final class E: LLMEngine {
            var stats: LLMMetrics = .init()
            func load(modelURL: URL, spec: LLMModelSpec) async throws {}
            func unload() async {}
            func cancelCurrent() {}
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
                AsyncThrowingStream { cont in
                    if prompt.contains("<|tool|>") {
                        cont.yield(.metrics(.init()))
                        cont.yield(.token(" after "))
                        cont.yield(.metrics(.init()))
                        cont.yield(.done)
                        cont.finish(); return
                    }
                    cont.yield(.metrics(.init()))
                    cont.yield(.token("calc: "))
                    let call = "{\"tool\":{\"name\":\"math\",\"arguments\":{\"expression\":\"(2 + 3) * 4.5 - 1\"}}}"
                    cont.yield(.token(call))
                    cont.yield(.metrics(.init()))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        }
        let engine = E()
        let box = HarmonyToolbox.demoTools(allowedRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        let turn = HarmonyTurn(engine: engine, messages: [.init(role: .user, content: "start")], toolbox: box)
        var events: [HarmonyEvent] = []
        for try await ev in turn.stream() { events.append(ev) }
        // Assert order includes: streamed text before toolCall; toolResult; continuation token before final metrics; final metrics then done
        XCTAssertTrue(events.count >= 6)
        // There must be a text token before the toolCall
        guard let idxToolCall = events.firstIndex(where: { if case .toolCall = $0 { return true } else { return false } }) else { return XCTFail("no toolCall") }
        XCTAssertTrue(events[..<idxToolCall].contains(.token("calc: ")))
        guard case .toolCall(let n, let a) = events[idxToolCall] else { return XCTFail("missing toolCall") }
        XCTAssertEqual(n, "math"); XCTAssertEqual(a["expression"] as? String, "(2 + 3) * 4.5 - 1")
        guard case .toolResult(let tr) = events[idxToolCall + 1] else { return XCTFail("missing toolResult") }
        XCTAssertEqual(tr.name, "math")
        XCTAssertEqual(tr.content, "21.5")
        // There must be at least one continuation token before the final metrics
        guard let lastMetricsIdx = events.lastIndex(where: { if case .metrics = $0 { return true } else { return false } }) else { return XCTFail("no final metrics") }
        XCTAssertTrue(events[(idxToolCall+1)..<lastMetricsIdx].contains(.token(" after ")))
        // Final event order ends with metrics then done
        XCTAssertEqual(events[lastMetricsIdx + 1], .done)
    }

    func testToolSchemasExposeOnlyDemoTools() throws {
        let box = HarmonyToolbox.demoTools(allowedRoot: URL(fileURLWithPath: "/"))
        let schemas = box.toolSchemas()
        XCTAssertEqual(schemas.count, 3)
        let names = Set(schemas.map { $0.name })
        XCTAssertEqual(names, ["time", "math", "fileInfo"])
        // Ensure schemas are strict (additionalProperties=false) for each
        for s in schemas {
            XCTAssertTrue(s.parametersJSONSchema.contains("\"additionalProperties\":false"))
        }
    }
}


