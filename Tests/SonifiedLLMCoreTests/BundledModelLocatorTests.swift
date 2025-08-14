import XCTest
@testable import SonifiedLLMCore
@testable import SonifiedLLMDownloader

final class BundledModelLocatorTests: XCTestCase {
    func testManifestHitReturnsURL() throws {
        let bundle = Bundle.module
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let url = BundledModelLocator.locate(spec: spec, in: bundle)
        XCTAssertNotNil(url)
    }

    func testConventionFallbackWhenNoManifest() throws {
        // Use a private helper bundle that points to a directory without index.json
        guard let base = Bundle.module.resourceURL else {
            XCTFail("Missing test resources base URL")
            return
        }
        let fakeBundleURL = base.appendingPathComponent("ConventionsOnly.bundle")
        try? FileManager.default.createDirectory(at: fakeBundleURL, withIntermediateDirectories: true)
        // Create directory structure Models/<name>/<name>-<quant>.gguf
        let subdir = fakeBundleURL.appendingPathComponent("Models/gpt-oss-7b", isDirectory: true)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let modelPath = subdir.appendingPathComponent("gpt-oss-7b-q4_K_M.gguf")
        FileManager.default.createFile(atPath: modelPath.path, contents: Data())

        guard let convBundle = Bundle(url: fakeBundleURL) else {
            XCTFail("Failed to create bundle at \(fakeBundleURL)")
            return
        }
        let spec = LLMModelSpec(name: "gpt-oss-7b", quant: .q4_K_M, contextTokens: 2048)
        let url = BundledModelLocator.locate(spec: spec, in: convBundle)
        XCTAssertNotNil(url)
    }

    func testFileModelStoreReturnsBundledAndThrowsWhenMissing() throws {
        let bundle = Bundle.module
        let store = FileModelStore()

        // Hit
        let hitSpec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let location = try store.ensureAvailable(spec: hitSpec, in: bundle)
        XCTAssertEqual(location.source, .bundled)

        // Miss
        let missSpec = LLMModelSpec(name: "does-not-exist", quant: .q4_K_M, contextTokens: 4096)
        do {
            _ = try store.ensureAvailable(spec: missSpec, in: bundle)
            XCTFail("Expected throw for missing model")
        } catch let error as LLMError {
            switch error {
            case .modelNotFound:
                XCTAssertEqual(error.recoverySuggestion, "This build requires a bundled model; ensure the GGUF is added to the app bundle.")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-LLMError: \(error)")
        }
    }

    func testSelectorLogic() throws {
        // Load test catalog JSON
        let bundle = Bundle.module
        let url = bundle.url(forResource: "index", withExtension: "json", subdirectory: "BundledModels")
            ?? bundle.url(forResource: "index", withExtension: "json")
        guard let url else {
            XCTFail("Missing test catalog")
            return
        }
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(BundledCatalog.self, from: data)

        // Caps { ram=16, arch=arm64 }, spec=20B q4_K_M → picks 20B q4_K_M
        let caps1 = DeviceCaps(ramGB: 16, arch: "arm64")
        let spec20 = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let pick1 = BundledModelSelector.choose(spec: spec20, catalog: catalog.models, caps: caps1)
        XCTAssertEqual(pick1?.name, "gpt-oss-20b")
        XCTAssertEqual(pick1?.quant, "q4_K_M")

        // Caps { ram=12, arch=arm64 }, spec=20B q4_K_M → picks 7B q4_K_M fallback
        let caps2 = DeviceCaps(ramGB: 12, arch: "arm64")
        let pick2 = BundledModelSelector.choose(spec: spec20, catalog: catalog.models, caps: caps2)
        XCTAssertEqual(pick2?.name, "gpt-oss-7b")
        XCTAssertEqual(pick2?.quant, "q4_K_M")

        // Caps { ram=6, arch=x86_64 } → returns nil
        let caps3 = DeviceCaps(ramGB: 6, arch: "x86_64")
        let pick3 = BundledModelSelector.choose(spec: spec20, catalog: catalog.models, caps: caps3)
        XCTAssertNil(pick3)
    }

    func testFileModelStoreFallbackSelection() throws {
        let bundle = Bundle.module
        // Inject low RAM caps so 20B is not allowed and 7B is
        let store = FileModelStore(deviceCaps: DeviceCaps(ramGB: 12, arch: "arm64"))
        let spec = LLMModelSpec(name: "gpt-oss-20b", quant: .q4_K_M, contextTokens: 4096)
        let location = try store.ensureAvailable(spec: spec, in: bundle)
        XCTAssertEqual(location.source, .bundled)
        XCTAssertTrue(location.url.lastPathComponent.contains("gpt-oss-7b"))
    }

    func testFileModelStoreThrowsWhenCatalogAbsentAndNoExact() throws {
        // Create a fake bundle without catalog or matching file
        guard let base = Bundle.module.resourceURL else {
            XCTFail("Missing test resources base URL")
            return
        }
        let fakeBundleURL = base.appendingPathComponent("NoCatalog.bundle")
        try? FileManager.default.createDirectory(at: fakeBundleURL, withIntermediateDirectories: true)
        guard let noCatalogBundle = Bundle(url: fakeBundleURL) else {
            XCTFail("Failed to create bundle at \(fakeBundleURL)")
            return
        }
        let store = FileModelStore(deviceCaps: DeviceCaps(ramGB: 12, arch: "arm64"))
        let missSpec = LLMModelSpec(name: "gpt-oss-42b", quant: .q4_K_M, contextTokens: 4096)
        do {
            _ = try store.ensureAvailable(spec: missSpec, in: noCatalogBundle)
            XCTFail("Expected throw for missing model without catalog")
        } catch let error as LLMError {
            switch error {
            case .modelNotFound:
                XCTAssertEqual(error.recoverySuggestion, "This build requires a bundled model; ensure the GGUF is added to the app bundle.")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-LLMError: \(error)")
        }
    }
}


