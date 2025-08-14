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

    func testQuantParsingIncludesMXFP4() {
        XCTAssertNotNil(LLMModelSpec.Quantization(rawValue: "mxfp4"))
    }

    func testChoosePicksMXFP4WhenAvailable() throws {
        // Build a tiny catalog that includes mxfp4
        let caps = DeviceCaps(ramGB: 32, arch: "arm64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .mxfp4, contextTokens: 4096)
        let cat: [BundledCatalogEntry] = [
            .init(name: "gpt-oss-20b", quant: "mxfp4", path: "Models/gpt-oss-20b/gpt-oss-20b-mxfp4.gguf", minRamGB: 16, arch: ["arm64"]) ,
        ]
        let chosen = BundledModelSelector.choose(spec: spec, catalog: cat, caps: caps)
        XCTAssertNotNil(chosen)
        XCTAssertEqual(chosen?.name, "gpt-oss-20b")
        XCTAssertEqual(chosen?.quant, "mxfp4")
    }
}


