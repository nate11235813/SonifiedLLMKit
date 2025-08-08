import XCTest
#if canImport(SonifiedLLMRuntime)
import SonifiedLLMRuntime

final class RuntimeLinkTests: XCTestCase {
    func testRuntimeSymbolsLink() throws {
        // Init
        let handle = llm_init("stub")
        XCTAssertNotNil(handle)

        // Eval (no-op callback)
        var called = false
        let cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { token, _ in
            if token != nil { called = true }
        }
        let rc = llm_eval(handle, "ping", nil, cb, nil)
        XCTAssertEqual(rc, 0)

        // Stats
        var s = llm_stats_t(ttfb_ms: 0, tok_per_sec: 0, total_ms: 0, peak_rss_mb: 0, success: 0)
        XCTAssertEqual(llm_stats(handle, &s), 0)
        XCTAssertTrue(called)

        // Free
        llm_free(handle)
    }
}
#endif


