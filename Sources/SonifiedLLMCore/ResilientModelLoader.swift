import Foundation

public struct ResilientLoadResult: Sendable {
    public let chosenSpec: LLMModelSpec
    public let url: URL
    public let provenance: ModelLocation.Source
    public let fallback: (from: String, to: String, reason: LLMError.EngineInitFailureReason)?
}

/// Helper that attempts to load the requested bundled model and falls back once on engine init failure.
public enum ResilientModelLoader {
    public static func loadBundled(engine: LLMEngine,
                                   requestedSpec: LLMModelSpec,
                                   caps: DeviceCaps,
                                   bundle: Bundle = .main,
                                   catalog: BundledCatalog? = nil) async throws -> ResilientLoadResult {
        // Resolve exact URL if available; otherwise use selector to find candidate
        let catalogModels: [BundledCatalogEntry]? = {
            if let catalog { return catalog.models }
            if let u = bundle.url(forResource: "index", withExtension: "json", subdirectory: "BundledModels"),
               let d = try? Data(contentsOf: u),
               let c = try? JSONDecoder().decode(BundledCatalog.self, from: d) { return c.models }
            if let alt = bundle.resourceURL?.appendingPathComponent("BundledModels/index.json"),
               FileManager.default.fileExists(atPath: alt.path),
               let d = try? Data(contentsOf: alt),
               let c = try? JSONDecoder().decode(BundledCatalog.self, from: d) { return c.models }
            if let u = bundle.url(forResource: "index", withExtension: "json"),
               let d = try? Data(contentsOf: u),
               let c = try? JSONDecoder().decode(BundledCatalog.self, from: d) { return c.models }
            // Dev-time: try repo-root BundledModels/index.json
            #if DEBUG
            if let repo = devRepoRoot() {
                let dev = repo.appendingPathComponent("BundledModels/index.json")
                if FileManager.default.fileExists(atPath: dev.path),
                   let d = try? Data(contentsOf: dev),
                   let c = try? JSONDecoder().decode(BundledCatalog.self, from: d) {
                    return c.models
                }
            }
            // Dev-time: try current working directory
            do {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let dev = cwd.appendingPathComponent("BundledModels/index.json")
                if FileManager.default.fileExists(atPath: dev.path),
                   let d = try? Data(contentsOf: dev),
                   let c = try? JSONDecoder().decode(BundledCatalog.self, from: d) {
                    return c.models
                }
            }
            #endif
            return nil
        }()

        // Build candidate list
        var candidates: [(spec: LLMModelSpec, url: URL)] = []
        if let url = BundledModelLocator.locate(spec: requestedSpec, in: bundle) {
            candidates.append((requestedSpec, url))
        }
        if let models = catalogModels {
            let ordered = BundledModelSelector.orderedCandidates(spec: requestedSpec, catalog: models, caps: caps)
            for e in ordered {
                // prefer already-resolved exact URL
                if e.name == requestedSpec.name && e.quant == requestedSpec.quant.rawValue && !candidates.isEmpty { continue }
                if let url = BundledModelLocator.resolvePath(e.path, in: bundle) ?? BundledModelLocator.locate(name: e.name, quant: e.quant, in: bundle) {
                    let q = LLMModelSpec.Quantization(rawValue: e.quant) ?? requestedSpec.quant
                    let s = LLMModelSpec(name: e.name, quant: q, contextTokens: requestedSpec.contextTokens, tokenizer: requestedSpec.tokenizer)
                    candidates.append((s, url))
                }
            }
        }
        // Ensure at least requested
        if candidates.isEmpty { throw LLMError.modelNotFound.withBundledOnlyRecovery() }

        // Try first candidate
        do {
            try await engine.load(modelURL: candidates[0].url, spec: candidates[0].spec)
            return ResilientLoadResult(chosenSpec: candidates[0].spec, url: candidates[0].url, provenance: .bundled, fallback: nil)
        } catch let e as LLMError {
            switch e {
            case .engineInitFailed(let reason, _):
                // Try next best once
                guard candidates.count > 1 else { throw e }
                // Unload any partial state before retrying
                await engine.unload()
                let next = candidates[1]
                do {
                    try await engine.load(modelURL: next.url, spec: next.spec)
                    return ResilientLoadResult(chosenSpec: next.spec, url: next.url, provenance: .bundled, fallback: (from: "\(candidates[0].spec.name):\(candidates[0].spec.quant.rawValue)", to: "\(next.spec.name):\(next.spec.quant.rawValue)", reason: reason))
                } catch {
                    throw error
                }
            default:
                throw e
            }
        } catch {
            throw error
        }
    }
}

#if DEBUG
private func devRepoRoot() -> URL? {
    let this = URL(fileURLWithPath: #file)
    let repo = this
        .deletingLastPathComponent() // ResilientModelLoader.swift
        .deletingLastPathComponent() // SonifiedLLMCore
        .deletingLastPathComponent() // Sources
    if FileManager.default.fileExists(atPath: repo.appendingPathComponent("BundledModels/index.json").path) {
        return repo
    }
    return nil
}
#endif


