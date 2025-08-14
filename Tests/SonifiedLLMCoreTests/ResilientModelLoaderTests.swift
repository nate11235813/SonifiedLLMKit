import XCTest
@testable import SonifiedLLMCore
import SonifiedLLMDownloader

final class ResilientModelLoaderTests: XCTestCase {
    private final class ToggleFailEngine: LLMEngine {
        var shouldFailFirstURL: URL?
        var loadedURL: URL?
        var _stats: LLMMetrics = .init()
        func load(modelURL: URL, spec: LLMModelSpec) async throws {
            if let f = shouldFailFirstURL, f == modelURL {
                throw LLMError.engineInitFailed(reason: .oom, message: "forced")
            }
            loadedURL = modelURL
        }
        func unload() async { loadedURL = nil }
        func cancelCurrent() {}
        func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> { AsyncThrowingStream { $0.finish() } }
        var stats: LLMMetrics { _stats }
    }

    func testSuccessFirstAttempt() async throws {
        let engine = ToggleFailEngine()
        let caps = DeviceCaps(ramGB: 32, arch: "arm64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let bundle = Bundle.module
        let res = try await ResilientModelLoader.loadBundled(engine: engine, requestedSpec: spec, caps: caps, bundle: bundle)
        XCTAssertEqual(res.chosenSpec.name, "gpt-oss-20b")
        XCTAssertNil(res.fallback)
        XCTAssertEqual(engine.loadedURL, res.url)
    }

    func testFailFirstThenFallback() async throws {
        let engine = ToggleFailEngine()
        let caps = DeviceCaps(ramGB: 12, arch: "arm64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let bundle = Bundle.module
        // Point failure to the exact 20B URL
        if let url = BundledModelLocator.locate(spec: spec, in: bundle) {
            engine.shouldFailFirstURL = url
        }
        let res = try await ResilientModelLoader.loadBundled(engine: engine, requestedSpec: spec, caps: caps, bundle: bundle)
        XCTAssertEqual(res.chosenSpec.name, "gpt-oss-7b")
        XCTAssertNotNil(res.fallback)
    }

    func testFailFirstAndFailFallbackSurfacesSecondError() async throws {
        final class AlwaysFailEngine: LLMEngine {
            func load(modelURL: URL, spec: LLMModelSpec) async throws { throw LLMError.engineInitFailed(reason: .oom, message: "forced") }
            func unload() async {}
            func cancelCurrent() {}
            func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> { AsyncThrowingStream { $0.finish() } }
            var stats: LLMMetrics { .init() }
        }
        let engine = AlwaysFailEngine()
        let caps = DeviceCaps(ramGB: 12, arch: "arm64")
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let bundle = Bundle.module
        do {
            _ = try await ResilientModelLoader.loadBundled(engine: engine, requestedSpec: spec, caps: caps, bundle: bundle)
            XCTFail("expected throw")
        } catch let e as LLMError {
            if case .engineInitFailed = e { /* ok */ } else { XCTFail("unexpected error: \(e)") }
        }
    }
}


