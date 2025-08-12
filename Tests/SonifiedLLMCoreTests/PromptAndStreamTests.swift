import XCTest
@testable import SonifiedLLMCore

final class SonifiedLLMCoreTests: XCTestCase {
    func testPromptBuilder() throws {
        let text = PromptBuilder.conversation(system: "You are a helpful assistant.", messages: [
            ("user", "Hello"),
            ("assistant", "Hi!")
        ])
        XCTAssertTrue(text.contains("<|system|>"))
        XCTAssertTrue(text.contains("<|user|>"))
        XCTAssertTrue(text.contains("<|assistant|>"))
    }

    func testMockEngineStreams() async throws {
        let engine = EngineFactory.makeDefaultEngine()
        try await engine.load(modelURL: URL(fileURLWithPath: "/dev/null"), spec: .init(name: "gpt-oss-20b", quant: "Q4_K_M", context: 4096))
        var tokens = [String]()
        let stream = engine.generate(prompt: "Test", options: .init(maxTokens: 8))
        for try await ev in stream {
            if case .token(let t) = ev {
                tokens.append(t)
            }
        }
        await engine.unload()
        XCTAssertGreaterThan(tokens.count, 0)
    }
}
