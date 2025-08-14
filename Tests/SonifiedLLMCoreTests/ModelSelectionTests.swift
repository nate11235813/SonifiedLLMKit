import XCTest
@testable import SonifiedLLMCore
@testable import SonifiedLLMDownloader

final class ModelSelectionTests: XCTestCase {
    func testExactHitReturnsRequested() throws {
        let bundle = Bundle.module
        let caps = DeviceCaps(ramGB: 32, arch: "arm64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let rv = try ModelAutoSelection.resolve(spec: spec, caps: caps, in: bundle)
        XCTAssertEqual(rv.requestedName, "gpt-oss-20b")
        XCTAssertEqual(rv.chosenName, "gpt-oss-20b")
        XCTAssertTrue(rv.url.path.contains("gpt-oss-20b"))
    }

    func testFallbackPicks7BFor12GB() throws {
        let bundle = Bundle.module
        let caps = DeviceCaps(ramGB: 12, arch: "arm64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let rv = try ModelAutoSelection.resolve(spec: spec, caps: caps, in: bundle)
        XCTAssertEqual(rv.requestedName, "gpt-oss-20b")
        XCTAssertEqual(rv.chosenName, "gpt-oss-7b")
        XCTAssertTrue(rv.url.path.contains("gpt-oss-7b"))
    }

    func testNoMatchReturnsError() {
        let bundle = Bundle.module
        let caps = DeviceCaps(ramGB: 6, arch: "x86_64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        do {
            _ = try ModelAutoSelection.resolve(spec: spec, caps: caps, in: bundle)
            XCTFail("Expected error")
        } catch let e as LLMError {
            switch e {
            case .modelNotFound:
                XCTAssertNotNil(e.recoverySuggestion)
            default:
                XCTFail("Unexpected error: \(e)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}


