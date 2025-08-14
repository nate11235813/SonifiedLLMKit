import Foundation

/// Scans a models directory for GGUF files and generates `BundledModels/index.json`.
///
/// Recognized layouts (relative to the models root):
/// - `Models/<name>/<name>-<quant>.gguf`
/// - `Models/<name>-<quant>.gguf`
///
/// The generated manifest schema matches `BundledCatalog` / `BundledCatalogEntry`.
public enum ModelIndexGenerator {
    // Local mirror of the public catalog schema
    struct CatalogEntry: Codable, Equatable {
        let name: String
        let quant: String
        let path: String
        var minRamGB: Int?
        var arch: [String]?
    }
    struct Catalog: Codable, Equatable {
        let embedded: Bool
        let models: [CatalogEntry]
    }
    /// Generate an index.json for bundled models.
    /// - Parameters:
    ///   - modelsRoot: Directory to scan. Defaults to "Models" under the current working directory.
    ///   - outputURL: Output path for the index. Defaults to "BundledModels/index.json" under the CWD.
    ///   - embedded: Whether the models are embedded in the app bundle. Defaults to true.
    public static func generate(modelsRoot: URL,
                               outputURL: URL,
                               embedded: Bool = true) throws {
        var entries = scan(modelsRoot: modelsRoot)
        // Merge existing minRamGB/arch if output exists
        if FileManager.default.fileExists(atPath: outputURL.path),
           let data = try? Data(contentsOf: outputURL),
           let existing = try? JSONDecoder().decode(Catalog.self, from: data) {
            let capsByKey: [String: (Int?, [String]?)] = Dictionary(uniqueKeysWithValues: existing.models.map { e in
                ((e.name + "|" + e.quant), (e.minRamGB, e.arch))
            })
            entries = entries.map { e in
                var copy = e
                if let caps = capsByKey[e.name + "|" + e.quant] {
                    copy.minRamGB = caps.0
                    copy.arch = caps.1
                }
                return copy
            }
        }
        let catalog = Catalog(embedded: embedded, models: entries)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(catalog)

        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: outputURL, options: Data.WritingOptions.atomic)
    }

    /// Scan the provided models root and return entries sorted by name then quant rank (descending).
    /// - Parameter modelsRoot: "Models" directory URL.
    /// - Returns: Sorted array of `BundledCatalogEntry`.
    static func scan(modelsRoot: URL) -> [CatalogEntry] {
        let fm = FileManager.default
        var found: [CatalogEntry] = []

        // Helper to process a single GGUF file URL with a logical relative path under bundle
        func process(fileURL: URL, relativePath: String) {
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            // Expect <name>-<quant>
            guard let dash = fileName.lastIndex(of: "-") else { return }
            let name = String(fileName[..<dash])
            let quant = String(fileName[fileName.index(after: dash)...])
            // Record entry; optional fields left nil; users can add later by editing JSON
            found.append(CatalogEntry(name: name, quant: quant, path: relativePath, minRamGB: nil, arch: nil))
        }

        // 1) Scan Models/<name>/<name>-<quant>.gguf
        if let names = try? fm.contentsOfDirectory(at: modelsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for dir in names {
                if (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                    for f in files where f.pathExtension.lowercased() == "gguf" {
                        let rel = "Models/" + dir.lastPathComponent + "/" + f.lastPathComponent
                        process(fileURL: f, relativePath: rel)
                    }
                }
            }
        }

        // 2) Scan Models/<name>-<quant>.gguf
        if let topFiles = try? fm.contentsOfDirectory(at: modelsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for f in topFiles where f.pathExtension.lowercased() == "gguf" {
                let rel = "Models/" + f.lastPathComponent
                process(fileURL: f, relativePath: rel)
            }
        }

        // De-duplicate identical entries (same name+quant), preferring the nested path variant if both exist.
        var unique: [String: CatalogEntry] = [:]
        for e in found {
            let key = e.name + "|" + e.quant
            if let existing = unique[key] {
                // Prefer nested path (which contains "/") over flat
                let existingIsNested = existing.path.contains("/")
                let currentIsNested = e.path.contains("/")
                if existingIsNested { continue }
                if currentIsNested { unique[key] = e } else { unique[key] = existing }
            } else {
                unique[key] = e
            }
        }

        var entries = Array(unique.values)
        entries.sort { a, b in
            if a.name != b.name { return a.name < b.name }
            let ra = quantRank(of: a.quant)
            let rb = quantRank(of: b.quant)
            if ra != rb { return ra > rb } // higher precision first
            return a.quant < b.quant
        }
        return entries
    }

    /// Heuristic ranking for common quant names. Higher is better.
    private static func quantRank(of quant: String) -> Int {
        let rank: [String: Int] = [
            "fp16": 100,
            "q8_0": 90,
            "q6_K_M": 80,
            "q6_K": 78,
            "q5_K_M": 70,
            "q5_K": 68,
            "q4_K_M": 60,
            "q4_K_S": 58,
            "q4_1": 55,
            "q4_0": 50,
            "q3_K_M": 40,
            "q3_K_S": 35,
            "q3_0": 30
        ]
        return rank[quant] ?? 0
    }
}


