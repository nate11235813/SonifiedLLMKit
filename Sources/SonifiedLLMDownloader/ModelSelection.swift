import Foundation
import SonifiedLLMCore

public struct ModelSelectionResult: Sendable, Equatable {
    public let requestedName: String
    public let requestedQuant: String
    public let chosenName: String
    public let chosenQuant: String
    public let url: URL
    public let source: ModelLocation.Source
}

/// Helper for CLI and apps to resolve a bundled model automatically without downloads.
/// Pure Swift; does not spawn processes.
public enum ModelAutoSelection {
    /// Resolve the best bundled model for the given requested spec and device caps.
    /// - Parameters:
    ///   - spec: Desired target spec (name + quant + context).
    ///   - caps: Device capabilities (RAM and arch) used to filter choices.
    ///   - bundle: Bundle to search (default: .main).
    /// - Returns: Selection result with requested and chosen details.
    /// - Throws: `LLMError.modelNotFound` if no suitable bundled model exists.
    public static func resolve(spec: LLMModelSpec, caps: DeviceCaps, in bundle: Bundle = .main) throws -> ModelSelectionResult {
        // 1) Read catalog if present
        func readCatalogData(from bundle: Bundle) -> Data? {
            if let u = bundle.url(forResource: "index", withExtension: "json", subdirectory: "BundledModels"),
               let d = try? Data(contentsOf: u) { return d }
            if let alt = bundle.resourceURL?.appendingPathComponent("BundledModels/index.json"),
               FileManager.default.fileExists(atPath: alt.path),
               let d = try? Data(contentsOf: alt) { return d }
            if let u = bundle.url(forResource: "index", withExtension: "json"),
               let d = try? Data(contentsOf: u) { return d }
            return nil
        }

        let requestedName = spec.name
        let requestedQuant = spec.quant.rawValue

        if let data = readCatalogData(from: bundle), let catalog = try? JSONDecoder().decode(BundledCatalog.self, from: data) {
            // Exact entry first (subject to caps)
            if let exact = catalog.models.first(where: { $0.name == requestedName && $0.quant == requestedQuant }) {
                let passes: Bool = {
                    if let min = exact.minRamGB, caps.ramGB < min { return false }
                    if let allowed = exact.arch, !allowed.isEmpty, !allowed.contains(caps.arch) { return false }
                    return true
                }()
                if passes, let url = BundledModelLocator.resolvePath(exact.path, in: bundle) ?? BundledModelLocator.locate(name: exact.name, quant: exact.quant, in: bundle) {
                    return ModelSelectionResult(requestedName: requestedName,
                                                requestedQuant: requestedQuant,
                                                chosenName: exact.name,
                                                chosenQuant: exact.quant,
                                                url: url,
                                                source: .bundled)
                }
            }

            // Fallback via selector
            if let chosen = BundledModelSelector.choose(spec: spec, catalog: catalog.models, caps: caps) {
                if let url = BundledModelLocator.resolvePath(chosen.path, in: bundle) ?? BundledModelLocator.locate(name: chosen.name, quant: chosen.quant, in: bundle) {
                    return ModelSelectionResult(requestedName: requestedName,
                                                requestedQuant: requestedQuant,
                                                chosenName: chosen.name,
                                                chosenQuant: chosen.quant,
                                                url: url,
                                                source: .bundled)
                }
            }

            throw LLMError.modelNotFound.withBundledOnlyRecovery()
        }

        // 2) No catalog: try exact conventional bundled file
        if let url = BundledModelLocator.locate(spec: spec, in: bundle) {
            return ModelSelectionResult(requestedName: requestedName,
                                        requestedQuant: requestedQuant,
                                        chosenName: requestedName,
                                        chosenQuant: requestedQuant,
                                        url: url,
                                        source: .bundled)
        }
        throw LLMError.modelNotFound.withBundledOnlyRecovery()
    }
}


