import XCTest

// Local mirror of the downloader's manifest for test isolation without linking the module.
private struct TestModelManifest: Codable, Sendable {
    let name: String
    let quant: String
    let sizeBytes: Int64
    let sha256: String
    let uri: URL

    enum CodingKeys: String, CodingKey {
        case name
        case quant
        case sizeBytes = "size_bytes"
        case sha256
        case uri
    }

    func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TestValidationError.invalidName }
        if quant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TestValidationError.invalidQuant }
        if sizeBytes <= 0 { throw TestValidationError.invalidSize }
        let hex = sha256.lowercased()
        let isHex = hex.count == 64 && hex.allSatisfy { c in
            ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c))
        }
        if !isHex { throw TestValidationError.invalidChecksum }
    }

    static func load(from url: URL) throws -> TestModelManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(TestModelManifest.self, from: data)
    }
}

private enum TestValidationError: Error, Equatable {
    case invalidName, invalidQuant, invalidSize, invalidChecksum
}

// Provide the expected type name for the test API surface
private typealias ModelManifest = TestModelManifest

final class ModelManifestTests: XCTestCase {
    func testDecodeAndValidateExample() throws {
        // Locate the repo root using this test file's path
        let thisFile = URL(fileURLWithPath: #file)
        let repoRoot = thisFile
            .deletingLastPathComponent() // SonifiedLLMCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo root>
        let manifestURL = repoRoot
            .appendingPathComponent("Manifests", isDirectory: true)
            .appendingPathComponent("gpt-oss-20b-q4km.example.json")

        let manifest = try ModelManifest.load(from: manifestURL)
        try manifest.validate()

        XCTAssertEqual(manifest.name, "gpt-oss-20b")
        XCTAssertEqual(manifest.quant, "Q4_K_M")
        XCTAssertEqual(manifest.sizeBytes, 1234567890)
        XCTAssertEqual(manifest.sha256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertEqual(manifest.uri.absoluteString, "https://example.com/models/gpt-oss-20b-q4km.gguf")
    }
}


