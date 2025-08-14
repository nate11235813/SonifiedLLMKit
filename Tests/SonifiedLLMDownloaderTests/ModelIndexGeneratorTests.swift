import XCTest
@testable import SonifiedLLMDownloader
import Foundation

final class ModelIndexGeneratorTests: XCTestCase {
    func testScanAndGenerateIndex() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Create Models layout
        let models = tmp.appendingPathComponent("Models", isDirectory: true)
        let nameDir = models.appendingPathComponent("gpt-oss-20b", isDirectory: true)
        try fm.createDirectory(at: nameDir, withIntermediateDirectories: true)
        let f1 = nameDir.appendingPathComponent("gpt-oss-20b-q4_K_M.gguf")
        try Data("dummy".utf8).write(to: f1)
        let f2 = models.appendingPathComponent("gpt-oss-7b-q5_K_M.gguf")
        try Data("dummy".utf8).write(to: f2)

        // Scan
        let entries = ModelIndexGenerator.scan(modelsRoot: models)
        XCTAssertEqual(entries.count, 2)
        // Sorted by name then quant rank
        XCTAssertEqual(entries[0].name, "gpt-oss-20b")
        XCTAssertEqual(entries[0].quant, "q4_K_M")
        XCTAssertEqual(entries[0].path, "Models/gpt-oss-20b/gpt-oss-20b-q4_K_M.gguf")
        XCTAssertEqual(entries[1].name, "gpt-oss-7b")
        XCTAssertEqual(entries[1].quant, "q5_K_M")
        XCTAssertEqual(entries[1].path, "Models/gpt-oss-7b-q5_K_M.gguf")

        // Generate JSON
        let out = tmp.appendingPathComponent("BundledModels/index.json")
        try ModelIndexGenerator.generate(modelsRoot: models, outputURL: out, embedded: true)
        let data = try Data(contentsOf: out)
        struct Catalog: Decodable { let embedded: Bool; let models: [AnyDecodable] }
        struct AnyDecodable: Decodable {}
        let decoded = try JSONDecoder().decode(Catalog.self, from: data)
        XCTAssertTrue(decoded.embedded)
        XCTAssertEqual(decoded.models.count, 2)
    }
}


