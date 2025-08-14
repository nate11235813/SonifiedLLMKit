import Foundation
import SonifiedLLMCore

public struct FileModelStore: ModelStore {
    public init(deviceCaps: DeviceCaps? = nil) { self.injectedCaps = deviceCaps }

    // Allow tests to inject caps; otherwise derive from `Preflight`.
    private let injectedCaps: DeviceCaps?

    /// Internal entry point used by tests to inject a specific bundle.
    public func ensureAvailable(spec: LLMModelSpec, in bundle: Bundle) throws -> ModelLocation {
        // Load bundled catalog if present and apply caps-aware selection policy. If no catalog, fall back to legacy behavior.
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

        if let data = readCatalogData(from: bundle), let catalog = try? JSONDecoder().decode(BundledCatalog.self, from: data) {
            let caps = injectedCaps ?? DeviceCaps(ramGB: Preflight.ramInGB(), arch: Preflight.currentArch())

            // Try exact entry in catalog gated by caps
            if let exact = catalog.models.first(where: { $0.name == spec.name && $0.quant == spec.quant.rawValue }) {
                let passes: Bool = {
                    if let min = exact.minRamGB, caps.ramGB < min { return false }
                    if let allowed = exact.arch, !allowed.isEmpty, !allowed.contains(caps.arch) { return false }
                    return true
                }()
                if passes, let url = BundledModelLocator.resolvePath(exact.path, in: bundle) ?? BundledModelLocator.locate(name: exact.name, quant: exact.quant, in: bundle) {
                    return ModelLocation(url: url, source: .bundled)
                }
            }

            // Otherwise, use selector to find best fallback
            if let chosen = BundledModelSelector.choose(spec: spec, catalog: catalog.models, caps: caps) {
                if let url = BundledModelLocator.resolvePath(chosen.path, in: bundle) ?? BundledModelLocator.locate(name: chosen.name, quant: chosen.quant, in: bundle) {
                    #if DEBUG
                    print("[ModelStore] Fallback to bundled \(chosen.name) / \(chosen.quant) due to caps: ram=\(caps.ramGB)GB arch=\(caps.arch)")
                    #endif
                    return ModelLocation(url: url, source: .bundled)
                }
            }

            // Catalog present but no suitable candidate
            throw LLMError.modelNotFound.withBundledOnlyRecovery()
        }

        // Legacy: no catalog, just try any exact bundled location.
        if let url = BundledModelLocator.locate(spec: spec, in: bundle) {
            return ModelLocation(url: url, source: .bundled)
        }
        throw LLMError.modelNotFound.withBundledOnlyRecovery()
    }

    /// Bundled-first; downloads disabled in this phase. Phase 4: bundle-first selection; downloads disabled; automatic fallback based on device caps.
    ///
    /// Strategy:
    /// 1) Attempt to resolve a bundled model via `BundledModelLocator`.
    /// 2) If not found, consult `BundledModels/index.json` and select a fallback per `BundledModelSelector` using device caps.
    /// 3) If found, return `.bundled` URL. Otherwise, fail with `.modelNotFound` and a recovery suggestion indicating bundling is required.
    public func ensureAvailable(spec: LLMModelSpec) async throws -> ModelLocation {
        return try ensureAvailable(spec: spec, in: .main)
    }

    public func purge(spec: LLMModelSpec) throws {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let file = appSupport.appendingPathComponent("Models/\(spec.name)-\(spec.quant.rawValue).gguf")
        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    public func diskUsage() async -> Int64 {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let modelsDir = appSupport.appendingPathComponent("Models", isDirectory: true)
        guard let enumerator = fm.enumerator(at: modelsDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [], errorHandler: nil) else {
            return 0
        }
        var total: Int64 = 0
        while let next = enumerator.nextObject() as? URL {
            if let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // Returns where a manifest would live in dev or app runtime.
    // TODO: Thread this through Bundle or app config; for now, point to a repo-local Manifests directory in dev.
    public func defaultManifestURL(for spec: LLMModelSpec) -> URL {
        // Dev-time path: <repo>/Manifests/<name>-<quant>.json
        // Using #file to locate this source file, then navigating up to repo root.
        let thisFileURL = URL(fileURLWithPath: #file)
        let repoRoot = thisFileURL.deletingLastPathComponent() // FileModelStore.swift
            .deletingLastPathComponent() // SonifiedLLMDownloader
            .deletingLastPathComponent() // Sources
        let manifestsDir = repoRoot.appendingPathComponent("Manifests", isDirectory: true)
        let filename = "\(spec.name)-\(spec.quant.rawValue).json"
        return manifestsDir.appendingPathComponent(filename)
    }
}
