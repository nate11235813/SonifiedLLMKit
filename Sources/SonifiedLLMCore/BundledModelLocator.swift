import Foundation

/// Reads a minimal manifest of bundled models and resolves URLs inside a given `Bundle`.
///
/// Behavior:
/// - If `BundledModels/index.json` exists, it is parsed and used to resolve the model path
///   for a matching `name` + `quant` pair.
/// - Regardless of manifest presence, conventional locations are attempted next:
///   - `Models/<name>/<name>-<quant>.gguf`
///   - `Models/<name>-<quant>.gguf`
///
/// This is read-only; it only checks for resource existence.
///
/// Phase 4: bundle-first selection; downloads disabled; automatic fallback based on device caps.
public enum BundledModelLocator {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let name: String
            let quant: String
            let path: String
            let minRamGB: Int?
            let arch: [String]?
        }
        let embedded: Bool
        let models: [Entry]
    }

    /// Attempt to locate a bundled model URL for the provided spec inside `bundle`.
    /// - Returns: URL if found, otherwise nil.
    public static func locate(spec: LLMModelSpec, in bundle: Bundle) -> URL? {
        // 1) Try manifest if present
        var manifestData: Data? = nil
        if let manifestURL = bundle.url(forResource: "index", withExtension: "json", subdirectory: "BundledModels") {
            manifestData = try? Data(contentsOf: manifestURL)
        } else if let altURL = bundle.resourceURL?.appendingPathComponent("BundledModels/index.json"),
                  FileManager.default.fileExists(atPath: altURL.path) {
            manifestData = try? Data(contentsOf: altURL)
        }
        if manifestData == nil {
            // Also try a flat top-level index.json (as seen in some SPM layouts)
            if let top = bundle.url(forResource: "index", withExtension: "json") {
                manifestData = try? Data(contentsOf: top)
            }
        }
        if let data = manifestData,
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            if let match = manifest.models.first(where: { $0.name == spec.name && $0.quant == spec.quant.rawValue }) {
                if let resolved = resolve(path: match.path, in: bundle) {
                    return resolved
                }
                // Fallback: ignore directories in manifest path and try filename at bundle root
                let filename = (match.path as NSString).lastPathComponent
                if let byName = resolve(path: filename, in: bundle) { return byName }
            }
        }

        // 2) Fallback to conventional locations
        let quant = spec.quant.rawValue
        // Models/<name>/<name>-<quant>.gguf
        if let url = bundle.url(
            forResource: "\(spec.name)-\(quant)",
            withExtension: "gguf",
            subdirectory: "Models/\(spec.name)"
        ) {
            return url
        }
        // Also try raw file existence under resourceURL for the same path
        if let base = bundle.resourceURL?.appendingPathComponent("Models/\(spec.name)/\(spec.name)-\(quant).gguf"),
           FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        // Models/<name>-<quant>.gguf
        if let url = bundle.url(
            forResource: "\(spec.name)-\(quant)",
            withExtension: "gguf",
            subdirectory: "Models"
        ) {
            return url
        }
        if let base = bundle.resourceURL?.appendingPathComponent("Models/\(spec.name)-\(quant).gguf"),
           FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        // As a last resort, try top-level file
        if let root = bundle.url(forResource: "\(spec.name)-\(quant)", withExtension: "gguf") {
            return root
        }
        if let base = bundle.resourceURL?.appendingPathComponent("\(spec.name)-\(quant).gguf"),
           FileManager.default.fileExists(atPath: base.path) {
            return base
        }

        return nil
    }

    /// Resolve a resource path string within the bundle, honoring subdirectories.
    public static func resolvePath(_ path: String, in bundle: Bundle) -> URL? {
        // Split the provided path into directory and filename components
        let nsPath = path as NSString
        let dir = nsPath.deletingLastPathComponent
        let file = nsPath.lastPathComponent
        let fileNoExt = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension

        // Try resolving via Bundle API which understands resource subdirectories
        if let url = bundle.url(forResource: fileNoExt, withExtension: ext.isEmpty ? nil : ext, subdirectory: dir.isEmpty ? nil : dir) {
            return url
        }
        // As a last resort, if the bundle has an absolute resource URL for the directory, append path
        if let base = bundle.resourceURL?.appendingPathComponent(path) {
            if FileManager.default.fileExists(atPath: base.path) { return base }
        }
        return nil
    }

    /// Attempt to locate a bundled model URL for provided name and quant (string form), without needing a typed `LLMModelSpec`.
    /// Useful when selecting a fallback from the catalog where the quant might not map to `LLMModelSpec.Quantization`.
    public static func locate(name: String, quant: String, in bundle: Bundle) -> URL? {
        // 1) Try manifest if present
        var manifestData: Data? = nil
        if let manifestURL = bundle.url(forResource: "index", withExtension: "json", subdirectory: "BundledModels") {
            manifestData = try? Data(contentsOf: manifestURL)
        } else if let altURL = bundle.resourceURL?.appendingPathComponent("BundledModels/index.json"),
                  FileManager.default.fileExists(atPath: altURL.path) {
            manifestData = try? Data(contentsOf: altURL)
        }
        if manifestData == nil {
            // Also try a flat top-level index.json (as seen in some SPM layouts)
            if let top = bundle.url(forResource: "index", withExtension: "json") {
                manifestData = try? Data(contentsOf: top)
            }
        }
        if let data = manifestData,
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            if let match = manifest.models.first(where: { $0.name == name && $0.quant == quant }) {
                if let resolved = resolvePath(match.path, in: bundle) { return resolved }
                let filename = (match.path as NSString).lastPathComponent
                if let byName = resolvePath(filename, in: bundle) { return byName }
            }
        }

        // 2) Conventional locations
        if let url = bundle.url(
            forResource: "\(name)-\(quant)",
            withExtension: "gguf",
            subdirectory: "Models/\(name)"
        ) { return url }
        if let base = bundle.resourceURL?.appendingPathComponent("Models/\(name)/\(name)-\(quant).gguf"),
           FileManager.default.fileExists(atPath: base.path) { return base }

        if let url = bundle.url(
            forResource: "\(name)-\(quant)",
            withExtension: "gguf",
            subdirectory: "Models"
        ) { return url }
        if let base = bundle.resourceURL?.appendingPathComponent("Models/\(name)-\(quant).gguf"),
           FileManager.default.fileExists(atPath: base.path) { return base }

        if let root = bundle.url(forResource: "\(name)-\(quant)", withExtension: "gguf") { return root }
        if let base = bundle.resourceURL?.appendingPathComponent("\(name)-\(quant).gguf"),
           FileManager.default.fileExists(atPath: base.path) { return base }

        return nil
    }

    private static func resolve(path: String, in bundle: Bundle) -> URL? {
        return resolvePath(path, in: bundle)
    }
}


