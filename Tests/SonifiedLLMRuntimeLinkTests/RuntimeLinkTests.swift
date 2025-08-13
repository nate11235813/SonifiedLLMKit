import XCTest
#if canImport(SonifiedLLMRuntime)
import SonifiedLLMRuntime
@testable import SonifiedLLMCore

// Non-capturing C-compatible token callback; passes state via ctx
private func tokenCB(_ token: UnsafePointer<CChar>?, _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let flag = ctx.assumingMemoryBound(to: Bool.self)
    if token != nil { flag.pointee = true }
}

final class RuntimeLinkTests: XCTestCase {
    func testRuntimeSymbolsLink() throws {
        // Init
        let handle = llm_init("stub")
        XCTAssertNotNil(handle)

        // Eval (no-op callback)
        var called = false
        withUnsafeMutablePointer(to: &called) { ptr in
            "hi".withCString { cstr in
                let rc = llm_eval(handle, cstr, nil, tokenCB, UnsafeMutableRawPointer(ptr))
                XCTAssertEqual(rc, 0)
            }
        }

        // Stats
        var s = llm_stats_t()
        XCTAssertEqual(llm_stats(handle, &s), 0)
        XCTAssertTrue(called)

        // Free
        llm_free(handle)
    }

    func testChatTemplateStubAvailable() async throws {
        // Use the engine accessor to avoid hard link to the symbol in tests
        let engine = LLMEngineImpl()
        try await engine.load(modelURL: URL(fileURLWithPath: "stub"), spec: .init(name: "stub", quant: .q4_K_M, contextTokens: 128))
        let s = engine.chatTemplate()
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("{{content}}"))
        await engine.unload()
    }

    func testEngineAccessorReturnsStubTemplate() async throws {
        let engine = LLMEngineImpl()
        try await engine.load(modelURL: URL(fileURLWithPath: "stub"), spec: .init(name: "stub", quant: .q4_K_M, contextTokens: 128))
        let t = engine.chatTemplate()
        XCTAssertNotNil(t)
        XCTAssertTrue(t!.contains("{{content}}"))
        await engine.unload()
    }
}
#endif


