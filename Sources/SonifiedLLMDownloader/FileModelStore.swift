import Foundation
import SonifiedLLMCore

public struct FileModelStore: ModelStore {
    public init() {}

    public func ensureAvailable(spec: LLMModelSpec) async throws -> ModelLocation {
        // Default container location in Application Support
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let modelsDir = appSupport.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let file = modelsDir.appendingPathComponent("\(spec.name)-\(spec.quant.rawValue).gguf")

        // TODO: Load manifest (from repo or bundle) and perform real download via ModelDownloader
        // For now, if the file exists and looks good, return; otherwise, stub behavior.
        if fm.fileExists(atPath: file.path) {
            return ModelLocation(url: file, source: .downloaded)
        }

        // Example wiring (commented):
        // let manifestURL = defaultManifestURL(for: spec)
        // let manifest = try ModelManifest.load(from: manifestURL)
        // try manifest.validate()
        // let downloader = ModelDownloader(delegate: nil)
        // try await downloader.download(manifest: manifest, destination: file)
        // return file

        // In the stub, we return the path where it would be downloaded
        return ModelLocation(url: file, source: .downloaded)
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
