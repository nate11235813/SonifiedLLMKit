import XCTest
#if canImport(SonifiedLLMRuntime)
import SonifiedLLMRuntime

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
}
#endif


